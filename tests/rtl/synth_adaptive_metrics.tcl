# Run from a disposable output directory; resolve inputs relative to this script.
set project_root [file normalize [file join [file dirname [info script]] ../..]]
foreach window_log2 {17 12} {
    create_project -in_memory -part xc7z010clg400-1
    read_verilog [file join $project_root DPLL_Rewrite.srcs/sources_1/Adaptive/adaptive_statistics.v]
    synth_design -top adaptive_statistics -part xc7z010clg400-1 -generic WINDOW_LOG2=$window_log2
    # Both are checked against 125 MHz, stricter than the 3.125 MHz DPLL clock.
    create_clock -name stats_clk -period 8.000 [get_ports clk]
    report_utilization -file metrics_${window_log2}_utilization.rpt
    report_timing_summary -delay_type max -max_paths 10 -file metrics_${window_log2}_timing.rpt
    set critical_path [get_timing_paths -delay_type max -max_paths 1]
    set slack [get_property SLACK $critical_path]
    puts "METRICS_WINDOW_${window_log2}_WNS_NS=$slack"
    if {$slack < 0} { error "Metrics standalone synthesis timing failed" }
    close_project
}
