$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin='C:\Xilinx\Vivado\2018.3\bin'
$out=Join-Path $root 'build\export_control_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out
try {
    & "$bin\xvlog.bat" --sv "$root\rtl\config_packet_rx.v" "$root\rtl\calibration_loader.v" "$root\rtl\calibration_control.v" "$root\rtl\packet_tx.v" "$root\rtl\ack_packet_tx.v" "$root\sim\tb_export_control.sv"
    if($LASTEXITCODE){throw 'compile failed'}
    & "$bin\xelab.bat" tb_export_control -s export_control_test
    if($LASTEXITCODE){throw 'elaboration failed'}
    & "$bin\xsim.bat" export_control_test -runall
    if($LASTEXITCODE){throw 'simulation failed'}
    if(!(Select-String -Path xsim.log -SimpleMatch 'PASS: EXPORT CRC isolation' -Quiet)){throw 'No passing result'}
} finally {Pop-Location}
