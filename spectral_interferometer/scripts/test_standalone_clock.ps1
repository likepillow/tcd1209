param([string]$VivadoBin='C:\Xilinx\Vivado\2018.3\bin')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$output=Join-Path $root 'build\standalone_clock_sim'
New-Item -ItemType Directory -Force $output | Out-Null
Push-Location $output
try {
    & (Join-Path $VivadoBin 'xvlog.bat') --sv (Join-Path $root 'rtl\usb_clock_qualifier.v') (Join-Path $root 'sim\tb_usb_clock_qualifier.sv')
    if($LASTEXITCODE){throw 'Compile failed'}
    & (Join-Path $VivadoBin 'xelab.bat') tb_usb_clock_qualifier -s clock_guard_test
    if($LASTEXITCODE){throw 'Elaboration failed'}
    & (Join-Path $VivadoBin 'xsim.bat') clock_guard_test -runall
    if($LASTEXITCODE -or -not (Select-String -Path xsim.log -SimpleMatch 'PASS: standalone IFCLK' -Quiet)){throw 'Clock qualifier simulation failed'}
} finally {Pop-Location}
