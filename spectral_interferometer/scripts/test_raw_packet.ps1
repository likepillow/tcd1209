$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin='C:\Xilinx\Vivado\2018.3\bin'
$out=Join-Path $root 'build\raw_packet_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out
try {
    & "$bin\xvlog.bat" --sv "$root\rtl\packet_tx.v" "$root\rtl\raw_packet_tx.v" "$root\sim\tb_raw_packet_tx.sv"
    if($LASTEXITCODE){throw 'compile failed'}
    & "$bin\xelab.bat" tb_raw_packet_tx -s raw_packet_test
    if($LASTEXITCODE){throw 'elaboration failed'}
    & "$bin\xsim.bat" raw_packet_test -runall
    if($LASTEXITCODE){throw 'simulation failed'}
    if(!(Select-String -Path xsim.log -SimpleMatch 'PASS: RAW packets' -Quiet)){throw 'No passing result'}
    & 'C:\Users\JITIANRUI\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' "$root\sim\check_raw_packets.py" "$out\raw_packets.hex"
    if($LASTEXITCODE){throw 'host verification failed'}
} finally {Pop-Location}
