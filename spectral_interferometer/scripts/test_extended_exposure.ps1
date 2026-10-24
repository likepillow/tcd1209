$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin='C:\Xilinx\Vivado\2018.3\bin'
$out=Join-Path $root 'build\extended_exposure_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out
try {
    $names=@('config_packet_rx','calibration_loader','calibration_control','packet_tx','ack_packet_tx','instrument_core','ccd_afe_timing')
    $sources=$names | ForEach-Object {Join-Path $root "rtl\$_.v"}
    & "$bin\xvlog.bat" --sv @sources "$root\sim\tb_extended_exposure.sv"
    if($LASTEXITCODE){throw 'compile failed'}
    foreach($top in @('tb_extended_exposure','tb_long_exposure_stop','tb_result_stride')) {
        & "$bin\xelab.bat" $top -s $top
        if($LASTEXITCODE){throw "elaboration failed: $top"}
        & "$bin\xsim.bat" $top -runall -log "$top.log"
        if($LASTEXITCODE -or !(Select-String -Path "$top.log" -SimpleMatch 'PASS:' -Quiet)){throw "simulation failed: $top"}
    }
} finally {Pop-Location}
