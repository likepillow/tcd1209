param([string]$VivadoBin = 'C:\Xilinx\Vivado\2018.3\bin')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$testOutput = Join-Path $projectRoot 'build\usb_word_sim'
New-Item -ItemType Directory -Force -Path $testOutput | Out-Null
Push-Location $testOutput
try {
    & (Join-Path $VivadoBin 'xvlog.bat') --sv (Join-Path $projectRoot 'rtl\usb_word_stream.v') (Join-Path $projectRoot 'sim\tb_usb_word_stream.sv')
    if ($LASTEXITCODE) { throw 'xvlog failed' }
    & (Join-Path $VivadoBin 'xelab.bat') tb_usb_word_stream -s usb_word_test
    if ($LASTEXITCODE) { throw 'xelab failed' }
    & (Join-Path $VivadoBin 'xsim.bat') usb_word_test -runall
    if ($LASTEXITCODE) { throw 'xsim failed' }
    if (!(Select-String -Path 'xsim.log' -SimpleMatch 'PASS: USB word stream' -Quiet)) { throw 'USB word simulation did not pass' }
} finally { Pop-Location }
