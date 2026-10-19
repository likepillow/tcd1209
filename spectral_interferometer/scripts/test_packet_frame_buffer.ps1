$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin='C:\Xilinx\Vivado\2018.3\bin'
$out=Join-Path $root 'build\packet_frame_buffer_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out
try {
    & "$bin\xvlog.bat" --sv "$root\rtl\packet_frame_buffer.v" "$root\sim\tb_packet_frame_buffer.sv"
    if($LASTEXITCODE){throw 'compile failed'}
    & "$bin\xelab.bat" tb_packet_frame_buffer -s frame_buffer_test
    if($LASTEXITCODE){throw 'elaboration failed'}
    & "$bin\xsim.bat" frame_buffer_test -runall
    if($LASTEXITCODE){throw 'simulation failed'}
    if(!(Select-String -Path xsim.log -SimpleMatch 'PASS: complete frame publication' -Quiet)){throw 'No passing result'}
} finally {Pop-Location}
