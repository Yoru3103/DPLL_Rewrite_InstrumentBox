`timescale 1ns / 1ps

// 自适应环路统计模块：在固定的 2^WINDOW_LOG2 个采样点内统计幅值、残差和状态。
// *_work 为当前窗口的工作寄存器；没有 _work 后缀的输出为上一个完整窗口的冻结快照。
// 所有快照输出只在窗口边界同时更新，PS 可用 snapshot_seq 前后两次读回保证一致性。
module adaptive_statistics #(
    parameter integer WINDOW_LOG2 = 12  // 窗口长度的 log2；12 对应 4096 个采样点
) (
    input  wire                    clk,             // 被观测环路所在时钟
    input  wire                    reset_n,         // 低有效同步复位
    input  wire [15:0]             amplitude,       // DDC 幅值，无符号数
    input  wire signed [13:0]      frequency_error, // 瞬时频率残差，二补码有符号数
    input  wire signed [31:0]      phase_error,     // 相位残差，二补码有符号数
    input  wire signed [31:0]      loop_output,     // 限幅后的 PID/环路输出
    input  wire                    locked,          // 本采样点锁定有效标志
    input  wire                    rail_positive,   // 本采样点正向限幅标志
    input  wire                    rail_negative,   // 本采样点负向限幅标志
    input  wire                    frequency_bad,   // 本采样点频率残差越限标志
    input  wire                    phase_bad,       // 本采样点相位残差越限标志

    output reg  [31:0]             snapshot_seq,    // 每完成一个窗口加 1，0 表示尚无有效快照
    output wire                    snapshot_toggle, // 每完成一个窗口翻转，用于通知另一时钟域
    output reg  [31:0]             sample_count,    // 冻结快照实际包含的采样点数
    output reg  [63:0]             amplitude_sum,   // 窗口幅值累加和，PS 用它计算均值
    output reg  [15:0]             amplitude_min,   // 窗口幅值最小值
    output reg  [15:0]             amplitude_max,   // 窗口幅值最大值
    output reg  [63:0]             frequency_abs_sum, // 窗口 |频率残差| 累加和
    output reg  [31:0]             frequency_abs_max, // 窗口 |频率残差| 峰值
    output reg  [63:0]             phase_abs_sum,   // 窗口 |相位残差| 累加和
    output reg  [31:0]             phase_abs_max,   // 窗口 |相位残差| 峰值
    output reg  [31:0]             output_min,      // 窗口环路输出最小值，按有符号数解释
    output reg  [31:0]             output_max,      // 窗口环路输出最大值，按有符号数解释
    output reg  [31:0]             locked_sample_count,       // 窗口内锁定有效样本数
    output reg  [31:0]             positive_rail_sample_count, // 窗口内正限幅样本数
    output reg  [31:0]             negative_rail_sample_count, // 窗口内负限幅样本数
    output reg  [31:0]             frequency_bad_sample_count, // 窗口内频率越限样本数
    output reg  [31:0]             phase_bad_sample_count,     // 窗口内相位越限样本数
    output reg  [31:0]             loss_of_lock_event_count,   // 复位以来累计失锁边沿数的快照
    output reg  [31:0]             positive_rail_event_count,  // 复位以来累计正限幅边沿数的快照
    output reg  [31:0]             negative_rail_event_count   // 复位以来累计负限幅边沿数的快照
);

// 固定窗口包含的采样点数；使用 2 的整数次幂可将边界判断简化为全 1 检测。
localparam [31:0] WINDOW_SAMPLES = (32'd1 << WINDOW_LOG2);

reg [WINDOW_LOG2-1:0] window_index; // 当前窗口采样下标，计到全 1 时结束窗口
reg [63:0] amp_sum_work;            // 当前窗口幅值累加器
reg [15:0] amp_min_work, amp_max_work; // 当前窗口幅值极值
reg [63:0] freq_sum_work;           // 当前窗口频率残差绝对值累加器
reg [31:0] freq_max_work;           // 当前窗口频率残差绝对值峰值
reg [63:0] phase_sum_work;          // 当前窗口相位残差绝对值累加器
reg [31:0] phase_max_work;          // 当前窗口相位残差绝对值峰值
reg signed [31:0] output_min_work, output_max_work; // 当前窗口有符号输出极值
reg [31:0] locked_work, pos_rail_work, neg_rail_work; // 当前窗口状态样本计数
reg [31:0] freq_bad_work, phase_bad_work; // 当前窗口残差越限样本计数
reg previous_locked, previous_pos_rail, previous_neg_rail; // 上一拍状态，用于边沿检测
reg snapshot_toggle_r;              // 完整窗口到达指示，供 CDC 模块同步
reg [31:0] loss_event_total, pos_event_total, neg_event_total; // 复位以来的饱和事件总数

// 对二补码最小负数取绝对值会溢出，因此在最大正数处饱和。
wire [13:0] frequency_abs =
    (frequency_error == 14'sh2000) ? 14'h1fff :
    (frequency_error[13] ? (~frequency_error + 14'd1) : frequency_error);
wire [31:0] phase_abs =
    (phase_error == 32'sh80000000) ? 32'h7fffffff :
    (phase_error[31] ? (~phase_error + 32'd1) : phase_error);
wire last_sample = &window_index;

assign snapshot_toggle = snapshot_toggle_r;

// 事件计数达到 0xFFFFFFFF 后保持，避免自然回卷造成软件误判。
function [31:0] saturating_increment;
    input [31:0] value;
    begin
        saturating_increment = (&value) ? value : value + 32'd1;
    end
endfunction

always @(posedge clk) begin
    if (!reset_n) begin
        window_index <= {WINDOW_LOG2{1'b0}};
        amp_sum_work <= 64'd0;
        amp_min_work <= 16'hffff;
        amp_max_work <= 16'd0;
        freq_sum_work <= 64'd0;
        freq_max_work <= 32'd0;
        phase_sum_work <= 64'd0;
        phase_max_work <= 32'd0;
        output_min_work <= 32'sh7fffffff;
        output_max_work <= -32'sh7fffffff - 1;
        locked_work <= 32'd0;
        pos_rail_work <= 32'd0;
        neg_rail_work <= 32'd0;
        freq_bad_work <= 32'd0;
        phase_bad_work <= 32'd0;
        previous_locked <= 1'b0;
        previous_pos_rail <= 1'b0;
        previous_neg_rail <= 1'b0;
        loss_event_total <= 32'd0;
        pos_event_total <= 32'd0;
        neg_event_total <= 32'd0;
        snapshot_seq <= 32'd0;
        snapshot_toggle_r <= 1'b0;
        sample_count <= 32'd0;
        amplitude_sum <= 64'd0;
        amplitude_min <= 16'd0;
        amplitude_max <= 16'd0;
        frequency_abs_sum <= 64'd0;
        frequency_abs_max <= 32'd0;
        phase_abs_sum <= 64'd0;
        phase_abs_max <= 32'd0;
        output_min <= 32'd0;
        output_max <= 32'd0;
        locked_sample_count <= 32'd0;
        positive_rail_sample_count <= 32'd0;
        negative_rail_sample_count <= 32'd0;
        frequency_bad_sample_count <= 32'd0;
        phase_bad_sample_count <= 32'd0;
        loss_of_lock_event_count <= 32'd0;
        positive_rail_event_count <= 32'd0;
        negative_rail_event_count <= 32'd0;
    end else begin
        // 保存上一拍状态，并累计失锁/限幅的上升或下降事件。
        previous_locked <= locked;
        previous_pos_rail <= rail_positive;
        previous_neg_rail <= rail_negative;
        if (previous_locked && !locked)
            loss_event_total <= saturating_increment(loss_event_total);
        if (!previous_pos_rail && rail_positive)
            pos_event_total <= saturating_increment(pos_event_total);
        if (!previous_neg_rail && rail_negative)
            neg_event_total <= saturating_increment(neg_event_total);

        if (last_sample) begin
            // 将当前窗口（包括本拍输入）一次性复制到只读快照区。
            snapshot_seq <= snapshot_seq + 32'd1;
            snapshot_toggle_r <= ~snapshot_toggle_r;
            sample_count <= WINDOW_SAMPLES;
            amplitude_sum <= amp_sum_work + amplitude;
            amplitude_min <= (amplitude < amp_min_work) ? amplitude : amp_min_work;
            amplitude_max <= (amplitude > amp_max_work) ? amplitude : amp_max_work;
            frequency_abs_sum <= freq_sum_work + frequency_abs;
            frequency_abs_max <= (frequency_abs > freq_max_work) ? frequency_abs : freq_max_work;
            phase_abs_sum <= phase_sum_work + phase_abs;
            phase_abs_max <= (phase_abs > phase_max_work) ? phase_abs : phase_max_work;
            output_min <= ($signed(loop_output) < output_min_work) ? loop_output : output_min_work;
            output_max <= ($signed(loop_output) > output_max_work) ? loop_output : output_max_work;
            locked_sample_count <= locked_work + locked;
            positive_rail_sample_count <= pos_rail_work + rail_positive;
            negative_rail_sample_count <= neg_rail_work + rail_negative;
            frequency_bad_sample_count <= freq_bad_work + frequency_bad;
            phase_bad_sample_count <= phase_bad_work + phase_bad;
            loss_of_lock_event_count <= (previous_locked && !locked) ?
                saturating_increment(loss_event_total) : loss_event_total;
            positive_rail_event_count <= (!previous_pos_rail && rail_positive) ?
                saturating_increment(pos_event_total) : pos_event_total;
            negative_rail_event_count <= (!previous_neg_rail && rail_negative) ?
                saturating_increment(neg_event_total) : neg_event_total;

            // 快照完成后清空工作区，下一拍开始统计新窗口。
            window_index <= {WINDOW_LOG2{1'b0}};
            amp_sum_work <= 64'd0;
            amp_min_work <= 16'hffff;
            amp_max_work <= 16'd0;
            freq_sum_work <= 64'd0;
            freq_max_work <= 32'd0;
            phase_sum_work <= 64'd0;
            phase_max_work <= 32'd0;
            output_min_work <= 32'sh7fffffff;
            output_max_work <= -32'sh7fffffff - 1;
            locked_work <= 32'd0;
            pos_rail_work <= 32'd0;
            neg_rail_work <= 32'd0;
            freq_bad_work <= 32'd0;
            phase_bad_work <= 32'd0;
        end else begin
            // 普通采样拍：只更新当前窗口工作寄存器，不改变对外快照。
            window_index <= window_index + {{(WINDOW_LOG2-1){1'b0}}, 1'b1};
            amp_sum_work <= amp_sum_work + amplitude;
            if (amplitude < amp_min_work) amp_min_work <= amplitude;
            if (amplitude > amp_max_work) amp_max_work <= amplitude;
            freq_sum_work <= freq_sum_work + frequency_abs;
            if (frequency_abs > freq_max_work) freq_max_work <= frequency_abs;
            phase_sum_work <= phase_sum_work + phase_abs;
            if (phase_abs > phase_max_work) phase_max_work <= phase_abs;
            if ($signed(loop_output) < output_min_work) output_min_work <= loop_output;
            if ($signed(loop_output) > output_max_work) output_max_work <= loop_output;
            locked_work <= locked_work + locked;
            pos_rail_work <= pos_rail_work + rail_positive;
            neg_rail_work <= neg_rail_work + rail_negative;
            freq_bad_work <= freq_bad_work + frequency_bad;
            phase_bad_work <= phase_bad_work + phase_bad;
        end
    end
end

endmodule
