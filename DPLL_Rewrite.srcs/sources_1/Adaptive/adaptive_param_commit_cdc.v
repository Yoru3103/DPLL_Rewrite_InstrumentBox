`timescale 1ns / 1ps

// 锁相回路跨时钟参数提交模块。
// bus_clk 域保存 shadow/hold 参数并发出 request toggle；loop_clk 域原子应用后返回 ack toggle。
// hold_* 在 busy 期间保持不变，因此多位参数总线可作为 bundled-data 安全跨域。
module adaptive_param_commit_cdc (
    input  wire        bus_clk,        // PS 寄存器总线时钟，本项目为 125 MHz
    input  wire        loop_clk,       // DPLL 环路时钟，本项目为 3.125 MHz
    input  wire        reset_n,        // 两个时钟域共用的低有效同步复位输入
    input  wire        bus_write,      // PS 寄存器写使能
    input  wire [15:0] bus_address,    // 已换算成 word address 的寄存器地址
    input  wire [31:0] bus_wdata,      // PS 写入数据
    input  wire        legacy_changed, // 旧参数地址被写入的 bus_clk 单拍标志
    input  wire [31:0] legacy_kp,      // 旧接口 Kp
    input  wire [31:0] legacy_ki,      // 旧接口 Ki
    input  wire [31:0] legacy_kii,     // 旧接口 Kii
    input  wire [31:0] legacy_kd,      // 旧接口 Kd
    input  wire [31:0] legacy_dcoef,   // 旧接口 D 支路滤波系数
    output wire [31:0] loop_kp,        // 实际送入 3.125 MHz 环路的 Kp
    output wire [31:0] loop_ki,        // 实际送入 3.125 MHz 环路的 Ki
    output wire [31:0] loop_kii,       // 实际送入 3.125 MHz 环路的 Kii
    output wire [31:0] loop_kd,        // 实际送入 3.125 MHz 环路的 Kd
    output wire [31:0] loop_dcoef,     // 实际送入 3.125 MHz 环路的 D 滤波系数
    output reg         loop_gain_changed, // loop_clk 域参数变化单拍脉冲
    output reg  [7:0]  shadow_profile, // PS 正在准备、尚未提交的 profile ID
    output reg  [31:0] shadow_kp,      // 尚未提交的 Kp
    output reg  [31:0] shadow_ki,      // 尚未提交的 Ki
    output reg  [31:0] shadow_kii,     // 尚未提交的 Kii
    output reg  [31:0] shadow_kd,      // 尚未提交的 Kd
    output reg  [31:0] shadow_dcoef,   // 尚未提交的 D 滤波系数，低 18 bit 有效
    output reg  [31:0] applied_seq,    // bus 域确认已在 loop 域生效的事务序号
    output wire [31:0] apply_status,   // busy、atomic mode、错误和 profile 的打包状态
    output reg  [7:0]  active_profile_bus, // 返回 bus 域的活动 profile 镜像
    output reg  [31:0] active_kp_bus,      // 返回 bus 域的活动 Kp 镜像
    output reg  [31:0] active_ki_bus,      // 返回 bus 域的活动 Ki 镜像
    output reg  [31:0] active_kii_bus,     // 返回 bus 域的活动 Kii 镜像
    output reg  [31:0] active_kd_bus,      // 返回 bus 域的活动 Kd 镜像
    output reg  [31:0] active_dcoef_bus,   // 返回 bus 域的活动 D 滤波系数镜像
    output reg  [31:0] commit_error_count // busy/非法/重复提交的饱和累计次数
);

reg [7:0] hold_profile; // 接受提交时复制的 profile，ack 返回前保持稳定
reg [31:0] hold_kp, hold_ki, hold_kii, hold_kd, hold_dcoef, hold_seq; // CDC bundled-data 保持组
reg request_toggle;    // 每接受一个新事务翻转，通知 loop_clk 域
reg busy;              // 1 表示已有事务等待 loop 域确认，禁止覆盖 hold_*
reg error_sticky;      // 提交错误锁存，供 PS 查询
reg legacy_write_seen; // 最近一次提交后是否发生过旧地址写入
reg legacy_mode_request; // 电平为 1 时要求 loop 域切回旧参数路径
reg [7:0] legacy_event_binary, legacy_event_gray; // 旧参数写事件计数及其格雷码 CDC 表示

// ASYNC_REG： 寄存器属于异步时钟域同步链，可能遇到亚稳态，需要按同步器来特殊处理
(* ASYNC_REG = "TRUE" *) reg request_meta, request_sync; // request toggle 两级同步链
reg request_seen; // loop 域已处理的 request 极性
(* ASYNC_REG = "TRUE" *) reg legacy_mode_meta, legacy_mode_sync;
(* ASYNC_REG = "TRUE" *) reg [7:0] legacy_event_meta, legacy_event_sync;
reg [7:0] legacy_event_seen; // loop 域最近处理的旧参数事件格雷码
reg acknowledge_toggle;     // loop 域每应用一次新事务翻转，通知 bus 域
reg [31:0] applied_seq_loop; // loop 域已经应用的事务序号
reg [7:0] active_profile_loop; // loop 域当前活动 profile
reg [31:0] active_kp_loop, active_ki_loop, active_kii_loop; // loop 域活动 P/I/II 系数
reg [31:0] active_kd_loop, active_dcoef_loop; // loop 域活动 D 系数及滤波系数
reg atomic_mode_loop; // 1：环路选择 active_*；0：环路选择 legacy_*

(* ASYNC_REG = "TRUE" *) reg acknowledge_meta, acknowledge_sync; // ack toggle 返回同步链
reg acknowledge_seen; // bus 域已处理的 ack 极性
(* ASYNC_REG = "TRUE" *) reg atomic_mode_meta, atomic_mode_sync; // 活动模式返回 bus 域显示

// 决定使用新接口还是老接口
assign loop_kp = atomic_mode_loop ? active_kp_loop : legacy_kp;
assign loop_ki = atomic_mode_loop ? active_ki_loop : legacy_ki;
assign loop_kii = atomic_mode_loop ? active_kii_loop : legacy_kii;
assign loop_kd = atomic_mode_loop ? active_kd_loop : legacy_kd;
assign loop_dcoef = atomic_mode_loop ? active_dcoef_loop : legacy_dcoef;
// APPLY_STATUS：bits15:8 profile，bit3 legacy 写入，bit2 错误，bit1 原子模式，bit0 busy。
assign apply_status = {16'd0, active_profile_bus, 4'd0, legacy_write_seen,
                       error_sticky, atomic_mode_sync, busy};

function [31:0] saturating_increment;
    input [31:0] value;
    begin
        saturating_increment = (&value) ? value : value + 32'd1;
    end
endfunction

always @(posedge bus_clk) begin
    if (!reset_n) begin
        shadow_profile <= 8'd0;
        shadow_kp <= 32'd0;
        shadow_ki <= 32'd0;
        shadow_kii <= 32'd0;
        shadow_kd <= 32'd0;
        shadow_dcoef <= 32'd0;
        hold_profile <= 8'd0;
        hold_kp <= 32'd0;
        hold_ki <= 32'd0;
        hold_kii <= 32'd0;
        hold_kd <= 32'd0;
        hold_dcoef <= 32'd0;
        hold_seq <= 32'd0;
        request_toggle <= 1'b0;
        busy <= 1'b0;
        error_sticky <= 1'b0;
        legacy_write_seen <= 1'b0;
        legacy_mode_request <= 1'b1;
        legacy_event_binary <= 8'd0;
        legacy_event_gray <= 8'd0;
        applied_seq <= 32'd0;
        active_profile_bus <= 8'd0;
        active_kp_bus <= 32'd0;
        active_ki_bus <= 32'd0;
        active_kii_bus <= 32'd0;
        active_kd_bus <= 32'd0;
        active_dcoef_bus <= 32'd0;
        commit_error_count <= 32'd0;
        acknowledge_meta <= 1'b0;
        acknowledge_sync <= 1'b0;
        acknowledge_seen <= 1'b0;
        atomic_mode_meta <= 1'b0;
        atomic_mode_sync <= 1'b0;
    end else begin
        // 将 loop 域的确认 toggle 和当前模式同步回 PS 总线域。
        acknowledge_meta <= acknowledge_toggle;
        acknowledge_sync <= acknowledge_meta;   // 跨时钟域，两级同步，同步锁相环参数用
        atomic_mode_meta <= atomic_mode_loop;
        atomic_mode_sync <= atomic_mode_meta;

        if (acknowledge_sync != acknowledge_seen) begin
            // 新 ack 到达：复制稳定的活动参数镜像，并结束本次事务。
            acknowledge_seen <= acknowledge_sync;       // 记录极性
            applied_seq <= applied_seq_loop;            // 成功应用的参数更新序号
            active_profile_bus <= active_profile_loop;  // 当前生效的参数配置档编号
            active_kp_bus <= active_kp_loop;
            active_ki_bus <= active_ki_loop;
            active_kii_bus <= active_kii_loop;
            active_kd_bus <= active_kd_loop;
            active_dcoef_bus <= active_dcoef_loop;      // 微分滤波，微分相关系数
            busy <= 1'b0;
        end

        // 检测旧版PID参数是否被写过，兼容旧版
        if (legacy_changed) begin
            legacy_mode_request <= 1'b1;
            legacy_write_seen <= 1'b1;
            // 格雷码允许 loop 域可靠发现一次或一批旧参数写事件；事件可合并但不会因偶数次翻转消失。
            legacy_event_binary <= legacy_event_binary + 8'd1;
            legacy_event_gray <= ((legacy_event_binary + 8'd1) >> 1) ^
                                 (legacy_event_binary + 8'd1);
        end

        if (bus_write) begin
            case (bus_address)  // 0x0061～0x0066 只更新 shadow，0x0067 才启动事务
                16'h0061: shadow_profile <= bus_wdata[7:0];
                16'h0062: shadow_kp <= bus_wdata;
                16'h0063: shadow_ki <= bus_wdata;
                16'h0064: shadow_kii <= bus_wdata;
                16'h0065: shadow_kd <= bus_wdata;
                16'h0066: shadow_dcoef <= {14'd0, bus_wdata[17:0]};
                16'h0067: begin
                    // busy 时不可覆盖保持寄存器；0 和已应用 sequence 也属于非法事务。
                    if (busy || (bus_wdata == 32'd0) || (bus_wdata == applied_seq)) begin
                        error_sticky <= 1'b1;
                        commit_error_count <= saturating_increment(commit_error_count);
                    end else begin
                        // 复制 bundled-data 后翻转 request；hold_* 会一直保持到 ack 返回。
                        hold_profile <= shadow_profile;
                        hold_kp <= shadow_kp;
                        hold_ki <= shadow_ki;
                        hold_kii <= shadow_kii;
                        hold_kd <= shadow_kd;
                        hold_dcoef <= shadow_dcoef;
                        hold_seq <= bus_wdata;
                        request_toggle <= ~request_toggle;
                        busy <= 1'b1;
                        legacy_mode_request <= 1'b0;
                        legacy_write_seen <= 1'b0;
                    end
                end
                // APPLY_STATUS.bit2 为 W1C，只清错误锁存。
                16'h0069: if (bus_wdata[2]) error_sticky <= 1'b0;
                default: ;
            endcase
        end
    end
end

always @(posedge loop_clk) begin
    if (!reset_n) begin
        request_meta <= 1'b0;
        request_sync <= 1'b0;
        request_seen <= 1'b0;
        legacy_mode_meta <= 1'b1;
        legacy_mode_sync <= 1'b1;
        legacy_event_meta <= 8'd0;
        legacy_event_sync <= 8'd0;
        legacy_event_seen <= 8'd0;
        acknowledge_toggle <= 1'b0;
        applied_seq_loop <= 32'd0;
        active_profile_loop <= 8'd0;
        active_kp_loop <= 32'd0;
        active_ki_loop <= 32'd0;
        active_kii_loop <= 32'd0;
        active_kd_loop <= 32'd0;
        active_dcoef_loop <= 32'd0;
        atomic_mode_loop <= 1'b0;
        loop_gain_changed <= 1'b0;
    end else begin
        // request、legacy 模式和 legacy 事件分别经过两级同步进入慢时钟域。
        request_meta <= request_toggle;
        request_sync <= request_meta;
        legacy_mode_meta <= legacy_mode_request;
        legacy_mode_sync <= legacy_mode_meta;
        legacy_event_meta <= legacy_event_gray;
        legacy_event_sync <= legacy_event_meta;
        loop_gain_changed <= 1'b0;

        if (legacy_mode_sync)
            atomic_mode_loop <= 1'b0;

        if (legacy_event_sync != legacy_event_seen) begin
            // 旧参数发生变化时给环路一个本时钟域的 gain_changed 脉冲。
            legacy_event_seen <= legacy_event_sync;
            loop_gain_changed <= 1'b1;
        end

        if (request_sync != request_seen) begin
            // 新 request 到达：同一个 loop_clk 沿锁存全部参数并返回 ack。
            request_seen <= request_sync;
            active_profile_loop <= hold_profile;
            active_kp_loop <= hold_kp;
            active_ki_loop <= hold_ki;
            active_kii_loop <= hold_kii;
            active_kd_loop <= hold_kd;
            active_dcoef_loop <= hold_dcoef;
            applied_seq_loop <= hold_seq;
            atomic_mode_loop <= 1'b1;
            loop_gain_changed <= 1'b1;
            acknowledge_toggle <= ~acknowledge_toggle;
        end
    end
end

endmodule
