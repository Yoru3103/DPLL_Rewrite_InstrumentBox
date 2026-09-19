param([string]$VivadoBin = 'D:\Xilinx\Vivado\2018.3\bin')
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$outputPath = Join-Path $workspace 'autotune_complete.sim/vco_pipeline'
$vco = Join-Path $workspace 'DPLL_Rewrite.srcs/sources_1/DigitalPLL/VCO'
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
# Both wrappers bind the installed Xilinx model. Only name and latency differ.
$model = [IO.File]::ReadAllText((Join-Path $vco 'mult_gen_pll/sim/mult_gen_pll.vhd'))
if ($model -notmatch 'C_LATENCY\s*=>\s*2\s*,') { throw 'Generate the production two-stage IP simulation target first' }
$reference = $model.Replace('mult_gen_pll', 'mult_gen_pll_reference') -replace '(C_LATENCY\s*=>\s*)2\s*,', '${1}1,'
[IO.File]::WriteAllText((Join-Path $outputPath 'mult_gen_pll_reference.vhd'), $reference, [Text.Encoding]::ASCII)
Push-Location $outputPath
try {
    & (Join-Path $VivadoBin 'xvhdl.bat') --work work `
        (Join-Path $vco 'mult_gen_pll/sim/mult_gen_pll.vhd') `
        (Join-Path $outputPath 'mult_gen_pll_reference.vhd') `
        (Join-Path $vco 'div_gen_pll/sim/div_gen_pll.vhd')
    if ($LASTEXITCODE -ne 0) { throw 'VCO vendor model compilation failed' }
    & (Join-Path $VivadoBin 'xvlog.bat') -sv --work work `
        (Join-Path $vco 'PLL_VCO_MUL_DIV.v') `
        (Join-Path $PSScriptRoot 'pll_vco_mul_div_reference.v') `
        (Join-Path $PSScriptRoot 'tb_vco_pipeline.sv')
    if ($LASTEXITCODE -ne 0) { throw 'VCO RTL compilation failed' }
    & (Join-Path $VivadoBin 'xelab.bat') --relax --debug typical --mt 4 `
        -L xbip_utils_v3_0_9 -L axi_utils_v2_0_5 -L xbip_pipe_v3_0_5 `
        -L xbip_dsp48_wrapper_v3_0_4 -L xbip_dsp48_addsub_v3_0_5 -L xbip_bram18k_v3_0_5 `
        -L mult_gen_v12_0_14 -L floating_point_v7_0_15 -L xbip_dsp48_mult_v3_0_5 `
        -L xbip_dsp48_multadd_v3_0_5 -L div_gen_v5_1_14 -L unisims_ver -L secureip `
        work.tb_vco_pipeline -s tb_vco_pipeline_sim -timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) { throw 'VCO elaboration failed' }
    & (Join-Path $VivadoBin 'xsim.bat') tb_vco_pipeline_sim -runall -log vco_pipeline.log
    if ($LASTEXITCODE -ne 0 -or -not (Select-String -LiteralPath vco_pipeline.log -Pattern 'PASS: VCO pipeline equivalence')) {
        throw 'VCO actual IP pipeline equivalence failed'
    }
} finally { Pop-Location }
