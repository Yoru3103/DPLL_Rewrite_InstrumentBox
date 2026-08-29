`timescale 1ns / 1ps

// 统计快照 bundled-data CDC：只同步事件 toggle，宽数据总线不逐位加同步器。
// 约束条件：源时钟域在翻转 src_toggle 后，必须保持 src_data 不变直到下一份快照产生。
// toggle 经过两级同步后，宽总线已经稳定多个目的时钟周期，可在目的域一次性锁存。
module adaptive_snapshot_cdc #(
    parameter integer DATA_WIDTH = 672 // 一整份统计快照拼接后的总位宽
) (
    input  wire                  dst_clk,     // 目的时钟，本项目为 125 MHz PS 总线时钟
    input  wire                  dst_reset_n, // 目的域低有效同步复位
    input  wire                  src_toggle,  // 源域每完成一份快照翻转一次
    input  wire [DATA_WIDTH-1:0] src_data,    // 源域保持稳定的整组统计数据
    output reg  [DATA_WIDTH-1:0] dst_data     // 目的域冻结的整组统计数据
);

(* ASYNC_REG = "TRUE" *) reg toggle_meta; // 第一级同步器，允许承受亚稳态
(* ASYNC_REG = "TRUE" *) reg toggle_sync; // 第二级同步器，供目的域逻辑使用
reg toggle_seen;                          // 已处理的 toggle 极性，防止重复锁存

always @(posedge dst_clk) begin
    if (!dst_reset_n) begin
        toggle_meta <= 1'b0;
        toggle_sync <= 1'b0;
        toggle_seen <= 1'b0;
        dst_data <= {DATA_WIDTH{1'b0}};
    end else begin
        toggle_meta <= src_toggle;
        toggle_sync <= toggle_meta;
        if (toggle_sync != toggle_seen) begin
            // 检测到新快照事件后，一拍锁存完整 bundled-data 总线。
            dst_data <= src_data;
            toggle_seen <= toggle_sync;
        end
    end
end

endmodule
