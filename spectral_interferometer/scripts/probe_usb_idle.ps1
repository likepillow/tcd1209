param([Parameter(Mandatory=$true)][string]$CyUsbDll)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
$null=[Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $CyUsbDll).Path)
$devices=New-Object CyUSB.USBDeviceList(1)
try {
    $matches=@($devices | Where-Object {$_.VendorID -eq 0x04b4 -and $_.ProductID -eq 0x00f1})
    if($matches.Count -ne 1){throw 'Expected one FX2 device'}
    $endpoint=$matches[0].EndPointOf(0x86)
    $endpoint.TimeOut=200
    foreach($attempt in 1..3){
        $buffer=New-Object byte[] 512
        [int]$count=512
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $ok=$endpoint.XferData([ref]$buffer,[ref]$count)
        $watch.Stop()
        [pscustomobject]@{Attempt=$attempt;Success=$ok;Count=$count;Milliseconds=$watch.ElapsedMilliseconds;LastError=$endpoint.LastError;NtStatus=$endpoint.NtStatus;UsbdStatus=$endpoint.UsbdStatus}
    }
} finally {$devices.Dispose()}
