param(
    [string]$VivadoBin='C:\Xilinx\Vivado\2018.3\bin',
    [string]$Python='C:\Users\JITIANRUI\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$testOutput=Join-Path $projectRoot 'build\coarse_peak_sim'
& $Python (Join-Path $projectRoot 'sim\coarse_peak_vectors.py') $testOutput
if($LASTEXITCODE){throw 'Vector generation failed'}
Push-Location $testOutput
try {
    & (Join-Path $VivadoBin 'xvlog.bat') --sv (Join-Path $projectRoot 'rtl\coarse_peak_fit.v') (Join-Path $projectRoot 'sim\tb_coarse_peak_fit.sv')
    if($LASTEXITCODE){throw 'Compile failed'}
    & (Join-Path $VivadoBin 'xelab.bat') tb_coarse_peak_fit -s coarse_peak_test
    if($LASTEXITCODE){throw 'Elaboration failed'}
    & (Join-Path $VivadoBin 'xsim.bat') coarse_peak_test -runall
    if($LASTEXITCODE){throw 'Simulation failed'}
    if(!(Select-String -Path xsim.log -SimpleMatch 'PASS: 313 exact coarse peak fits' -Quiet)){throw 'No PASS'}
} finally {Pop-Location}
