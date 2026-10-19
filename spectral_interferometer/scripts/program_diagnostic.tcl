# Explicit volatile JTAG programming of the isolated, held-reset diagnostic.
# No Flash operation; never commits VIO output changes or starts CCD capture.
if {[llength $argv] != 1} {error "Pass absolute spectral_interferometer root"}
set root [lindex $argv 0]
if {[file pathtype $root] ne "absolute"} {error "Absolute root required"}
set bitfile [file join $root build diag diagnostic.bit]
set probes [file join $root build diag diagnostic.ltx]
if {![file exists $bitfile] || ![file exists $probes]} {error "Missing bitstream/probes"}
open_hw
connect_hw_server -url localhost:3121
set targets [get_hw_targets -quiet]
if {[llength $targets] != 1} {error "Expected exactly one connected JTAG target"}
current_hw_target [lindex $targets 0]
open_hw_target
set devices [get_hw_devices -quiet]
if {[llength $devices] != 1} {error "Expected exactly one FPGA"}
set device [lindex $devices 0]
if {[get_property PART $device] ne "xc7a200t"} {error "Unexpected FPGA part"}
current_hw_device $device
set_property PROGRAM.FILE $bitfile $device
set_property PROBES.FILE $probes $device
program_hw_devices $device
refresh_hw_device $device
set ilas [get_hw_ilas -quiet -of_objects $device]
set vios [get_hw_vios -quiet -of_objects $device]
puts "DIAGNOSTIC_DEBUG_CORES: ILA=[llength $ilas], VIO=[llength $vios]"
if {[llength $ilas] != 1 || [llength $vios] != 1} {error "Expected diagnostic ILA and VIO"}
foreach vio $vios {
    refresh_hw_vio $vio
    foreach probe [get_hw_probes -of_objects $vio] {
        puts "VIO_PROBE: $probe"
        foreach property [list_property $probe] {
            if {$property in {INPUT_VALUE OUTPUT_VALUE WIDTH PROBE_TYPE}} {
                puts "  $property=[get_property $property $probe]"
            }
        }
    }
}
close_hw_target
disconnect_hw_server
close_hw
puts "DIAGNOSTIC_PROGRAMMED_HELD_RESET: no VIO output commits, no CCD start, no Flash writes"
