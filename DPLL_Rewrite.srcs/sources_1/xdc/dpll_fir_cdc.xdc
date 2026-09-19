# DigitalPLL-only 3.125 MHz -> 250 MHz bundled-data transfer (80:1).
# Source boxcar sum and toggle launch together and hold for 320 ns. The
# two ASYNC_REG stages resolve the toggle before d2/d3 edge detection.
# Earliest data capture is the THIRD fast edge. No exception is applied
# to d1->d2, d2->d3, CE logic, FIR output, or the separate Freq_Meter_H.
# Proof and phase sweep: tests/rtl/README_DPLL_FIR_MULTICYCLE.md.
# Implementation-only, LATE. Object-count assertions run in the dedicated
# build pre-hook and again before final timing/bitstream signoff.
set at_fir_first [get_pins -hier -regexp {^dpll_wrapper_inst/DDC0_inst/ddc_frontend_lowpass_filter_inst_[IQ]/N_times_clk_FIR_wrapper_inst/flag_times_N_d1_reg/D$}]
set at_fir_capture [get_pins -hier -regexp {^dpll_wrapper_inst/DDC0_inst/ddc_frontend_lowpass_filter_inst_[IQ]/N_times_clk_FIR_wrapper_inst/data_times_N_reg\[[0-9]+\]/D$}]
set at_fir_launch [get_cells -hier -regexp {^dpll_wrapper_inst/DDC0_inst/ddc_frontend_lowpass_filter_inst_[IQ]/boxcar_2_pts_filter_inst3/sum_register_reg\[[0-9]+\]$}]
# A metastable first-stage value may delay capture, never advance it.
# Retain hold: the common nominal edge must capture the OLD source flag.
# Fresh implementation only: do not retain an older all-checks exception.
set_false_path -setup -to $at_fir_first
set_multicycle_path 3 -setup -end -from $at_fir_launch -to $at_fir_capture
set_multicycle_path 2 -hold -end -from $at_fir_launch -to $at_fir_capture
