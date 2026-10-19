param(
    [string]$VivadoBin = 'C:\Xilinx\Vivado\2018.3\bin',
    [ValidateRange(1,10)][int]$CaptureCycles = 2,
    [ValidateRange(1,100000)][int]$BusArrivalPs = 9500
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$outputName = if ($CaptureCycles -eq 2 -and $BusArrivalPs -eq 9500) { 'frontend_sim' } else { "frontend_c${CaptureCycles}_a${BusArrivalPs}_sim" }
$testOutput = Join-Path $projectRoot "build\$outputName"
New-Item -ItemType Directory -Force -Path $testOutput | Out-Null
Push-Location $testOutput
try {
    $sources = @('ad9945_init.v','adc_pixel_align.v','ccd_afe_timing.v','ccd_frontend.v','frame_ping_pong.v') | ForEach-Object { Join-Path $projectRoot "rtl\$_" }
    & (Join-Path $VivadoBin 'xvlog.bat') --sv @sources (Join-Path $projectRoot 'sim\tb_ccd_frontend.sv')
    if ($LASTEXITCODE) { throw 'xvlog failed' }
    # Keep literal quotes through the .bat wrapper so '=' stays in one argument.
    & (Join-Path $VivadoBin 'xelab.bat') tb_ccd_frontend -generic_top "`"ADC_CAPTURE_DELAY=$CaptureCycles`"" -generic_top "`"BUS_ARRIVAL_PS=$BusArrivalPs`"" -s frontend_test
    if ($LASTEXITCODE) { throw 'xelab failed' }
    & (Join-Path $VivadoBin 'xsim.bat') frontend_test -runall
    if ($LASTEXITCODE) { throw 'xsim failed' }
    if (!(Select-String -Path 'xsim.log' -SimpleMatch 'PASS: frontend pin-driven model' -Quiet)) { throw 'Frontend simulation did not pass' }
    if (!(Select-String -Path 'xsim.log' -SimpleMatch 'PASS: startup gating' -Quiet)) { throw 'Frontend control coverage did not pass' }
} finally { Pop-Location }
