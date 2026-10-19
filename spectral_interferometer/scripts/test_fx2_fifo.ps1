param([switch]$LongPackets)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin='C:\Xilinx\Vivado\2018.3\bin'
$test='tb_fx2_slave_fifo'
$marker='PASS: FX2 full-IN'
if($LongPackets){$test='tb_fx2_packets';$marker='PASS: FX2 long packets'}
$out=Join-Path $root "build\${test}_sim"
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out
try {
    & "$bin\xvlog.bat" --sv "$root\rtl\fx2_slave_fifo.v" "$root\sim\${test}.sv"
    if($LASTEXITCODE){throw 'compile failed'}
    & "$bin\xelab.bat" $test -s fx2_fifo_test
    if($LASTEXITCODE){throw 'elaboration failed'}
    & "$bin\xsim.bat" fx2_fifo_test -runall
    if($LASTEXITCODE){throw 'simulation failed'}
    if(!(Select-String -Path xsim.log -SimpleMatch $marker -Quiet)){throw 'No passing result'}
} finally {Pop-Location}
