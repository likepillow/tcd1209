param(
    [string]$VivadoBin = 'C:\Xilinx\Vivado\2018.3\bin',
    [string]$Python = 'C:\Users\JITIANRUI\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$testOutput = Join-Path $projectRoot 'build\packet_sim'
New-Item -ItemType Directory -Force -Path $testOutput | Out-Null
& $Python (Join-Path $projectRoot 'sim\test_protocol.py')
if ($LASTEXITCODE) { throw 'Host protocol tests failed' }
& $Python (Join-Path $projectRoot 'sim\packet_vectors.py') $testOutput
if ($LASTEXITCODE) { throw 'Vector generation failed' }
Push-Location $testOutput
try {
    & (Join-Path $VivadoBin 'xvlog.bat') --sv -i $testOutput (Join-Path $projectRoot 'rtl\packet_tx.v') (Join-Path $projectRoot 'sim\tb_packet_tx.sv')
    if ($LASTEXITCODE) { throw 'xvlog failed' }
    & (Join-Path $VivadoBin 'xelab.bat') tb_packet_tx -s packet_test
    if ($LASTEXITCODE) { throw 'xelab failed' }
    & (Join-Path $VivadoBin 'xsim.bat') packet_test -runall
    if ($LASTEXITCODE) { throw 'xsim failed' }
    if (!(Select-String -Path 'xsim.log' -SimpleMatch 'PASS: SPIF transmitter' -Quiet)) { throw 'Simulation did not pass' }
} finally { Pop-Location }
