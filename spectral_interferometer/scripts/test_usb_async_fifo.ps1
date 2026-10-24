param([switch]$Bridge,[switch]$Large)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin='C:\Xilinx\Vivado\2018.3\bin'
$xpm='C:\Xilinx\Vivado\2018.3\data\ip\xpm'
$out=Join-Path $root 'build\usb_async_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out
try {
    & "$bin\xvlog.bat" --sv "$xpm\xpm_cdc\hdl\xpm_cdc.sv" "$xpm\xpm_memory\hdl\xpm_memory.sv" "$xpm\xpm_fifo\hdl\xpm_fifo.sv" "$root\rtl\usb_async_fifo.v" "$root\sim\tb_usb_async_fifo.sv"
    if($LASTEXITCODE){throw 'compile failed'}
    & "$bin\xvlog.bat" 'C:\Xilinx\Vivado\2018.3\data\verilog\src\glbl.v'
    if($LASTEXITCODE){throw 'global simulation compile failed'}
    & "$bin\xelab.bat" tb_usb_async_fifo glbl -L unisims_ver -s usb_async_test
    if($LASTEXITCODE){throw 'elaboration failed'}
    & "$bin\xsim.bat" usb_async_test -runall
    if($LASTEXITCODE){throw 'simulation failed'}
    if(!(Select-String -Path xsim.log -SimpleMatch 'PASS: actual XPM async FIFO' -Quiet)){throw 'No passing result'}
    if($Bridge) {
        & "$bin\xvlog.bat" --sv "$root\rtl\usb_word_stream.v" "$root\rtl\usb_stream_bridge.v" "$root\sim\tb_usb_stream_bridge.sv"
        if($LASTEXITCODE){throw 'bridge compile failed'}
        & "$bin\xelab.bat" tb_usb_stream_bridge glbl -L unisims_ver -s usb_bridge_test
        if($LASTEXITCODE){throw 'bridge elaboration failed'}
        & "$bin\xsim.bat" usb_bridge_test -runall -log bridge_xsim.log
        if($LASTEXITCODE){throw 'bridge simulation failed'}
        if(!(Select-String -Path bridge_xsim.log -SimpleMatch 'PASS: USB bridges' -Quiet)){throw 'No passing bridge result'}
    }
    if($Large) {
        & "$bin\xvlog.bat" --sv "$root\sim\tb_usb_large_fifo.sv"
        if($LASTEXITCODE){throw 'large FIFO compile failed'}
        & "$bin\xelab.bat" tb_usb_large_fifo glbl -L unisims_ver -s usb_large_test
        if($LASTEXITCODE){throw 'large FIFO elaboration failed'}
        & "$bin\xsim.bat" usb_large_test -runall -log large_xsim.log
        if($LASTEXITCODE -or !(Select-String -Path large_xsim.log -SimpleMatch 'PASS: 32768-word XPM FIFO' -Quiet)){throw 'No passing large FIFO result'}
    }
} finally {Pop-Location}
