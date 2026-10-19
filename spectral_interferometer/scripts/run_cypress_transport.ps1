param([Parameter(Mandatory=$true)][string]$CyUsbDll,[switch]$CompileOnly)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
$library=(Resolve-Path -LiteralPath $CyUsbDll).Path
$null=[Reflection.Assembly]::LoadFrom($library)
$source=Join-Path (Split-Path $PSScriptRoot -Parent) 'host\CypressTransport.cs'
Add-Type -Path $source -ReferencedAssemblies $library,System.Windows.Forms
if(!$CompileOnly){[CypressTransport]::Run()}
