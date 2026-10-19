$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$vivadoBin='C:\Xilinx\Vivado\2018.3\bin'
$testOutput=Join-Path $projectRoot 'build\dynamic_acquisition_sim'
New-Item -ItemType Directory -Force -Path $testOutput | Out-Null
Push-Location $testOutput
try {
    & "$vivadoBin\xvlog.bat" --sv "$projectRoot\rtl\frame_ping_pong.v" "$projectRoot\rtl\ccd_afe_timing.v" "$projectRoot\sim\tb_dynamic_acquisition.sv"
    if($LASTEXITCODE){throw 'compile failed'}
    & "$vivadoBin\xelab.bat" tb_dynamic_acquisition -s dynamic_acquisition_test
    if($LASTEXITCODE){throw 'elaboration failed'}
    & "$vivadoBin\xsim.bat" dynamic_acquisition_test -runall
    if($LASTEXITCODE){throw 'simulation failed'}
    if(!(Select-String -Path xsim.log -SimpleMatch 'PASS: dynamic W endpoints' -Quiet)){throw 'No passing result'}
} finally {Pop-Location}
