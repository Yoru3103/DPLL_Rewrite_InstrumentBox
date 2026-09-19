# Run only after the final build/signoff completed successfully.
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$outputPath = Join-Path $workspace 'autotune_complete.sim/hardware'
$sourceFiles = @(
    'DPLL_Rewrite.srcs/sources_1/ReadPitaya/red_pitaya_top.v',
    'DPLL_Rewrite.srcs/sources_1/ReadPitaya/red_pitaya_pwm.sv',
    'DPLL_Rewrite.srcs/sources_1/DigitalPLL/dpll_wrapper.v',
    'DPLL_Rewrite.srcs/sources_1/Freq_Meter/Digital_Freq_Meter.v',
    'DPLL_Rewrite.srcs/sources_1/DigitalPLL/DDC/N_times_clk_FIR_wrapper.vhd',
    'DPLL_Rewrite.srcs/sources_1/DigitalPLL/VCO/PLL_VCO_MUL_DIV.v',
    'DPLL_Rewrite.srcs/sources_1/DigitalPLL/VCO/mult_gen_pll/mult_gen_pll.xci',
    'DPLL_Rewrite.srcs/sources_1/DigitalPLL/VCO/mult_gen_pll/mult_gen_pll.dcp',
    'DPLL_Rewrite.srcs/sources_1/xdc/red_pitaya.xdc',
    'DPLL_Rewrite.srcs/sources_1/xdc/dpll_fir_cdc.xdc'
)
$sourceFiles += Get-ChildItem -LiteralPath (Join-Path $workspace 'DPLL_Rewrite.srcs/sources_1/Adaptive') -File -Filter '*.v' | ForEach-Object { $_.FullName.Substring($workspace.Length + 1).Replace('\', '/') }
$sourceFiles += Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Name -match '^(build|check|finalize|rebuild|report|write)_.*\.(tcl|ps1)$' } | ForEach-Object { 'tests/rtl/' + $_.Name }
$sourceHashes = foreach ($relative in ($sourceFiles | Sort-Object -Unique)) {
    '{0}  {1}' -f (Get-FileHash -LiteralPath (Join-Path $workspace $relative) -Algorithm SHA256).Hash, $relative
}
$sourceHashes | Set-Content -LiteralPath (Join-Path $outputPath 'source_sha256.txt') -Encoding ascii
$artifacts = @('autotune_postroute.dcp', 'red_pitaya_top_autotune.bit', 'red_pitaya_top_autotune.hwdef', 'red_pitaya_top_autotune.hdf', 'timing_summary.rpt', 'fir_first_stage_hold.rpt', 'fir_synchronizer_timing.rpt', 'fir_capture_timing.rpt', 'exceptions.rpt', 'effective_constraints.xdc', 'drc.rpt', 'route_status.rpt', 'source_sha256.txt')
foreach ($optional in @('cdc.rpt', 'cdc_summary.rpt')) {
    if (Test-Path -LiteralPath (Join-Path $outputPath $optional)) { $artifacts += $optional }
}
$artifactHashes = foreach ($name in $artifacts) {
    '{0}  {1}' -f (Get-FileHash -LiteralPath (Join-Path $outputPath $name) -Algorithm SHA256).Hash, $name
}
$artifactHashes | Set-Content -LiteralPath (Join-Path $outputPath 'artifact_sha256.txt') -Encoding ascii
