# Run after link_design: fail closed if hierarchy/width changes.
set at_fir_first [get_pins -hier -regexp {^dpll_wrapper_inst/DDC0_inst/ddc_frontend_lowpass_filter_inst_[IQ]/N_times_clk_FIR_wrapper_inst/flag_times_N_d1_reg/D$}]
set at_fir_capture [get_pins -hier -regexp {^dpll_wrapper_inst/DDC0_inst/ddc_frontend_lowpass_filter_inst_[IQ]/N_times_clk_FIR_wrapper_inst/data_times_N_reg\[[0-9]+\]/D$}]
set at_fir_launch [get_cells -hier -regexp {^dpll_wrapper_inst/DDC0_inst/ddc_frontend_lowpass_filter_inst_[IQ]/boxcar_2_pts_filter_inst3/sum_register_reg\[[0-9]+\]$}]
if {[llength $at_fir_first] != 2 || [llength $at_fir_capture] != 32 || [llength $at_fir_launch] != 32} {
    error "DPLL FIR CDC selector mismatch: first=[llength $at_fir_first] capture=[llength $at_fir_capture] launch=[llength $at_fir_launch]"
}
set at_fir_sync [get_cells -hier -regexp {^dpll_wrapper_inst/DDC0_inst/ddc_frontend_lowpass_filter_inst_[IQ]/N_times_clk_FIR_wrapper_inst/flag_times_N_d[12]_reg$}]
if {[llength $at_fir_sync] != 4} {error {DPLL FIR requires four synchronizer FFs}}
foreach cell $at_fir_sync {
    if {![get_property ASYNC_REG $cell]} {error "Missing ASYNC_REG on $cell"}
}
puts {DPLL_FIR_OBJECTS: first_D=2 data_D=32 launch_FF=32 ASYNC_REG_FF=4}
