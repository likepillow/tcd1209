param([string]$VivadoBin='C:\Xilinx\Vivado\2018.3\bin')
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$testOutput=Join-Path $projectRoot 'build\clipping_sim'
New-Item -ItemType Directory -Force -Path $testOutput | Out-Null
Push-Location $testOutput
try {
    & (Join-Path $VivadoBin 'xvlog.bat') --sv (Join-Path $projectRoot 'rtl\normalize_frame.v') (Join-Path $projectRoot 'sim\tb_normalize_clipping.sv')
    if($LASTEXITCODE){throw 'xvlog failed'}
    & (Join-Path $VivadoBin 'xelab.bat') tb_normalize_clipping -s clipping_test
    if($LASTEXITCODE){throw 'xelab failed'}
    & (Join-Path $VivadoBin 'xsim.bat') clipping_test -runall
    if($LASTEXITCODE){throw 'xsim failed'}
    if(!(Select-String -Path xsim.log -SimpleMatch 'PASS: clipping' -Quiet)){throw 'Clipping simulation failed'}
} finally {Pop-Location}
