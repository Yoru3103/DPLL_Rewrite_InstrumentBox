# Run separately after build_autotune_hardware.tcl; preserve primary artifacts
# if Vivado 2018.3 crashes during the optional diagnostic report.
set root [file normalize [file join [file dirname [info script]] ../..]]
set out [file join $root autotune_complete.sim hardware]
# An interrupted report must never leave a previous report at the final name.
foreach name {cdc.rpt cdc_summary.rpt cdc_pending.rpt} {
    set previous [file join $out $name]
    if {[file exists $previous]} {
        file rename -force $previous [file join $out "[file rootname $name]_previous_[clock seconds].rpt"]
    }
}
set_param general.maxThreads 1
open_checkpoint [file join $out autotune_postroute.dcp]
report_clock_interaction -file [file join $out clock_interaction.rpt]
report_cdc -summary -file [file join $out cdc_summary.rpt]
puts {AUTOTUNE_CDC_SUMMARY_COMPLETED=1}
report_cdc -details -file [file join $out cdc_pending.rpt]
file rename -force [file join $out cdc_pending.rpt] [file join $out cdc.rpt]
close_design
puts {AUTOTUNE_CDC_REPORT_COMPLETED=1}
