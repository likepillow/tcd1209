if {[llength $argv] != 0} {error "No arguments expected"}
open_hw
connect_hw_server -url localhost:3121
set targets [get_hw_targets -quiet]
if {[llength $targets] != 1} {error "Expected one JTAG target"}
current_hw_target [lindex $targets 0]
open_hw_target
set devices [get_hw_devices -quiet]
if {[llength $devices] != 1} {error "Expected one FPGA"}
set dev [lindex $devices 0]
current_hw_device $dev
if {[get_property PART $dev] ne "xc7a200t"} {error "Wrong FPGA"}
boot_hw_device $dev
after 1500
refresh_hw_device $dev
if {[get_property REGISTER.USR_ACCESS $dev] ne "26100301"} {error "Clipping image did not boot from Flash"}
puts "CLIPPING_FLASH_BOOT_PASS: USR_ACCESS=26100301"
close_hw_target
disconnect_hw_server
close_hw
