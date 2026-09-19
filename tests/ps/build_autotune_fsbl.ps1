# Rebuild the existing FSBL sources against the current Vivado PS initialization.
# Output stays in the ignored Autotune build directory; this does not flash a board.
$ErrorActionPreference = 'Stop'
$rootDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$outDir = Join-Path $rootDir 'autotune_complete.sim/fsbl'
$srcDir = Join-Path $rootDir 'DPLL_Rewrite.sdk/DPLL_i_FSBL/src'
$bspDir = Join-Path $rootDir 'DPLL_Rewrite.sdk/DPLL_i_FSBL_bsp/ps7_cortexa9_0'
$psDir = Join-Path $rootDir 'DPLL_Rewrite.srcs/sources_1/bd/system/ip/system_processing_system7_0_0'
$compiler = (Get-Command arm-none-eabi-gcc -ErrorAction Stop).Source
New-Item -ItemType Directory -Force $outDir | Out-Null
function Invoke-Checked([string]$Tool, [string[]]$Arguments) {
    & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Tool failed ($LASTEXITCODE)" }
}
$files = @('fsbl_handoff.S','fsbl_hooks.c','image_mover.c','main.c','md5.c',
           'nand.c','nor.c','pcap.c','qspi.c','rsa.c','sd.c')
$files = @($files | ForEach-Object { Join-Path $srcDir $_ })
$files += Join-Path $psDir 'ps7_init.c'
$objects = @()
foreach ($file in $files) {
    $object = Join-Path $outDir ([IO.Path]::GetFileNameWithoutExtension($file)+'.o')
    Invoke-Checked $compiler @('-Wall','-O2','-mcpu=cortex-a9','-mfpu=vfpv3','-mfloat-abi=hard',
        '-I',$psDir,'-I',(Join-Path $bspDir 'include'),'-c',$file,'-o',$object)
    $objects += $object
}
$elf = Join-Path $outDir 'autotune_fsbl.elf'
Invoke-Checked $compiler (@('-B',((Split-Path $compiler).Replace('\','/')+'/'),
    '-mcpu=cortex-a9','-mfpu=vfpv3','-mfloat-abi=hard','-Wl,-build-id=none',
    "-specs=$srcDir/Xilinx.spec","-Wl,-T,$srcDir/lscript.ld",'-L',(Join-Path $bspDir 'lib'),
    '-o',$elf) + $objects + @('-Wl,--start-group,-lxilffs,-lrsa,-lxil,-lgcc,-lc,--end-group'))
Invoke-Checked 'arm-none-eabi-size' @($elf)
Get-FileHash -Algorithm SHA256 -LiteralPath $elf,(Join-Path $psDir 'ps7_init.c')
Write-Output "PASS: rebuilt Autotune FSBL ($elf)"