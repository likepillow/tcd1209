param(
    [string]$VivadoBin = 'C:\Xilinx\Vivado\2018.3\bin',
    [string]$Python = 'C:\Users\JITIANRUI\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$testOutput = Join-Path $projectRoot 'build\phase_sim'
& $Python (Join-Path $projectRoot 'sim\phase_vectors.py') $testOutput
if ($LASTEXITCODE) { throw 'Vector generation failed' }
Push-Location $testOutput
try {
    & (Join-Path $VivadoBin 'xvlog.bat') --sv (Join-Path $projectRoot 'rtl\phase_cordic.v') (Join-Path $projectRoot 'rtl\phase_unwrap.v') (Join-Path $projectRoot 'sim\tb_phase.sv')
    if ($LASTEXITCODE) { throw 'xvlog failed' }
    & (Join-Path $VivadoBin 'xelab.bat') tb_phase -s phase_test
    if ($LASTEXITCODE) { throw 'xelab failed' }
    & (Join-Path $VivadoBin 'xsim.bat') phase_test -runall
    if ($LASTEXITCODE) { throw 'xsim failed' }
    if (!(Select-String -Path 'xsim.log' -SimpleMatch 'PASS: phase pipeline protocol' -Quiet)) { throw 'Simulation did not pass' }
    & $Python (Join-Path $projectRoot 'sim\phase_vectors.py') $testOutput --check
    if ($LASTEXITCODE) { throw 'Phase numerical check failed' }
} finally { Pop-Location }
