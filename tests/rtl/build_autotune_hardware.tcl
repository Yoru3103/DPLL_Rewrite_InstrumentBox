# Vivado 2018.3: vivado -mode batch -source tests/rtl/build_autotune_hardware.tcl
# Uses separate runs; original synth_1/impl_1 and old SDK artifacts are retained.
set root [file normalize [file join [file dirname [info script]] ../..]]
set out [file join $root autotune_complete.sim hardware]
file mkdir $out
# generate_target alone can leave a 2020 DCP beside the updated XCI.
# Force the current two-stage IP netlist before opening/linking the project.
source [file join $root tests rtl rebuild_autotune_vco_ip.tcl]
open_project [file join $root DPLL_Rewrite.xpr]
set cdc_file [file join $root DPLL_Rewrite.srcs sources_1 xdc dpll_fir_cdc.xdc]
if {[llength [get_files -quiet $cdc_file]] == 0} {add_files -fileset constrs_1 $cdc_file}
set_property USED_IN_SYNTHESIS false [get_files $cdc_file]
set_property PROCESSING_ORDER LATE [get_files $cdc_file]
set synth_name autotune_synth_20260920
set impl_name autotune_impl_20260920
if {[llength [get_runs -quiet $synth_name]] == 0} {
    create_run $synth_name -part xc7z010clg400-1 -flow {Vivado Synthesis 2018} -strategy Flow_PerfOptimized_high -constrset constrs_1
}
if {[llength [get_runs -quiet $impl_name]] == 0} {
    create_run $impl_name -part xc7z010clg400-1 -flow {Vivado Implementation 2018} -strategy Performance_ExplorePostRoutePhysOpt -constrset constrs_1 -parent_run $synth_name
}
current_run -synthesis [get_runs $synth_name]
current_run -implementation [get_runs $impl_name]
set_property STEPS.OPT_DESIGN.TCL.PRE [file join $root tests rtl check_autotune_hardware_objects.tcl] [get_runs $impl_name]
# Only reset these dedicated Autotune runs.
reset_run $synth_name
launch_runs $synth_name -jobs 4
wait_on_run $synth_name
if {[get_property PROGRESS [get_runs $synth_name]] ne {100%}} {error {Synthesis failed}}
set route_started [clock seconds]
launch_runs $impl_name -to_step route_design -jobs 4
wait_on_run $impl_name
set impl_status [get_property STATUS [get_runs $impl_name]]
# A route-only run with post-route optimization enabled stops at this state.
if {$impl_status ni {{route_design Complete!} {Not started phys_opt_design (Post-Route)}}} {
    error "Implementation did not complete routing: $impl_status"
}
set run_dir [get_property DIRECTORY [get_runs $impl_name]]
foreach name {.route_design.end.rst red_pitaya_top_routed.dcp} {
    set completed_file [file join $run_dir $name]
    if {![file exists $completed_file] || [file mtime $completed_file] < $route_started} {
        error "Routing did not produce a fresh completion/checkpoint: $name"
    }
}
if {[file exists [file join $run_dir .route_design.error.rst]]} {error {Routing failed}}
# Open the actual route checkpoint; route-only leaves post-route run pending.
open_checkpoint [file join $run_dir red_pitaya_top_routed.dcp]
source [file join $root tests rtl finalize_autotune_hardware.tcl]
close_project
