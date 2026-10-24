param(
    [string]$Python = 'python',
    [string]$PyInstallerPath = '',
    [string]$OutputName = 'viewer_dist'
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$hostRoot = Join-Path $projectRoot 'host'
$distRoot = Join-Path $projectRoot "build\$OutputName"
$workRoot = Join-Path $projectRoot 'build\viewer_build'
$specRoot = Join-Path $projectRoot 'build'

$oldPythonPath = $env:PYTHONPATH
try {
    if ($PyInstallerPath) {
        $resolvedPyInstallerPath = (Resolve-Path -LiteralPath $PyInstallerPath).Path
        $env:PYTHONPATH = if ($oldPythonPath) {
            "$resolvedPyInstallerPath;$oldPythonPath"
        } else {
            $resolvedPyInstallerPath
        }
    }

    & $Python -m PyInstaller `
        --noconfirm `
        --clean `
        --onefile `
        --windowed `
        --name viewer `
        --paths $hostRoot `
        --collect-all h5py `
        --distpath $distRoot `
        --workpath $workRoot `
        --specpath $specRoot `
        --add-data "$(Join-Path $projectRoot 'scripts\run_cypress_transport.ps1');scripts" `
        --add-data "$(Join-Path $hostRoot 'CypressTransport.cs');host" `
        (Join-Path $hostRoot 'viewer.py')
    if ($LASTEXITCODE -ne 0) {
        throw "PyInstaller failed with exit code $LASTEXITCODE"
    }
} finally {
    $env:PYTHONPATH = $oldPythonPath
}

$exe = Join-Path $distRoot 'viewer.exe'
if (!(Test-Path -LiteralPath $exe)) {
    throw "Expected executable was not created: $exe"
}
$dllSource = Join-Path $projectRoot 'build\viewer_dist\CyUSB.dll'
$dllDestination = Join-Path $distRoot 'CyUSB.dll'
if ((Test-Path -LiteralPath $dllSource) -and !(Test-Path -LiteralPath $dllDestination)) {
    Copy-Item -LiteralPath $dllSource -Destination $dllDestination
}
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash
Write-Host "VIEWER_BUILD_PASS: $exe"
Write-Host "SHA256: $hash"
