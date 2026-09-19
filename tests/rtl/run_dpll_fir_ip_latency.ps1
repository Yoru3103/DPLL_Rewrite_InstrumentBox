param([string]$VivadoBin = 'D:\Xilinx\Vivado\2018.3\bin')
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$source = Join-Path $workspace 'DPLL_Rewrite.srcs\sources_1\DigitalPLL\DDC'
$netlist = Join-Path $source 'ip\fir_compiler_minimumphase\fir_compiler_minimumphase_sim_netlist.vhdl'
if (-not (Test-Path -LiteralPath $netlist -PathType Leaf)) {
    throw 'Generate Output Products for fir_compiler_minimumphase in Vivado before running this real-IP test (generated netlist is not tracked in Git).'
}
$build = Join-Path $workspace 'autotune_complete.sim\dpll_fir_ip_latency_vhdl'
New-Item -ItemType Directory -Path $build -Force | Out-Null
Push-Location -LiteralPath $build
try {
    & (Join-Path $VivadoBin 'xvhdl.bat') --2008 (Join-Path $source 'ip\fir_compiler_minimumphase\fir_compiler_minimumphase_sim_netlist.vhdl') (Join-Path $source 'boxcar_2_pts_filter.vhd') (Join-Path $source 'N_times_clk_FIR_wrapper.vhd') (Join-Path $PSScriptRoot 'tb_dpll_fir_ip_latency.vhd')
    if ($LASTEXITCODE -ne 0) { throw 'FIR latency VHDL compilation failed' }
    & (Join-Path $VivadoBin 'xelab.bat') work.tb_dpll_fir_ip_latency -L unisim -s tb_dpll_fir_ip_latency_sim -debug typical
    if ($LASTEXITCODE -ne 0) { throw 'FIR latency elaboration failed' }
    & (Join-Path $VivadoBin 'xsim.bat') tb_dpll_fir_ip_latency_sim -runall -log dpll_fir_ip_latency.log
    if ($LASTEXITCODE -ne 0) { throw 'FIR latency simulation failed' }
    $log = Get-Content -LiteralPath 'dpll_fir_ip_latency.log' -Raw
    if ($log -notmatch 'PASS: real FIR IP old/new wrappers' -or $log -match 'Failure:|Fatal:') {
        throw 'FIR latency comparison did not complete all assertions'
    }
} finally { Pop-Location }
