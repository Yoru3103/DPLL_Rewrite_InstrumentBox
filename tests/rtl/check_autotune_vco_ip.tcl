# Fail closed if implementation links the stale one-stage IP checkpoint.
set at_vco_dsps [get_cells -hier -filter {REF_NAME == DSP48E1 && NAME =~ dpll_wrapper_inst/VCO0_mul_div/VCO0_Multiplier/*}]
if {[llength $at_vco_dsps] != 3} {error {VCO multiplier DSP count mismatch}}
set at_vco_indices {}
foreach d $at_vco_dsps {
    if {![regexp {appDSP48\[([0-2])\]} $d match index]} {error "VCO DSP hierarchy mismatch: $d"}
    lappend at_vco_indices $index
    set a [get_property AREG $d]
    set b [get_property BREG $d]
    set m [get_property MREG $d]
    set p [get_property PREG $d]
    puts "VCO_DSP_PIPELINE index=$index AREG=$a BREG=$b MREG=$m PREG=$p"
    if {$a < 1 || $m != 0 || ($index == 0 && $b < 1) || ($index == 2 && $p != 1)} {
        error {VCO DSP input pipeline does not match the verified two-stage IP}
    }
}
if {[lsort $at_vco_indices] ne {0 1 2}} {error {VCO DSP index mismatch}}
