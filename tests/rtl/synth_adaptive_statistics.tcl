read_verilog DPLL_Rewrite.srcs/sources_1/Adaptive/adaptive_statistics.v
synth_design -top adaptive_statistics -part xc7z010clg400-1 -generic WINDOW_LOG2=17
create_clock -name stats_clk -period 8.000 [get_ports clk]
report_utilization
report_timing_summary -delay_type max -max_paths 10
set critical_path [get_timing_paths -delay_type max -max_paths 1]
puts "STAGE3_STATS_WNS_NS=[get_property SLACK $critical_path]"
