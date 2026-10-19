param([string]$VivadoBin = 'C:\Xilinx\Vivado\2018.3\bin')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$testOutput = Join-Path $projectRoot 'build\adc_align_sim'
New-Item -ItemType Directory -Force -Path $testOutput | Out-Null
Push-Location $testOutput
try {
    & (Join-Path $VivadoBin 'xvlog.bat') --sv (Join-Path $projectRoot 'rtl\adc_pixel_align.v') (Join-Path $projectRoot 'rtl\frame_ping_pong.v') (Join-Path $projectRoot 'sim\tb_adc_pixel_align.sv')
    if ($LASTEXITCODE) { throw 'xvlog failed' }
    & (Join-Path $VivadoBin 'xelab.bat') tb_adc_pixel_align -s adc_align_test
    if ($LASTEXITCODE) { throw 'xelab failed' }
    & (Join-Path $VivadoBin 'xsim.bat') adc_align_test -runall
    if ($LASTEXITCODE) { throw 'xsim failed' }
    if (!(Select-String -Path 'xsim.log' -SimpleMatch 'PASS: ADC alignment' -Quiet)) { throw 'Simulation did not pass' }
    if (!(Select-String -Path 'xsim.log' -SimpleMatch 'PASS: ADC to ping-pong crop' -Quiet)) { throw 'Crop integration did not pass' }
} finally { Pop-Location }
