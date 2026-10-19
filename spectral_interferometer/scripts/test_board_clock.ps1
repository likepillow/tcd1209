param([string]$VivadoBin = 'C:\Xilinx\Vivado\2018.3\bin')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$testOutput = Join-Path $projectRoot 'build\board_clock_sim'
New-Item -ItemType Directory -Force -Path $testOutput | Out-Null
Push-Location $testOutput
try {
    $glbl = Join-Path (Split-Path $VivadoBin -Parent) 'data\verilog\src\glbl.v'
    & (Join-Path $VivadoBin 'xvlog.bat') --sv (Join-Path $projectRoot 'rtl\board_clock_reset.v') (Join-Path $projectRoot 'sim\tb_board_clock_reset.sv') $glbl
    if ($LASTEXITCODE) { throw 'xvlog failed' }
    & (Join-Path $VivadoBin 'xelab.bat') -L unisims_ver tb_board_clock_reset glbl -s board_clock_test
    if ($LASTEXITCODE) { throw 'xelab failed' }
    & (Join-Path $VivadoBin 'xsim.bat') board_clock_test -runall
    if ($LASTEXITCODE) { throw 'xsim failed' }
    if (!(Select-String -Path 'xsim.log' -SimpleMatch 'PASS: actual MMCME2_BASE' -Quiet)) { throw 'Clock simulation did not pass' }
} finally { Pop-Location }
