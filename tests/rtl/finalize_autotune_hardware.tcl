# Caller opens a fresh route checkpoint using the setup-only first-stage
# exception. An old checkpoint retaining a hold cut fails finite-slack checks.
set root [file normalize [file join [file dirname [info script]] ../..]]
set out [file join $root autotune_complete.sim hardware]
file mkdir $out
source [file join $root tests rtl check_autotune_hardware_objects.tcl]
read_xdc [file join $root DPLL_Rewrite.srcs sources_1 xdc dpll_fir_cdc.xdc]
phys_opt_design -directive Explore
source [file join $root tests rtl check_autotune_hardware_objects.tcl]
write_checkpoint -force [file join $out autotune_postroute.dcp]
set summary [report_timing_summary -delay_type min_max -max_paths 20 -return_string]
set stream [open [file join $out timing_summary.rpt] w]; puts $stream $summary; close $stream
report_utilization -file [file join $out utilization.rpt]
report_route_status -file [file join $out route_status.rpt]
report_drc -file [file join $out drc.rpt]
report_exceptions -coverage -file [file join $out exceptions.rpt]
write_xdc -force [file join $out effective_constraints.xdc]
report_timing -to $at_fir_first -delay_type min -max_paths 2 -file [file join $out fir_first_stage_hold.rpt]
set first_holds [get_timing_paths -to $at_fir_first -delay_type min -max_paths 2]
proc at_assert_paths {paths expected description} {
    if {[llength $paths] != $expected} {error "$description: paths are missing or cut"}
    foreach path $paths {
        set slack [get_property SLACK $path]
        if {![regexp {^-?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$} $slack]} {
            error "$description: non-finite slack '$slack' (missing timing constraint)"
        }
        if {$slack < 0} {error "$description: negative slack $slack"}
    }
}
at_assert_paths $first_holds 2 {FIR first-stage hold}
set sync_d2 [get_pins -hier -regexp {^dpll_wrapper_inst/DDC0_inst/ddc_frontend_lowpass_filter_inst_[IQ]/N_times_clk_FIR_wrapper_inst/flag_times_N_d2_reg/D$}]
if {[llength $sync_d2] != 2} {error {DPLL synchronizer stage two count mismatch}}
report_timing -to $sync_d2 -delay_type min_max -max_paths 4 -file [file join $out fir_synchronizer_timing.rpt]
set first_ff [get_cells -of_objects $at_fir_first]
foreach type {max min} {
    set sync_paths [get_timing_paths -from $first_ff -to $sync_d2 -delay_type $type -max_paths 2]
    at_assert_paths $sync_paths 2 "FIR d1-to-d2 $type"
}
set selected [get_pins -hier -regexp {^dpll_wrapper_inst/DDC0_inst/ddc_frontend_lowpass_filter_inst_[IQ]/N_times_clk_FIR_wrapper_inst/data_times_N_reg\[[0-9]+\]/D$}]
if {[llength $selected] != 32} {error {DPLL FIR data capture count mismatch}}
report_timing -to $selected -delay_type min_max -max_paths 64 -file [file join $out fir_capture_timing.rpt]
foreach {loop expected} {Digital_Freq_Meter_inst 17 dpll_wrapper_inst 12} {
    set count [llength [get_cells -hier -filter "IS_SEQUENTIAL == 1 && NAME =~ $loop/adaptive_loop_statistics/window_index_reg*"]]
    puts "AUTOTUNE_WINDOW_BITS_${loop}=$count"
    if {$count != $expected} {error "Autotune window width mismatch in $loop: $count"}
}
# Parse all three global signoff numbers, including pulse-width slack.
set found 0
foreach line [split $summary \n] {
    if {[regexp {^\s*(-?[0-9]+\.[0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+([0-9]+)\s+([0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+([0-9]+)\s+([0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+([0-9]+)\s+([0-9]+)\s*$} $line all wns tns setup_fail setup_total whs ths hold_fail hold_total wpws tpws pulse_fail pulse_total]} {set found 1; break}
}
if {!$found} {error {Could not parse global setup/hold/pulse-width timing}}
foreach check {{There are 0 register/latch pins with no clock.} {There are 0 pins that are not constrained for maximum delay.}} {
    if {[string first $check $summary] < 0} {error "Internal timing coverage check failed: $check"}
}
puts "AUTOTUNE_TIMING: WNS=$wns WHS=$whs WPWS=$wpws"
if {$wns < 0 || $whs < 0 || $wpws < 0 || $setup_fail != 0 || $hold_fail != 0 || $pulse_fail != 0} {
    error {Timing did not close; no bitstream generated}
}
# Detailed CDC analysis runs separately (report_autotune_cdc.tcl) because
# Vivado 2018.3 may crash there. Structural/finite-path timing gates above
# are mandatory and are never bypassed by that tool limitation.
report_clock_interaction -file [file join $out clock_interaction.rpt]
write_hwdef -force [file join $out red_pitaya_top_autotune.hwdef]
write_bitstream -force [file join $out red_pitaya_top_autotune.bit]
write_sysdef -force -hwdef [file join $out red_pitaya_top_autotune.hwdef] -bitfile [file join $out red_pitaya_top_autotune.bit] [file join $out red_pitaya_top_autotune.hdf]
puts "AUTOTUNE_BITSTREAM_GENERATED=1 OUTPUT=$out"
