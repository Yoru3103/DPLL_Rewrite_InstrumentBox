param([switch]$SkipTests)
$ErrorActionPreference = 'Stop'
$rootDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$outDir = Join-Path $rootDir 'autotune_complete.sim'
$srcDir = Join-Path $rootDir 'DPLL_Rewrite.sdk/DPLL_2COM_v2/src'
$bspDir = Join-Path $rootDir 'DPLL_Rewrite.sdk/DPLL_2COM_bsp/ps7_cortexa9_0'
New-Item -ItemType Directory -Force $outDir | Out-Null
function Invoke-Checked([string]$Tool, [string[]]$Arguments) {
    & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Tool failed ($LASTEXITCODE)" }
}
$nativeGcc = (Get-Command gcc -ErrorAction Stop).Source
$armGcc = (Get-Command arm-none-eabi-gcc -ErrorAction Stop).Source
$env:PATH = (Split-Path $nativeGcc) + ';' + $env:PATH
if (-not $SkipTests) {
    foreach ($test in @('test_adaptive_metrics', 'test_autotune_engine')) {
        $cFiles = @((Join-Path $PSScriptRoot "$test.c"), (Join-Path $srcDir 'AdaptiveMetrics.c'))
        if ($test -eq 'test_adaptive_metrics') { $cFiles += Join-Path $srcDir 'AdaptivePlIf.c' }
        else { $cFiles += Join-Path $srcDir 'AutotuneEngine.c' }
        $exe = Join-Path $outDir "$test.exe"
        Invoke-Checked $nativeGcc (@('-std=c99','-Wall','-Wextra','-Werror','-I', (Join-Path $PSScriptRoot 'include'),'-I',$srcDir) + $cFiles + @('-lm','-o',$exe))
        Invoke-Checked $exe @()
    }
    Invoke-Checked 'python' @('-m','unittest','discover','-s',$PSScriptRoot,'-p','test_*.py','-v')
}
$objects = @()
foreach ($name in @('AdaptivePlIf','AdaptiveMetrics','AutotuneEngine','helloworld','platform')) {
    $object = Join-Path $outDir "$name.o"
    $argsList = @('-std=c99','-Wall','-O2','-g','-mcpu=cortex-a9','-mfpu=vfpv3','-mfloat-abi=hard',
                  '-I',(Join-Path $bspDir 'include'),'-c',(Join-Path $srcDir "$name.c"),'-o',$object)
    if ($name -in @('AdaptivePlIf','AdaptiveMetrics','AutotuneEngine')) { $argsList += @('-Wextra','-Werror') }
    Invoke-Checked $armGcc $argsList
    $objects += $object
}
$elf = Join-Path $outDir 'DPLL_2COM_v2_autotune.elf'
Invoke-Checked $armGcc (@('-B',((Split-Path $armGcc).Replace('\','/')+'/'),'-mcpu=cortex-a9','-mfpu=vfpv3','-mfloat-abi=hard','-Wl,-build-id=none',
    "-specs=$srcDir/Xilinx.spec","-Wl,-T,$srcDir/lscript.ld","-Wl,-Map,$outDir/autotune.map",
    '-L',(Join-Path $bspDir 'lib'),'-o',$elf) + $objects + @('-Wl,--start-group,-lxil,-lm,-lgcc,-lc,--end-group'))
Invoke-Checked 'arm-none-eabi-size' @($elf)
Get-FileHash -Algorithm SHA256 -LiteralPath $elf
Write-Output "PASS: complete Autotune ARM build ($elf)"
