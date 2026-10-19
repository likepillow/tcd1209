param([string]$VivadoBin = 'C:\Xilinx\Vivado\2018.3\bin')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$testOutput = Join-Path $projectRoot 'build\capture_sim'
New-Item -ItemType Directory -Force -Path $testOutput | Out-Null
Push-Location $testOutput
try {
    & (Join-Path $VivadoBin 'xvlog.bat') --sv (Join-Path $projectRoot 'rtl\frame_ping_pong.v') (Join-Path $projectRoot 'sim\tb_capture_crop.sv')
    if ($LASTEXITCODE) { throw 'xvlog failed' }
    & (Join-Path $VivadoBin 'xelab.bat') tb_capture_crop -s capture_test
    if ($LASTEXITCODE) { throw 'xelab failed' }
    & (Join-Path $VivadoBin 'xsim.bat') capture_test -runall
    if ($LASTEXITCODE) { throw 'xsim failed' }
    if (!(Select-String -Path 'xsim.log' -SimpleMatch 'PASS: 2048-to-1024 crop' -Quiet)) { throw 'Simulation did not pass' }
} finally { Pop-Location }
