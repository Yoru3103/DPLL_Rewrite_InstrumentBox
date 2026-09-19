param(
    [string]$VivadoBin = 'D:\Xilinx\Vivado\2018.3\bin'
)
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$build = Join-Path $workspace 'autotune_complete.sim\dpll_fir_multicycle'
New-Item -ItemType Directory -Path $build -Force | Out-Null
$boxcar = Join-Path $workspace 'DPLL_Rewrite.srcs\sources_1\DigitalPLL\DDC\boxcar_2_pts_filter.vhd'
$wrapper = Join-Path $workspace 'DPLL_Rewrite.srcs\sources_1\DigitalPLL\DDC\N_times_clk_FIR_wrapper.vhd'
$bench = Join-Path $PSScriptRoot 'tb_dpll_fir_multicycle.vhd'
Push-Location -LiteralPath $build
try {
    & (Join-Path $VivadoBin 'xvhdl.bat') --2008 $boxcar $wrapper $bench
    if ($LASTEXITCODE -ne 0) { throw 'DPLL FIR crossing VHDL compilation failed' }
    & (Join-Path $VivadoBin 'xelab.bat') work.tb_dpll_fir_multicycle -s tb_dpll_fir_multicycle_sim -debug typical
    if ($LASTEXITCODE -ne 0) { throw 'DPLL FIR crossing elaboration failed' }
    & (Join-Path $VivadoBin 'xsim.bat') tb_dpll_fir_multicycle_sim -runall -log dpll_fir_multicycle.log
    if ($LASTEXITCODE -ne 0) { throw 'DPLL FIR crossing simulation failed' }
    $log = Get-Content -LiteralPath 'dpll_fir_multicycle.log' -Raw
    if ($log -notmatch 'PASS: production boxcar and FIR wrapper' -or $log -match 'Failure:|Fatal:') {
        throw 'DPLL FIR crossing did not complete all assertions'
    }
} finally {
    Pop-Location
}
