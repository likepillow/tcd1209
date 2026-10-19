# Volatile JTAG programming. VIO defaults must leave acquisition stopped/reset.
# No configuration Flash access and no VIO output commits are performed here.
if {[llength $argv] != 1} {error "Pass absolute spectral_interferometer root"}
set root [lindex $argv 0]
if {[file pathtype $root] ne "absolute"} {error "Absolute root required"}
set output [file join $root build board30_deploy]
set bitfile [file join $output instrument_board30_test.bit]
set probes [file join $output instrument_board30_test.ltx]
if {![file exists $bitfile] || ![file exists $probes]} {error "Missing board30 bitstream/probes"}
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
set vios [get_hw_vios -quiet -of_objects $device]
if {[llength $vios] != 1} {error "Expected one safety VIO"}
set vio [lindex $vios 0]
refresh_hw_vio $vio
proc find_probe {vio name} {
    set result [get_hw_probes -quiet $name -of_objects $vio]
    if {[llength $result] != 1} {error "Expected one VIO probe named $name"}
    return [lindex $result 0]
}
set run [find_probe $vio run]
set hold [find_probe $vio hold_reset]
puts "BOARD30_SAFE_VIO: run=[get_property OUTPUT_VALUE $run] hold_reset=[get_property OUTPUT_VALUE $hold]"
if {[get_property OUTPUT_VALUE $run] ne "0" || [get_property OUTPUT_VALUE $hold] ne "1"} {
    error "Unsafe VIO power-up values; acquisition was not released"
}
close_hw_target
disconnect_hw_server
close_hw
puts "BOARD30_PROGRAMMED_HELD_RESET: volatile only; no Flash write and no acquisition start"
