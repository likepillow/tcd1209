param([Parameter(Mandatory=$true)][string]$CyUsbDll)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$backup=Join-Path $root 'build\flash_audit\original_fx2_eeprom.bin'
$image=Join-Path $root 'build\flash_audit\slave_30mhz.iic'
$readback=Join-Path $root 'build\flash_audit\programmed_fx2_eeprom.bin'
if(Test-Path -LiteralPath $readback){throw 'Readback exists; inspect it before any repeat programming'}
if((Get-FileHash $backup).Hash -ne '55829553FB4CB429DC44D234B8968E53AE2C67E0324C9D7BDF35EC224180274A'){throw 'Backup hash mismatch'}
if((Get-FileHash $image).Hash -ne 'E5FA2194FCEB6DE5ECE6F3BE6FD5B16DCBF35D33F052142B4A36BB74806870D4'){throw 'Image hash mismatch'}
$original=[IO.File]::ReadAllBytes($backup)
$expected=[IO.File]::ReadAllBytes($backup)
$firmware=[IO.File]::ReadAllBytes($image)
[Array]::Copy($firmware,0,$expected,0,$firmware.Length)
$null=[Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $CyUsbDll).Path)
$devices=New-Object CyUSB.USBDeviceList -ArgumentList ([byte]1)
try {
    if($devices.Count -ne 1){throw 'Expected one Cypress device'}
    $fx=$devices.get_Item([int]0)
    # 1004 is the DLL-bundled VendAX helper left running after the backup.
    if(-not $fx.IsFX2Device -or $fx.VendorID -ne 0x04b4 -or $fx.ProductID -notin @(0x00f1,0x1004)){throw 'Unexpected device'}
    if(-not $fx.LoadRAM('VendAX')){throw 'Readback helper failed'}
    Start-Sleep -Milliseconds 500
    function Read-Eeprom {
        $ep=$fx.ControlEndPt
        $ep.Target=0;$ep.ReqType=0x40;$ep.ReqCode=0xa9;$ep.Index=0;$ep.TimeOut=5000
        $result=New-Object byte[] 8192
        for($offset=0;$offset -lt 8192;$offset+=64){
            $ep.Value=[uint16]$offset;$block=New-Object byte[] 64;$count=64
            if(-not $ep.Read([ref]$block,[ref]$count) -or $count -ne 64){throw "Read failed at $offset"}
            [Array]::Copy($block,0,$result,$offset,64)
        }
        return ,$result
    }
    $before=Read-Eeprom
    if([Convert]::ToBase64String($before) -ne [Convert]::ToBase64String($original)){throw 'EEPROM changed since backup; refusing write'}
    Write-Host 'Writing authorized 2718-byte C2 boot image to 24LC64; backup verified'
    if(-not $fx.LoadEEPROM($image,$true)){throw 'LoadEEPROM failed; do not power off until investigated'}
    $actual=Read-Eeprom
    if([Convert]::ToBase64String($actual) -ne [Convert]::ToBase64String($expected)){throw 'Full EEPROM verification failed'}
    $stream=[IO.File]::Open($readback,[IO.FileMode]::CreateNew)
    try{$stream.Write($actual,0,$actual.Length)}finally{$stream.Dispose()}
    Write-Host 'FX2_EEPROM_PROGRAM_PASS: full 8192-byte readback matches; trailing data preserved'
    Get-FileHash $readback
} finally {$devices.Dispose()}
