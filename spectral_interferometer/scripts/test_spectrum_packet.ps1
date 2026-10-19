$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin='C:\Xilinx\Vivado\2018.3\bin'
$out=Join-Path $root 'build\spectrum_packet_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out
try {
    & "$bin\xvlog.bat" --sv "$root\rtl\packet_tx.v" "$root\rtl\spectrum_packet_tx.v" "$root\rtl\spectrum_stream_packet_tx.v" "$root\sim\tb_spectrum_packet.sv"
    if($LASTEXITCODE){throw 'compile failed'}
    & "$bin\xelab.bat" tb_spectrum_packet -s spectrum_packet_test
    if($LASTEXITCODE){throw 'elaboration failed'}
    & "$bin\xsim.bat" spectrum_packet_test -runall
    if($LASTEXITCODE){throw 'simulation failed'}
    if(!(Select-String -Path xsim.log -SimpleMatch 'PASS: spectrum tuple' -Quiet)){throw 'No passing result'}
    & 'C:\Users\JITIANRUI\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' "$root\sim\check_spectrum_packet.py" "$out\spectrum_packets.hex"
    if($LASTEXITCODE){throw 'host verification failed'}
} finally {Pop-Location}
