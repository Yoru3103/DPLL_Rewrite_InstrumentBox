`timescale 1ns/1ps
// Actual vendor multiplier/divider models; the reference is the unchanged old wrapper.
module vco_pipeline_fixture #(parameter integer OFFSET = 0)(output reg done = 0);
  reg clk = 0;
  reg slow = 0;
  reg [47:0] data_in = 0;
  reg [15:0] mul = 1, div = 1;
  wire [47:0] old_out, new_out;
  integer cycle = 0, accepted = 0, outputs = 0, compared = 0;
  reg old_in_valid = 0, old_out_valid = 0;
  reg [63:0] old_product = 0;
  reg [15:0] old_div = 0;
  reg [47:0] old_output = 0;
  reg output_known = 0;
  reg [31:0] rng = 32'h8fe193ab + OFFSET;
  always #4 clk = ~clk;
  initial begin
    #(OFFSET);
    repeat (2000) #160 slow = ~slow; // 1000 samples, then drain the divider pipeline.
  end
  PLL_VCO_MUL_DIV_reference reference_i(clk, slow, data_in, old_out, mul, div);
  PLL_VCO_MUL_DIV dut(clk, slow, data_in, new_out, mul, div);
  function [31:0] next_random(input [31:0] r);
    reg [31:0] x;
    begin x = r ^ (r << 13); x = x ^ (x >> 17); next_random = x ^ (x << 5); end
  endfunction
  function [47:0] edge_data(input integer i);
    case (i % 8)
      0: edge_data = 0;
      1: edge_data = 1;
      2: edge_data = 48'h7fffffffffff;
      3: edge_data = 48'h800000000000;
      4: edge_data = 48'hffffffffffff;
      5: edge_data = 48'h0000ffffffff;
      6: edge_data = 48'hffff00000000;
      7: edge_data = 48'h5555aaaaaaaa;
    endcase
  endfunction
  function [15:0] edge_factor(input integer i);
    case (i % 6)
      0: edge_factor = 1;
      1: edge_factor = 8;
      2: edge_factor = 16'h7fff;
      3: edge_factor = 16'h8000;
      4: edge_factor = 16'hffff;
      5: edge_factor = 16'h5555;
    endcase
  endfunction
  always @(negedge clk) begin
    if (cycle < 12000) begin
      // Hold each boundary sample across a complete slow-clock interval.
      data_in = edge_data(cycle / 40);
      mul = edge_factor(cycle / 320);
      div = edge_factor(cycle / 1920);
    end else begin
      // Factors change on every fast clock, including both sides of accept.
      rng = next_random(rng); data_in[31:0] = rng;
      rng = next_random(rng); data_in[47:32] = rng[15:0];
      rng = next_random(rng); mul = rng[15:0];
      rng = next_random(rng); div = rng[15:0] | 16'h0001;
    end
  end
  always @(posedge clk) begin
    // Compare the operands at the edge on which the real divider samples them.
    if (cycle > 1) begin
      if (dut.clk_data_ready_reg_d2 !== old_in_valid)
        $fatal(1, "input valid mismatch offset=%0d cycle=%0d", OFFSET, cycle);
      if (dut.clk_data_ready_reg_d2) begin
        if (dut.PLL_Mul_Data !== old_product || dut.pll_div_factor_d1 !== old_div)
          $fatal(1, "accepted operand mismatch offset=%0d cycle=%0d", OFFSET, cycle);
        accepted = accepted + 1;
      end
    end
    old_in_valid = reference_i.clk_data_ready_reg_d1;
    old_product = reference_i.PLL_Mul_Data;
    old_div = div;
    #1;
    if (cycle > 1 && dut.m_axis_data_tvalid !== old_out_valid)
      $fatal(1, "divider valid mismatch offset=%0d cycle=%0d", OFFSET, cycle);
    if (dut.m_axis_data_tvalid) outputs = outputs + 1;
    if (output_known) begin
      if (new_out !== old_output)
        $fatal(1, "output mismatch offset=%0d cycle=%0d old=%h new=%h", OFFSET, cycle, old_output, new_out);
      compared = compared + 1;
    end
    old_out_valid = reference_i.m_axis_data_tvalid;
    old_output = old_out;
    output_known = (^old_out !== 1'bx);
    cycle = cycle + 1;
    if (cycle == 40400) begin
      if (accepted != 1000 || outputs != 1000 || compared < 39000)
        $fatal(1, "insufficient coverage %0d %0d %0d", accepted, outputs, compared);
      $display("PASS: VCO actual IP offset=%0d accepted=%0d outputs=%0d compared=%0d", OFFSET, accepted, outputs, compared);
      done = 1;
    end
  end
endmodule

module tb_vco_pipeline;
  wire done0, done4;
  vco_pipeline_fixture #(.OFFSET(0)) a(done0);
  vco_pipeline_fixture #(.OFFSET(4)) b(done4);
  reg clk = 0;
  reg [47:0] a_in = 0;
  reg [15:0] b_in = 0;
  wire [63:0] p1, p2;
  reg [63:0] previous = 0, expected = 0;
  reg [31:0] rng = 32'h35df234c;
  integer count = 0;
  always #4 clk = ~clk;
  mult_gen_pll_reference one_stage(clk, a_in, b_in, p1);
  mult_gen_pll two_stage(clk, a_in, b_in, p2);
  always @(negedge clk) begin
    rng = (rng ^ (rng << 13)); rng = (rng ^ (rng >> 17)); rng = rng ^ (rng << 5);
    a_in = {rng[15:0], rng};
    b_in = rng[31:16];
    if (count < 8) begin a_in = count[0] ? 48'hffffffffffff : 0; b_in = count[1] ? 16'hffff : 0; end
  end
  always @(posedge clk) begin
    expected = a_in * b_in;
    #1;
    if (p1 !== expected) $fatal(1, "one-stage actual IP arithmetic mismatch cycle %0d", count);
    if (count > 0 && p2 !== previous) $fatal(1, "actual IP product pipeline mismatch cycle %0d", count);
    previous = p1;
    count = count + 1;
    if (done0 && done4) begin
      $display("PASS: VCO pipeline equivalence, actual IP models, 8 ns fixed latency, dynamic factors and %0d multiplier pairs", count);
      $finish;
    end
  end
  initial begin #400000; $fatal(1, "timeout"); end
endmodule
