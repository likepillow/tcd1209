# Read-only JTAG discovery. Never sets PROGRAM.FILE or calls program_hw_devices.
# Run in Vivado 2018.3 batch; reports every discovered device without programming.
open_hw
connect_hw_server -url localhost:3121
set targets [get_hw_targets -quiet]
if {![llength $targets]} {
    puts "HARDWARE_NOT_FOUND: no JTAG target; check board power, download USB and existing cable driver"
} else {
    foreach target $targets {
        current_hw_target $target
        if {[catch {open_hw_target} problem]} {
            puts "TARGET_OPEN_FAILED: ${target}: $problem"
            continue
        }
        foreach device [get_hw_devices -quiet] {
            puts "HARDWARE_DEVICE: $device, PART=[get_property PART $device]"
            if {[catch {refresh_hw_device $device} problem]} {
                puts "DEVICE_REFRESH_FAILED: $problem"
                continue
            }
            foreach property [list_property $device] {
                if {[string match {REGISTER.CONFIG_STATUS*} $property] || [string match {REGISTER.BOOT_STATUS*} $property] || [string match {REGISTER.USR_ACCESS*} $property]} {
                    puts "DEVICE_STATUS: $property=[get_property $property $device]"
                }
            }
            set ilas [get_hw_ilas -quiet -of_objects $device]
            set vios [get_hw_vios -quiet -of_objects $device]
            puts "DEBUG_CORES: ILA=[llength $ilas], VIO=[llength $vios]"
        }
        close_hw_target
    }
}
disconnect_hw_server
close_hw
puts "READ_ONLY_DISCOVERY_FINISHED: no programming operation performed"
