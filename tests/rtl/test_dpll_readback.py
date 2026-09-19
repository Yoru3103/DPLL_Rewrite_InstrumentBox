"""Exercise the production legacy telemetry pre-sampler and read/ACK cases.

Run with Python 3 and Vivado 2018.3 installed. All generated files stay in
ignored autotune_complete.sim/dpll_readback. Full-project synthesis checks
integration; this focused fixture verifies the added sample latency/ACK.
"""
import os
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "DPLL_Rewrite.srcs/sources_1/DigitalPLL/dpll_wrapper.v"


class DpllReadback(unittest.TestCase):
    def test_production_presample_and_ack(self):
        source = SOURCE.read_bytes().decode("latin1")
        sample = re.search(r"reg \[15:0\] legacy_amplitude_bus;.*?end\s*\n", source, re.S).group()
        config = re.search(r"reg \[3:0\] angleSelect_loop;.*?end\s*\n", source, re.S).group()
        cases = []
        for address in range(0x101, 0x108):
            line = re.search(rf"^\s*16'h{address:04X}\s*:.*$", source, re.M).group()
            self.assertIn("sys_ack <= sys_en;", line)
            self.assertNotIn("sys_ack <= sys_en_delay", line)
            cases.append(line)
        self.assertIn(".angleSelect(angleSelect_loop)", source)
        fixture = r"""
`timescale 1ns/1ps
module tb;
reg clk1=0, clk_dpll=0, rst=0, sys_en=0;
always #4 clk1=~clk1;
always #160 clk_dpll=~clk_dpll;
reg [3:0] angleSelect_0=0;
reg [15:0] cmd_addr=0;
reg [15:0] DDC_Amplitude_0=0;
reg [13:0] wrapped_phase0=0, inst_frequency0=0;
reg [31:0] pll0_output=0, PID_OUT_With_Limit=0;
reg [31:0] phase_residuals0=0, pll_output_average_value=0;
reg sys_ack=0;
reg [31:0] sys_rdata;
__CONFIG__
__SAMPLE__
always @(posedge clk1) begin
 if (!rst) sys_ack <= 0;
 else case (cmd_addr)
__CASES__
 default: begin sys_ack <= sys_en; sys_rdata <= 0; end
 endcase
end
integer i;
reg [31:0] expected;
initial begin
 repeat(2) @(negedge clk1);
 rst=1;
 // Distinct bit patterns verify all seven register mappings and widths.
 DDC_Amplitude_0=16'hfedc; wrapped_phase0=14'h3abc;
 inst_frequency0=14'h2fed; pll0_output=32'h87654321;
 PID_OUT_With_Limit=32'h80000001; phase_residuals0=32'hffffffef;
 pll_output_average_value=32'h12345678;
 @(negedge clk1);
 for(i=1;i<=7;i=i+1) begin
   cmd_addr=16'h100+i; sys_en=1;
   case(i)
    1:expected=32'hfedc; 2:expected=32'h3abc; 3:expected=32'h2fed;
    4:expected=32'h87654321; 5:expected=32'h80000001;
    6:expected=32'hffffffef; 7:expected=32'h12345678;
   endcase
   @(posedge clk1); #1;
   if(sys_ack !== 1 || sys_rdata !== expected) $fatal(1,"read/ack mapping %d",i);
   @(negedge clk1); sys_en=0;
   @(posedge clk1); #1;
   if(sys_ack !== 0) $fatal(1,"ACK remained asserted without request");
   @(negedge clk1);
 end
 // A live value changes immediately before a request: read mux uses prior
 // bus sample, then refreshes next beat without inserting an ACK bubble.
 cmd_addr=16'h0104; sys_en=1; pll0_output=32'h11223344;
 @(posedge clk1); #1;
 if(sys_ack !== 1 || sys_rdata !== 32'h87654321) $fatal(1,"missing one-sample delay");
 @(posedge clk1); #1;
 if(sys_ack !== 1 || sys_rdata !== 32'h11223344) $fatal(1,"telemetry stale beyond one bus beat");
 @(negedge clk_dpll); angleSelect_0=4'h9;
 @(posedge clk_dpll); #1;
 if(angleSelect_loop !== 4'h9) $fatal(1,"selector did not latch on loop clock");
 rst=0;
 @(posedge clk_dpll); #1;
 if(angleSelect_loop !== 0 || sys_ack !== 0) $fatal(1,"reset semantics");
 $display("PASS: DPLL readback presample/ACK and local selector"); $finish;
end
initial begin #2000; $fatal(1,"timeout"); end
endmodule
"""
        fixture = fixture.replace("__CONFIG__", config).replace("__SAMPLE__", sample).replace("__CASES__", "\n".join(cases))
        output = ROOT / "autotune_complete.sim/dpll_readback"
        output.mkdir(parents=True, exist_ok=True)
        (output / "tb.sv").write_text(fixture, encoding="ascii")
        binary = Path(os.environ.get("VIVADO_BIN", "D:/Xilinx/Vivado/2018.3/bin"))
        for command in [("xvlog", "-sv", "tb.sv"), ("xelab", "tb", "-s", "readback_sim"), ("xsim", "readback_sim", "-runall", "-log", "readback.log")]:
            run = subprocess.run([str(binary / (command[0] + ".bat")), *command[1:]], cwd=output, capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("PASS: DPLL readback", (output / "readback.log").read_text())


if __name__ == "__main__":
    unittest.main()
