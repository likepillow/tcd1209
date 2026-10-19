param(
    [Parameter(Mandatory=$true)][string]$CyUsbDll
)
# Descriptor-only discovery. No bulk transfers, reset, configuration/interface
# setters, vendor requests, firmware downloads, or EEPROM writes.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$null = [Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $CyUsbDll).Path)
$usbDevices = New-Object CyUSB.USBDeviceList -ArgumentList ([byte]1)
try {
    $found = 0
    Write-Host "Cypress library device count: $($usbDevices.Count)"
    for ($i = 0; $i -lt $usbDevices.Count; $i++) {
        # Explicit accessor avoids PowerShell's scalar/collection indexing rules.
        $device = $usbDevices.get_Item([int]$i)
        Write-Host ('Library entry {0}: type={1}, VID={2}, PID={3}, product={4}' -f $i,$device.GetType().FullName,$device.VendorID,$device.ProductID,$device.Product)
        if ($device.VendorID -ne 0x04B4) { continue }
        $found++
        $descriptor = New-Object CyUSB.USB_DEVICE_DESCRIPTOR
        $device.GetDeviceDescriptor([ref]$descriptor)
        # Standard, device-to-host GET_DESCRIPTOR only (USB 2.0 chapter 9).
        $control = $device.ControlEndPt
        $control.Target = 0
        $control.ReqType = 0
        $control.Direction = 128
        $control.ReqCode = 6
        $control.Value = 0x0100
        $control.Index = 0
        $control.TimeOut = 1000
        [byte[]]$rawDescriptor = New-Object byte[] 18
        [int]$descriptorLength = 18
        $descriptorOk = $control.XferData([ref]$rawDescriptor, [ref]$descriptorLength)
        if (-not $descriptorOk -or $descriptorLength -ne 18 -or $rawDescriptor[0] -ne 18 -or $rawDescriptor[1] -ne 1) {
            throw "Standard device descriptor request failed or returned malformed data."
        }
        $endpoints = @($device.EndPoints | Where-Object { $null -ne $_ } | ForEach-Object {
            [pscustomobject]@{
                address = ('0x{0:X2}' -f $_.Address)
                attributes = [int]$_.Attributes
                direction = $(if ($_.Address -eq 0) { 'CONTROL_BIDIRECTIONAL' } elseif ($_.bIn) { 'IN' } else { 'OUT' })
                max_packet_bytes = $_.MaxPktSize
            }
        })
        [pscustomobject]@{
            vid = ('0x{0:X4}' -f $device.VendorID)
            pid = ('0x{0:X4}' -f $device.ProductID)
            descriptor_vid = ('0x{0:X4}' -f $descriptor.idVendor)
            descriptor_pid = ('0x{0:X4}' -f $descriptor.idProduct)
            live_descriptor_hex = [BitConverter]::ToString($rawDescriptor)
            live_vid = ('0x{0:X4}' -f [BitConverter]::ToUInt16($rawDescriptor,8))
            live_pid = ('0x{0:X4}' -f [BitConverter]::ToUInt16($rawDescriptor,10))
            product = $device.Product
            driver_name = $device.DriverName
            device_handle_valid = ($device.DeviceHandle -ne [IntPtr]::Zero -and $device.DeviceHandle -ne [IntPtr](-1))
            high_speed = $device.bHighSpeed
            super_speed = $device.bSuperSpeed
            bcd_usb = ('0x{0:X4}' -f $device.BcdUSB)
            configuration_value = $device.ConfigValue
            interface_count = $device.IntfcCount
            alternate_setting = $device.AltIntfc
            endpoints = $endpoints
        } | ConvertTo-Json -Depth 5
    }
    if ($found -ne 1) { throw "Expected one Cypress 04B4 device; found $found. No bulk or vendor transfers attempted." }
} finally {
    $usbDevices.Dispose()
}
