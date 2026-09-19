param([string]$VivadoBin = 'D:\Xilinx\Vivado\2018.3\bin')
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$outputPath = Join-Path $workspace 'autotune_complete.sim/pwm_equivalence'
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
Push-Location $outputPath
try {
    & (Join-Path $VivadoBin 'xvlog.bat') -sv `
        (Join-Path $workspace 'DPLL_Rewrite.srcs/sources_1/ReadPitaya/red_pitaya_pwm.sv') `
        (Join-Path $PSScriptRoot 'pwm_reference.sv') `
        (Join-Path $PSScriptRoot 'tb_pwm_equivalence.sv')
    if ($LASTEXITCODE -ne 0) { throw 'PWM compilation failed' }
    & (Join-Path $VivadoBin 'xelab.bat') tb_pwm_equivalence -s tb_pwm_equivalence_sim -timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) { throw 'PWM elaboration failed' }
    & (Join-Path $VivadoBin 'xsim.bat') tb_pwm_equivalence_sim -runall -log pwm_equivalence.log
    if ($LASTEXITCODE -ne 0 -or -not (Select-String -LiteralPath pwm_equivalence.log -Pattern 'PASS: PWM cycle equivalence')) {
        throw 'PWM cycle equivalence failed'
    }
} finally {
    Pop-Location
}
