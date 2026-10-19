param([switch]$Capture,[switch]$LongStall)
$ErrorActionPreference='Stop'
if($LongStall -and !$Capture){throw 'LongStall requires Capture'}
$root=Split-Path $PSScriptRoot -Parent
$bin='C:\Xilinx\Vivado\2018.3\bin'
$out=Join-Path $root 'build\raw_stream_packet_sim'
$top='tb_raw_stream_packet_tx';$check='check_raw_stream_packets.py';$hex='raw_stream_packets.hex';$pass='PASS: RAW stream multiframe'
if($Capture){
    $out=Join-Path $root 'build\capture_packet_sim'
    $top='tb_capture_packet';$check='check_capture_packets.py';$hex='capture_packets.hex';$pass='PASS: capture packet'
    if($LongStall){$out=Join-Path $root 'build\capture_packet_stall_sim'}
}
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out
try {
    & "$bin\xvlog.bat" --sv "$root\rtl\packet_tx.v" "$root\rtl\raw_packet_tx.v" "$root\rtl\raw_stream_packet_tx.v" "$root\rtl\frame_ping_pong.v" "$root\rtl\packet_scheduler.v" "$root\sim\$top.sv"
    if($LASTEXITCODE){throw 'compile failed'}
    & "$bin\xelab.bat" $top -s raw_stream_test
    if($LASTEXITCODE){throw 'elaboration failed'}
    $simArgs=@();$checkArgs=@()
    if($LongStall){$simArgs=@('-testplusarg','LONG_STALL');$checkArgs=@('--long-stall')}
    & "$bin\xsim.bat" raw_stream_test -runall @simArgs
    if($LASTEXITCODE){throw 'simulation failed'}
    if(!(Select-String -Path xsim.log -SimpleMatch $pass -Quiet)){throw 'No passing result'}
    & 'C:\Users\JITIANRUI\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' "$root\sim\$check" "$out\$hex" @checkArgs
    if($LASTEXITCODE){throw 'host verification failed'}
} finally {Pop-Location}
