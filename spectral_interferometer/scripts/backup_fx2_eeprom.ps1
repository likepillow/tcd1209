param([Parameter(Mandatory=$true)][string]$CyUsbDll)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$output=Join-Path $root 'build\flash_audit\original_fx2_eeprom.bin'
if(Test-Path -LiteralPath $output){throw 'Backup already exists'}
$null=[Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $CyUsbDll).Path)
$devices=New-Object CyUSB.USBDeviceList -ArgumentList ([byte]1)
try {
    if($devices.Count -ne 1){throw 'Expected exactly one Cypress device'}
    $fx=$devices.get_Item([int]0)
    if(-not $fx.IsFX2Device -or $fx.VendorID -ne 0x04b4 -or $fx.ProductID -ne 0x00f1){throw 'Unexpected device'}
    # DLL-bundled Cypress vendor helper, RAM only. EEPROM access below is IN only.
    if(-not $fx.LoadRAM('VendAX')){throw 'Cannot load Cypress RAM readback helper'}
    Start-Sleep -Milliseconds 500
    $ep=$fx.ControlEndPt
    $ep.Target=0;$ep.ReqType=0x40;$ep.ReqCode=0xa9;$ep.Index=0;$ep.TimeOut=5000
    $copies=@()
    for($pass=0;$pass -lt 2;$pass++){
        $data=New-Object byte[] 8192
        for($offset=0;$offset -lt 8192;$offset+=64){
            $ep.Value=[uint16]$offset
            $block=New-Object byte[] 64
            $count=64
            if(-not $ep.Read([ref]$block,[ref]$count) -or $count -ne 64){throw "EEPROM read failed at $offset"}
            [Array]::Copy($block,0,$data,$offset,64)
        }
        $copies+=,$data
    }
    if([Convert]::ToBase64String($copies[0]) -ne [Convert]::ToBase64String($copies[1])){throw 'Readbacks disagree'}
    if($copies[0][0] -ne 0xc2){throw 'Expected existing C2 boot image; no write performed'}
    $stream=[IO.File]::Open($output,[IO.FileMode]::CreateNew)
    try{$stream.Write($copies[0],0,8192)}finally{$stream.Dispose()}
    Write-Host 'FX2_EEPROM_BACKUP_PASS: 8192 bytes, two identical reads, no EEPROM writes'
    Get-FileHash -LiteralPath $output
} finally {$devices.Dispose()}
