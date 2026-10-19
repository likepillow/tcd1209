# Read-only inspection of the already-programmed board30 safety VIO.
if {[llength $argv] != 1} {error "Pass absolute spectral_interferometer root"}
set root [lindex $argv 0]
open_hw
connect_hw_server -url localhost:3121
set targets [get_hw_targets -quiet]
if {[llength $targets] != 1} {error "Expected one JTAG target"}
current_hw_target [lindex $targets 0]
open_hw_target
set devices [get_hw_devices -quiet]
if {[llength $devices] != 1} {error "Expected one FPGA"}
set device [lindex $devices 0]
set_property PROBES.FILE [file join $root build board30_deploy instrument_board30_test.ltx] $device
refresh_hw_device $device
set vios [get_hw_vios -quiet -of_objects $device]
if {[llength $vios] != 1} {error "Expected one VIO"}
set vio [lindex $vios 0]
refresh_hw_vio $vio
foreach probe [get_hw_probes -of_objects $vio] {
    if {![catch {get_property INPUT_VALUE $probe} value]} {
        puts "BOARD30_VIO: [get_property NAME $probe] direction=input value=$value"
    } else {
        puts "BOARD30_VIO: [get_property NAME $probe] direction=output value=[get_property OUTPUT_VALUE $probe]"
    }
}
close_hw_target
disconnect_hw_server
close_hw
puts "BOARD30_VIO_INSPECTION_COMPLETE: no output commits"
