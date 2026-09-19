set root [file normalize [file join [file dirname [info script]] ../..]]
create_project -in_memory -part xc7z010clg400-1
set xci [file join $root DPLL_Rewrite.srcs sources_1 DigitalPLL VCO mult_gen_pll mult_gen_pll.xci]
read_ip $xci
set_property GENERATE_SYNTH_CHECKPOINT true [get_files $xci]
if {[get_property CONFIG.PipeStages [get_ips mult_gen_pll]] != 2} {error {VCO IP pipeline configuration mismatch}}
synth_ip -force [get_ips mult_gen_pll]
set generated [get_files -all -of_objects [get_ips mult_gen_pll] -filter {FILE_TYPE == "Design Checkpoint"}]
if {[llength $generated] != 1 || ![file exists [lindex $generated 0]]} {error {VCO OOC checkpoint was not generated}}
puts "VCO_REGENERATED_DCP=$generated"
close_project
