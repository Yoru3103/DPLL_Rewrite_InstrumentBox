param([string]$VivadoBin = 'D:\Xilinx\Vivado\2018.3\bin')
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$outputPath = Join-Path $workspace 'autotune_complete.sim/hardware'
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
Push-Location $outputPath
try {
    & (Join-Path $VivadoBin 'vivado.bat') -mode batch -nojournal -log build.log -source (Join-Path $PSScriptRoot 'build_autotune_hardware.tcl')
    if ($LASTEXITCODE -ne 0 -or -not (Select-String -LiteralPath build.log -Pattern '^AUTOTUNE_BITSTREAM_GENERATED=1 OUTPUT=')) { throw 'Autotune hardware build/signoff failed; do not use stale output files' }
    # CDC is a separate process: some 2018.3 builds crash in report_cdc.
    & (Join-Path $VivadoBin 'vivado.bat') -mode batch -nojournal -log cdc.log -source (Join-Path $PSScriptRoot 'report_autotune_cdc.tcl')
    if ($LASTEXITCODE -ne 0 -or -not (Select-String -LiteralPath cdc.log -Pattern 'AUTOTUNE_CDC_REPORT_COMPLETED=1')) {
        Write-Warning 'CDC report is unavailable: inspect cdc.log; do not claim CDC reporting passed.'
    }
    & (Join-Path $PSScriptRoot 'write_autotune_hardware_manifest.ps1')
} finally { Pop-Location }
