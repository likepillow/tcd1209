param([string]$VivadoBin = 'C:\Xilinx\Vivado\2018.3\bin')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$testOutput = Join-Path $projectRoot 'build\diagnostic_sim'
New-Item -ItemType Directory -Force -Path $testOutput | Out-Null
Push-Location $testOutput
try {
    $sources = @('board_clock_reset.v','ad9945_init.v','adc_pixel_align.v','ccd_afe_timing.v','ccd_frontend.v','diagnostic_top.v') | ForEach-Object { Join-Path $projectRoot "rtl\$_" }
    $glbl = Join-Path (Split-Path $VivadoBin -Parent) 'data\verilog\src\glbl.v'
    & (Join-Path $VivadoBin 'xvlog.bat') @sources $glbl
    if ($LASTEXITCODE) { throw 'RTL xvlog failed' }
    & (Join-Path $VivadoBin 'xvlog.bat') --sv (Join-Path $projectRoot 'sim\tb_diagnostic_top.sv')
    if ($LASTEXITCODE) { throw 'Testbench xvlog failed' }
    & (Join-Path $VivadoBin 'xelab.bat') -L unisims_ver tb_diagnostic_top glbl -s diagnostic_test
    if ($LASTEXITCODE) { throw 'xelab failed' }
    & (Join-Path $VivadoBin 'xsim.bat') diagnostic_test -runall
    if ($LASTEXITCODE) { throw 'xsim failed' }
    if (!(Select-String -Path 'xsim.log' -SimpleMatch 'PASS: diagnostic top held startup' -Quiet)) { throw 'Diagnostic simulation did not pass' }
} finally { Pop-Location }
