param(
    [Parameter(Mandatory=$true)][ValidateSet('Candidate30','Original48')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$ProjectRoot,
    [Parameter(Mandatory=$true)][string]$CyUsbDll,
    [Parameter(Mandatory=$true)][string]$OriginalFirmwareFolder
)
# Volatile FX2 RAM download only. LoadEEPROM is deliberately never called.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$dll = (Resolve-Path -LiteralPath $CyUsbDll).Path
$original = Join-Path (Resolve-Path -LiteralPath $OriginalFirmwareFolder).Path 'slave.hex'
$candidate = Join-Path $root 'build\slave_30mhz_candidate.hex'
if ($Mode -eq 'Candidate30') {
    $firmware = $candidate
    $expected = '15EFA5E256C2C95404B0A8C4D18B7D0257CB121A27F45ACBD9DDBDEADB99154E'
} else {
    $firmware = $original
    $expected = '3438273290E71EEB64DE0872BD21CE4F28503D68B99A2DE278001A5BA0C4399D'
}
$firmware = (Resolve-Path -LiteralPath $firmware).Path
$actual = (Get-FileHash -LiteralPath $firmware -Algorithm SHA256).Hash
if ($actual -ne $expected) { throw "Firmware hash mismatch; refusing RAM download" }
$null = [Reflection.Assembly]::LoadFrom($dll)

function Open-UniqueFx2 {
    $list = New-Object CyUSB.USBDeviceList -ArgumentList ([byte]1)
    if ($list.Count -ne 1) {
        $count = $list.Count
        $list.Dispose()
        throw "Expected exactly one Cypress device; found $count"
    }
    $device = $list.get_Item([int]0)
    if ($device.GetType().FullName -ne 'CyUSB.CyFX2Device' -or
        $device.VendorID -ne 0x04B4 -or $device.ProductID -notin @(0x00F1,0x1004) -or
        -not $device.IsFX2Device) {
        $description = "$($device.GetType().FullName) VID=$($device.VendorID) PID=$($device.ProductID)"
        $list.Dispose()
        throw "Unexpected USB device: $description"
    }
    return @($list,$device)
}

$opened = Open-UniqueFx2
$devices = $opened[0]
$fx2 = $opened[1]
try {
    Write-Host ("FX2_RAM_DOWNLOAD_BEGIN mode={0} VID={1:X4} PID={2:X4} sha256={3}" -f $Mode,$fx2.VendorID,$fx2.ProductID,$actual)
    $ok = $fx2.LoadRAM($firmware)
    if (-not $ok) { throw "CyFX2Device.LoadRAM returned false" }
} finally {
    $devices.Dispose()
}

# The CPU restart may momentarily re-enumerate the device. Require the intended
# descriptor and bulk endpoints to return before reporting success.
$verified = $false
for ($attempt=0; $attempt -lt 40 -and -not $verified; $attempt++) {
    Start-Sleep -Milliseconds 250
    try {
        $opened = Open-UniqueFx2
        $devices = $opened[0]
        $fx2 = $opened[1]
        try {
            $ep2 = $fx2.EndPointOf([byte]0x02)
            $ep6 = $fx2.EndPointOf([byte]0x86)
            $verified = ($fx2.ProductID -eq 0x00F1 -and $fx2.bHighSpeed -and -not $fx2.bSuperSpeed -and
                         $null -ne $ep2 -and $null -ne $ep6 -and
                         $ep2.MaxPktSize -eq 512 -and $ep6.MaxPktSize -eq 512)
        } finally {
            $devices.Dispose()
        }
    } catch {
        if ($attempt -eq 39) { throw }
    }
}
if (-not $verified) { throw "FX2 did not return with expected high-speed EP2/EP6 endpoints" }
Write-Host "FX2_RAM_DOWNLOAD_PASS mode=$Mode high_speed=True EP2=512 EP6=512 volatile_only=True"
