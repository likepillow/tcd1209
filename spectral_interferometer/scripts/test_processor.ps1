param(
    [string]$VivadoBin = 'C:\Xilinx\Vivado\2018.3\bin',
    [string]$Python = 'C:\Users\JITIANRUI\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
    [switch]$Capture,
    [switch]$Packet,
    [switch]$Clipping
)
$ErrorActionPreference = 'Stop'
if($Packet){$Capture=$true}
$projectRoot = Split-Path $PSScriptRoot -Parent
$testOutput = Join-Path $projectRoot 'build\processor_sim'
$vectorArguments = @($testOutput)
if ($Clipping) { $vectorArguments += '--clipping' }
& $Python (Join-Path $projectRoot 'sim\processor_vectors.py') @vectorArguments
if ($LASTEXITCODE) { throw 'Vector generation failed' }
$vivado = Join-Path $VivadoBin 'vivado.bat'
if (!(Test-Path -LiteralPath (Join-Path $projectRoot 'build\fft_ip\spectral_fft.xpr'))) {
    & $vivado -mode batch -source (Join-Path $PSScriptRoot 'generate_fft_ip.tcl') -log (Join-Path $projectRoot 'build\generate_fft.log') -journal (Join-Path $projectRoot 'build\generate_fft.jou') -tclargs $projectRoot
    if ($LASTEXITCODE) { throw 'FFT IP generation failed' }
}
$testTag = if ($Capture) { 'acquisition' } else { 'processor' }
$tclArguments = @($projectRoot)
if ($Packet) {$tclArguments += 'capture_packet';$testTag='acquisition_packet'}
elseif ($Capture) { $tclArguments += 'capture' }
& $vivado -mode batch -source (Join-Path $PSScriptRoot 'test_processor.tcl') -log (Join-Path $projectRoot "build\${testTag}_sim.log") -journal (Join-Path $projectRoot "build\${testTag}_sim.jou") -tclargs @tclArguments
if ($LASTEXITCODE) { throw 'Processor simulation failed' }
$simulationOutput = Join-Path $projectRoot 'build\fft_ip\spectral_fft.sim\sim_1\behav\xsim'
$checkArguments = @($simulationOutput, '--check')
if ($Clipping) { $checkArguments += '--clipping' }
& $Python (Join-Path $projectRoot 'sim\processor_vectors.py') @checkArguments
if ($LASTEXITCODE) { throw 'Processor numerical check failed' }
if($Packet){
    & $Python (Join-Path $projectRoot 'sim\check_processor_packets.py') $simulationOutput
    if($LASTEXITCODE){throw 'Processor RAW packet verification failed'}
}
