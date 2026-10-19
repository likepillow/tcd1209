# Read-only hardware inventory and installed-tool capabilities. No programming.
open_hw
connect_hw_server -url localhost:3121
set targets [get_hw_targets -quiet]
if {[llength $targets] != 1} {error "Expected one JTAG target"}
current_hw_target [lindex $targets 0]
open_hw_target
set devices [get_hw_devices -quiet]
if {[llength $devices] != 1} {error "Expected one FPGA"}
set dev [lindex $devices 0]
refresh_hw_device $dev
report_property $dev
puts "FLASH_PARTS: [get_cfgmem_parts -quiet -filter {NAME == mx25l12845g-spi-x1_x2_x4 && MEM_TYPE == spi}]"
foreach command {readback_hw_cfgmem program_hw_cfgmem create_hw_cfgmem read_hw_device} {
    puts "CAPABILITY $command: [info commands $command]"
    if {[llength [info commands $command]]} {puts [help $command]}
}
close_hw_target
disconnect_hw_server
close_hw
