$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$vivadoBin='C:\Xilinx\Vivado\2018.3\bin'
$testOutput=Join-Path $projectRoot 'build\acquisition_reconfigure_sim'
New-Item -ItemType Directory -Force -Path $testOutput | Out-Null
Push-Location $testOutput
try {
    & "$vivadoBin\xvlog.bat" --sv "$projectRoot\rtl\instrument_core.v" "$projectRoot\sim\tb_acquisition_reconfigure.sv"
    if($LASTEXITCODE){throw 'compile failed'}
    & "$vivadoBin\xelab.bat" tb_acquisition_reconfigure -s acquisition_reconfigure_test
    if($LASTEXITCODE){throw 'elaboration failed'}
    & "$vivadoBin\xsim.bat" acquisition_reconfigure_test -runall
    if($LASTEXITCODE){throw 'simulation failed'}
    if(!(Select-String -Path xsim.log -SimpleMatch 'PASS: W/T waits' -Quiet)){throw 'No passing result'}
} finally {Pop-Location}
