param(
    [string]$VivadoBin = 'C:\Xilinx\Vivado\2018.3\bin',
    [string]$Python = 'C:\Users\JITIANRUI\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$testOutput = Join-Path $projectRoot 'build\normalize_sim'
New-Item -ItemType Directory -Force -Path $testOutput | Out-Null
& $Python (Join-Path $projectRoot 'sim\normalization_vectors.py') $testOutput
if ($LASTEXITCODE) { throw 'Vector generation failed' }
Push-Location $testOutput
try {
    & (Join-Path $VivadoBin 'xvlog.bat') --sv (Join-Path $projectRoot 'rtl\normalize_frame.v') (Join-Path $projectRoot 'sim\tb_normalize_frame.sv')
    if ($LASTEXITCODE) { throw 'xvlog failed' }
    & (Join-Path $VivadoBin 'xelab.bat') tb_normalize_frame -s normalize_test
    if ($LASTEXITCODE) { throw 'xelab failed' }
    & (Join-Path $VivadoBin 'xsim.bat') normalize_test -runall
    if ($LASTEXITCODE) { throw 'xsim failed' }
    if (!(Select-String -Path 'xsim.log' -SimpleMatch 'PASS: 2048 bit-exact' -Quiet)) { throw 'Simulation did not pass' }
} finally { Pop-Location }
