# Package only this build's timing-checked hardware, rebuilt FSBL and application.
# Run tests/rtl/build_autotune_hardware.tcl first. No board is programmed.
param([string]$Bootgen = 'D:\Xilinx\SDK\2018.3\bin\bootgen.bat')
$ErrorActionPreference = 'Stop'
$rootDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$buildDir = Join-Path $rootDir 'autotune_complete.sim'
$hardwareDir = Join-Path $buildDir 'hardware'
$bit = Join-Path $hardwareDir 'red_pitaya_top_autotune.bit'
$timing = Join-Path $hardwareDir 'timing_summary.rpt'
$checkpoint = Join-Path $hardwareDir 'autotune_postroute.dcp'
$hardwareExport = Join-Path $hardwareDir 'red_pitaya_top_autotune.hdf'
foreach ($path in @($bit,$timing,$checkpoint,$hardwareExport)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing hardware artifact: $path" }
}
# Match the global WNS/TNS/endpoints/WHS/THS/endpoints/WPWS/TPWS/endpoints row.
$float = '(-?\d+\.\d+)'
$number = '(\d+)'
$pattern = '(?m)^\s*' + (($float,$float,$number,$number,$float,$float,$number,$number,$float,$float,$number,$number) -join '\s+') + '\s*$'
$match = [regex]::Match([IO.File]::ReadAllText($timing),$pattern)
if (-not $match.Success) { throw 'Cannot parse global hardware timing summary' }
foreach ($index in @(1,5,9)) {
    if ([double]::Parse($match.Groups[$index].Value,[Globalization.CultureInfo]::InvariantCulture) -lt 0) { throw 'Hardware timing did not pass' }
}
foreach ($index in @(3,7,11)) {
    if ([int64]$match.Groups[$index].Value -ne 0) { throw 'Hardware timing has failing endpoints' }
}
$bitTime = (Get-Item -LiteralPath $bit).LastWriteTimeUtc
foreach ($path in @($timing,$checkpoint)) {
    if ((Get-Item -LiteralPath $path).LastWriteTimeUtc -gt $bitTime) { throw 'Bitstream predates its verification artifacts' }
}
# Reject a stale previous bit after source edits or a failed rebuild. This is a
# local build freshness check, not a replacement for the full hardware flow.
$extensions = @('.v','.sv','.vhd','.vhdl','.xdc','.xci','.bd','.coe','.mem','.mif')
$newerSource = Get-ChildItem -LiteralPath (Join-Path $rootDir 'DPLL_Rewrite.srcs/sources_1') -File -Recurse |
    Where-Object { $_.Extension -in $extensions -and $_.LastWriteTimeUtc -gt $bitTime } |
    Select-Object -First 1
if ($newerSource) { throw "Hardware source is newer than bitstream: $($newerSource.FullName)" }
& (Join-Path $PSScriptRoot 'build_autotune.ps1') -SkipTests
& (Join-Path $PSScriptRoot 'build_autotune_fsbl.ps1')
$fsbl = Join-Path $buildDir 'fsbl/autotune_fsbl.elf'
$elf = Join-Path $buildDir 'DPLL_2COM_v2_autotune.elf'
$outDir = Join-Path $buildDir 'bootimage'
New-Item -ItemType Directory -Force $outDir | Out-Null
$bif = Join-Path $outDir 'autotune.bif'
$boot = Join-Path $outDir 'BOOT_autotune.bin'
$bifText = "the_ROM_image:`n{`n    [bootloader] `"$($fsbl.Replace('\','/'))`"`n    `"$($bit.Replace('\','/'))`"`n    `"$($elf.Replace('\','/'))`"`n}`n"
[IO.File]::WriteAllText($bif,$bifText,(New-Object Text.UTF8Encoding($false)))
& $Bootgen -arch zynq -image $bif -o $boot -w on
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $boot)) { throw 'Bootgen failed' }
$hashes = @(Get-FileHash -Algorithm SHA256 -LiteralPath $fsbl,$bit,$elf,$boot,$timing,$checkpoint,$hardwareExport)
$manifest = [ordered]@{
    generated_utc = [DateTime]::UtcNow.ToString('o')
    setup_wns_ns = $match.Groups[1].Value
    hold_whs_ns = $match.Groups[5].Value
    pulse_width_slack_ns = $match.Groups[9].Value
    artifacts = @($hashes | Select-Object Path,Hash,Algorithm)
    board_validation = 'Not flashed or validated on hardware by this build script'
}
[IO.File]::WriteAllText((Join-Path $outDir 'manifest.json'),($manifest | ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
$hashes
Write-Output "PASS: packaged local Autotune boot image ($boot)"