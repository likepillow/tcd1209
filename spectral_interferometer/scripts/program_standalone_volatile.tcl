set root [lindex $argv 0]
open_hw
connect_hw_server -url localhost:3121
set targets [get_hw_targets -quiet]
if {[llength $targets]!=1} {error "Expected one JTAG target"}
current_hw_target [lindex $targets 0]
open_hw_target
set devices [get_hw_devices -quiet]
if {[llength $devices]!=1} {error "Expected one FPGA"}
set dev [lindex $devices 0]
if {[get_property PART $dev] ne "xc7a200t"} {error "Wrong FPGA"}
set_property PROBES.FILE {} $dev
set_property PROGRAM.FILE [file join $root build standalone_deploy instrument_standalone.bit] $dev
program_hw_devices $dev
refresh_hw_device $dev
if {[get_property REGISTER.USR_ACCESS $dev] ne "26092304"} {error "Wrong standalone version"}
puts "STANDALONE_VOLATILE_PROGRAM_PASS: auto-start; no VIO/JTAG controls required"
close_hw_target
disconnect_hw_server
close_hw
