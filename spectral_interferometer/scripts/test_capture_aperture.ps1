param([string]$VivadoBin = 'C:\Xilinx\Vivado\2018.3\bin')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$testOutput = Join-Path $projectRoot 'build\capture_aperture_sim'
New-Item -ItemType Directory -Force -Path $testOutput | Out-Null
Push-Location $testOutput
try {
    & (Join-Path $VivadoBin 'xvlog.bat') --sv (Join-Path $projectRoot 'rtl\adc_pixel_align.v') (Join-Path $projectRoot 'sim\tb_adc_capture_aperture.sv')
    if ($LASTEXITCODE) { throw 'xvlog failed' }
    & (Join-Path $VivadoBin 'xelab.bat') tb_adc_capture_aperture -s capture_aperture
    if ($LASTEXITCODE) { throw 'xelab failed' }
    & (Join-Path $VivadoBin 'xsim.bat') capture_aperture -runall
    if ($LASTEXITCODE) { throw 'xsim failed' }
    if (!(Select-String -Path 'xsim.log' -SimpleMatch 'PASS: ADC late-arrival sensitivity' -Quiet)) { throw 'Aperture checks did not pass' }
} finally { Pop-Location }
