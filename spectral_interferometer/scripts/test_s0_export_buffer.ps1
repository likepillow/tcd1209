$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin='C:\Xilinx\Vivado\2018.3\bin'
$out=Join-Path $root 'build\s0_export_buffer_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out
try {
    & "$bin\xvlog.bat" --sv "$root\rtl\packet_frame_buffer.v" "$root\rtl\s0_export_buffer.v" "$root\sim\tb_s0_export_buffer.sv"
    if($LASTEXITCODE){throw 'compile failed'}
    & "$bin\xelab.bat" tb_s0_export_buffer -s s0_export_test
    if($LASTEXITCODE){throw 'elaboration failed'}
    & "$bin\xsim.bat" s0_export_test -runall
    if($LASTEXITCODE){throw 'simulation failed'}
    if(!(Select-String -Path xsim.log -SimpleMatch 'PASS: S0 nonblocking export' -Quiet)){throw 'No passing result'}
} finally {Pop-Location}
