$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin='C:\Xilinx\Vivado\2018.3\bin'
$out=Join-Path $root 'build\packet_scheduler_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out
try {
    & "$bin\xvlog.bat" --sv "$root\rtl\packet_scheduler.v" "$root\sim\tb_packet_scheduler.sv"
    if($LASTEXITCODE){throw 'compile failed'}
    & "$bin\xelab.bat" tb_packet_scheduler -s scheduler_test
    if($LASTEXITCODE){throw 'elaboration failed'}
    & "$bin\xsim.bat" scheduler_test -runall
    if($LASTEXITCODE){throw 'simulation failed'}
    if(!(Select-String -Path xsim.log -SimpleMatch 'PASS: packet scheduler' -Quiet)){throw 'No passing result'}
} finally {Pop-Location}
