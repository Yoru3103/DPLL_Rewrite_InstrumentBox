`timescale 1ns / 1ps

// 测频回路同时钟参数提交模块。
// PS 先写 shadow 参数，再写 COMMIT_SEQ；整组参数在同一个 clk 上升沿成为 active 参数。
// legacy 参数地址仍可使用，一旦检测到 legacy_changed 就退出原子参数模式。
module adaptive_param_commit_same_clock (
    input  wire        clk,            // 参数总线和测频环路共用的 125 MHz 时钟
    input  wire        reset_n,        // 低有效同步复位
    input  wire        bus_write,      // PS 寄存器写使能
    input  wire [15:0] bus_address,    // 已换算成 word address 的寄存器地址
    input  wire [31:0] bus_wdata,      // PS 写入数据
    input  wire        legacy_changed, // 旧 0x0021～0x0025 参数被写入的单拍标志
    input  wire [31:0] legacy_kp,      // 旧接口 Kp
    input  wire [31:0] legacy_ki,      // 旧接口 Ki
    input  wire [31:0] legacy_kii,     // 旧接口 Kii
    input  wire [31:0] legacy_kd,      // 旧接口 Kd
    input  wire [31:0] legacy_dcoef,   // 旧接口 D 支路滤波系数
    output wire [31:0] loop_kp,        // 实际送入环路滤波器的 Kp
    output wire [31:0] loop_ki,        // 实际送入环路滤波器的 Ki
    output wire [31:0] loop_kii,       // 实际送入环路滤波器的 Kii
    output wire [31:0] loop_kd,        // 实际送入环路滤波器的 Kd
    output wire [31:0] loop_dcoef,     // 实际送入环路滤波器的 D 滤波系数
    output reg         loop_gain_changed, // 参数组发生变化时产生一个 clk 周期脉冲
    output reg  [7:0]  shadow_profile, // PS 正在准备、尚未生效的 profile ID
    output reg  [31:0] shadow_kp,      // 尚未提交的 Kp
    output reg  [31:0] shadow_ki,      // 尚未提交的 Ki
    output reg  [31:0] shadow_kii,     // 尚未提交的 Kii
    output reg  [31:0] shadow_kd,      // 尚未提交的 Kd
    output reg  [31:0] shadow_dcoef,   // 尚未提交的 D 滤波系数，低 18 bit 有效
    output reg  [31:0] applied_seq,    // 最近一次成功应用的事务序号
    output wire [31:0] apply_status,   // 原子模式、错误锁存和当前 profile 的打包状态
    output reg  [7:0]  active_profile, // 当前已经生效的 profile ID
    output reg  [31:0] active_kp,      // 当前原子参数组 Kp
    output reg  [31:0] active_ki,      // 当前原子参数组 Ki
    output reg  [31:0] active_kii,     // 当前原子参数组 Kii
    output reg  [31:0] active_kd,      // 当前原子参数组 Kd
    output reg  [31:0] active_dcoef,   // 当前原子参数组 D 滤波系数
    output reg  [31:0] commit_error_count // 非法/重复提交的饱和累计次数
);

reg atomic_mode_active; // 1：loop_* 选择 active 参数；0：选择 legacy 参数
reg error_sticky;       // 提交错误锁存，PS 对 APPLY_STATUS.bit2 写 1 清除
reg legacy_write_seen;  // 最近一次原子提交后是否发生过旧地址写入

// 原子模式生效前保持原有参数路径，避免升级 bitstream 后改变上电行为。
assign loop_kp = atomic_mode_active ? active_kp : legacy_kp;
assign loop_ki = atomic_mode_active ? active_ki : legacy_ki;
assign loop_kii = atomic_mode_active ? active_kii : legacy_kii;
assign loop_kd = atomic_mode_active ? active_kd : legacy_kd;
assign loop_dcoef = atomic_mode_active ? active_dcoef : legacy_dcoef;
// APPLY_STATUS：bits15:8 profile，bit3 legacy 写入，bit2 错误，bit1 原子模式，bit0 恒 0。
assign apply_status = {16'd0, active_profile, 4'd0, legacy_write_seen,
                       error_sticky, atomic_mode_active, 1'b0};

// 错误计数到达全 1 后停止，避免长时间运行后回卷。
function [31:0] saturating_increment;
    input [31:0] value;
    begin
        saturating_increment = (&value) ? value : value + 32'd1;
    end
endfunction

always @(posedge clk) begin
    if (!reset_n) begin
        shadow_profile <= 8'd0;
        shadow_kp <= 32'd0;
        shadow_ki <= 32'd0;
        shadow_kii <= 32'd0;
        shadow_kd <= 32'd0;
        shadow_dcoef <= 32'd0;
        applied_seq <= 32'd0;
        active_profile <= 8'd0;
        active_kp <= 32'd0;
        active_ki <= 32'd0;
        active_kii <= 32'd0;
        active_kd <= 32'd0;
        active_dcoef <= 32'd0;
        atomic_mode_active <= 1'b0;
        error_sticky <= 1'b0;
        legacy_write_seen <= 1'b0;
        loop_gain_changed <= 1'b0;
        commit_error_count <= 32'd0;
    end else begin
        // 默认把旧接口变化脉冲继续传给环路；新提交成功时在下方强制置 1。
        loop_gain_changed <= legacy_changed;
        if (legacy_changed) begin
            // 手动写旧参数具有更高兼容优先级，立即退出 atomic mode。
            atomic_mode_active <= 1'b0;
            legacy_write_seen <= 1'b1;
        end
        if (bus_write) begin
            case (bus_address)
                // 0x0061～0x0066 仅准备 shadow 参数，不影响当前闭环。
                16'h0061: shadow_profile <= bus_wdata[7:0];
                16'h0062: shadow_kp <= bus_wdata;
                16'h0063: shadow_ki <= bus_wdata;
                16'h0064: shadow_kii <= bus_wdata;
                16'h0065: shadow_kd <= bus_wdata;
                16'h0066: shadow_dcoef <= {14'd0, bus_wdata[17:0]};
                16'h0067: begin
                    // sequence 不能为 0，也不能与最近成功事务重复。
                    if ((bus_wdata == 32'd0) || (bus_wdata == applied_seq)) begin
                        error_sticky <= 1'b1;
                        commit_error_count <= saturating_increment(commit_error_count);
                    end else begin
                        // 同一个时钟沿锁存全部参数，环路不会看到半新半旧的组合。
                        active_profile <= shadow_profile;
                        active_kp <= shadow_kp;
                        active_ki <= shadow_ki;
                        active_kii <= shadow_kii;
                        active_kd <= shadow_kd;
                        active_dcoef <= shadow_dcoef;
                        applied_seq <= bus_wdata;
                        atomic_mode_active <= 1'b1;
                        legacy_write_seen <= 1'b0;
                        loop_gain_changed <= 1'b1;
                    end
                end
                // APPLY_STATUS.bit2 为 W1C：写 1 只清错误锁存，不清累计计数。
                16'h0069: if (bus_wdata[2]) error_sticky <= 1'b0;
                default: ;
            endcase
        end
    end
end

endmodule
