$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin='C:\Xilinx\Vivado\2018.3\bin'
$out=Join-Path $root 'build\run_control_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out
try {
    & "$bin\xvlog.bat" --sv "$root\rtl\instrument_core.v" "$root\sim\tb_acquisition_run_control.sv"
    if($LASTEXITCODE){throw 'compile failed'}
    & "$bin\xelab.bat" tb_acquisition_run_control -s run_control_test
    if($LASTEXITCODE){throw 'elaboration failed'}
    & "$bin\xsim.bat" run_control_test -runall
    if($LASTEXITCODE){throw 'simulation failed'}
    if(!(Select-String -Path xsim.log -SimpleMatch 'PASS: run control' -Quiet)){throw 'No passing result'}
} finally {Pop-Location}
