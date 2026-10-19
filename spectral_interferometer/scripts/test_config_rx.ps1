param([switch]$Loader)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin='C:\Xilinx\Vivado\2018.3\bin'
$out=Join-Path $root 'build\config_rx_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
& 'C:\Users\JITIANRUI\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' "$root\sim\config_rx_vectors.py" $out
if($LASTEXITCODE){throw 'vectors failed'}
Push-Location $out
try {
    & "$bin\xvlog.bat" --sv -i $out "$root\rtl\config_packet_rx.v" "$root\sim\tb_config_packet_rx.sv"
    if($LASTEXITCODE){throw 'compile failed'}
    & "$bin\xelab.bat" tb_config_packet_rx -s config_rx_test
    if($LASTEXITCODE){throw 'elaboration failed'}
    & "$bin\xsim.bat" config_rx_test -runall
    if($LASTEXITCODE){throw 'simulation failed'}
    if(!(Select-String -Path xsim.log -SimpleMatch 'PASS: config receiver' -Quiet)){throw 'No passing result'}
    if($Loader) {
        & "$bin\xvlog.bat" --sv -i $out "$root\rtl\packet_scheduler.v" "$root\rtl\packet_tx.v" "$root\rtl\ack_packet_tx.v" "$root\rtl\calibration_loader.v" "$root\rtl\calibration_control.v" "$root\rtl\normalize_frame.v" "$root\rtl\distance_fit.v" "$root\sim\tb_calibration_loader.sv"
        if($LASTEXITCODE){throw 'loader compile failed'}
        & "$bin\xelab.bat" tb_calibration_loader -s loader_test
        if($LASTEXITCODE){throw 'loader elaboration failed'}
        & "$bin\xsim.bat" loader_test -runall -log loader_xsim.log
        if($LASTEXITCODE){throw 'loader simulation failed'}
        if(!(Select-String -Path loader_xsim.log -SimpleMatch 'PASS: calibration loader' -Quiet)){throw 'No passing loader result'}
        & 'C:\Users\JITIANRUI\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' "$root\sim\check_loader_ack.py" "$out\loader_ack.hex"
        if($LASTEXITCODE){throw 'host ACK verification failed'}
    }
} finally {Pop-Location}
