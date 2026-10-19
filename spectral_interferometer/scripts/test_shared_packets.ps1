param([switch]$Bridge)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin='C:\Xilinx\Vivado\2018.3\bin'
$out=Join-Path $root 'build\shared_packet_sim'
if($Bridge){$out=Join-Path $root 'build\shared_packet_bridge_sim'}
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out
try {
    $sources=@('packet_scheduler','packet_tx','ack_packet_tx','raw_packet_tx','raw_stream_packet_tx','result_packet_tx') | ForEach-Object {"$root\rtl\$_.v"}
    if($Bridge) {
        $xpm='C:\Xilinx\Vivado\2018.3\data\ip\xpm'
        & "$bin\xvlog.bat" --sv "$xpm\xpm_cdc\hdl\xpm_cdc.sv" "$xpm\xpm_memory\hdl\xpm_memory.sv" "$xpm\xpm_fifo\hdl\xpm_fifo.sv" "$root\rtl\usb_word_stream.v" "$root\rtl\usb_async_fifo.v" "$root\rtl\usb_stream_bridge.v"
        if($LASTEXITCODE){throw 'XPM/bridge compile failed'}
        & "$bin\xvlog.bat" 'C:\Xilinx\Vivado\2018.3\data\verilog\src\glbl.v'
        if($LASTEXITCODE){throw 'global simulation compile failed'}
        & "$bin\xvlog.bat" --sv -d USB_BRIDGE @sources "$root\sim\tb_shared_packets.sv"
    } else {
        & "$bin\xvlog.bat" --sv @sources "$root\sim\tb_shared_packets.sv"
    }
    if($LASTEXITCODE){throw 'compile failed'}
    if($Bridge){& "$bin\xelab.bat" tb_shared_packets glbl -L unisims_ver -s shared_packet_test}
    else {& "$bin\xelab.bat" tb_shared_packets -s shared_packet_test}
    if($LASTEXITCODE){throw 'elaboration failed'}
    & "$bin\xsim.bat" shared_packet_test -runall
    if($LASTEXITCODE){throw 'simulation failed'}
    if(!(Select-String -Path xsim.log -SimpleMatch 'PASS: shared ACK RAW RESULT' -Quiet)){throw 'No passing result'}
    & 'C:\Users\JITIANRUI\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' "$root\sim\check_shared_packets.py" "$out\shared_packets.hex"
    if($LASTEXITCODE){throw 'host verification failed'}
} finally {Pop-Location}
