$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$vivado = 'C:\Xilinx\Vivado\2018.3\bin\vivado.bat'
$bit = Join-Path $projectRoot 'build/diag/diagnostic.bit'
if ((Get-FileHash -LiteralPath $bit -Algorithm SHA256).Hash -ne '4D33F7911E415EB0776AE5767179C029EA353E038358DE5CD5B36E364C76163E') {
    throw 'Diagnostic bitstream has changed; review before programming'
}
foreach ($name in 'replacement_20260920_sh','replacement_20260920_pixels') {
    if (Test-Path (Join-Path $projectRoot "build/hardware_frames/$name.csv")) { throw "Capture already exists: $name" }
}
Push-Location (Join-Path $projectRoot 'build')
try {
    & $vivado -mode batch -source (Join-Path $PSScriptRoot 'program_diagnostic.tcl') -log replacement_program.log -journal replacement_program.jou -tclargs $projectRoot
    if ($LASTEXITCODE) { throw 'Diagnostic programming failed' }
    foreach ($mode in 'sh','pixels') {
        & $vivado -mode batch -source (Join-Path $PSScriptRoot 'capture_diagnostic_frames.tcl') -log "replacement_$mode.log" -journal "replacement_$mode.jou" -tclargs $projectRoot "replacement_20260920_$mode" $mode
        if ($LASTEXITCODE) { throw "Capture failed: $mode; inspect restoration status before continuing" }
    }
} finally { Pop-Location }
