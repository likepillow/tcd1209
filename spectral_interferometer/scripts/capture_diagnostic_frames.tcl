# Capture four valid-pixel frames through ILA; USB/DSP are not involved.
if {[llength $argv] < 2 || [llength $argv] > 4} {error "Pass absolute project root, output basename, optional pixels/sh mode and settling milliseconds"}
set root [lindex $argv 0]
set basename [lindex $argv 1]
set mode pixels
if {[llength $argv] >= 3} {set mode [lindex $argv 2]}
if {$mode ni {pixels sh}} {error "Invalid capture mode"}
set settle_ms 0
if {[llength $argv] == 4} {set settle_ms [lindex $argv 3]}
if {![string is integer -strict $settle_ms] || $settle_ms < 0 || $settle_ms > 100} {error "Settling time must be 0..100 ms"}
if {[file pathtype $root] ne "absolute" || ![regexp {^[A-Za-z0-9_-]+$} $basename]} {error "Invalid path arguments"}
set output [file join $root build hardware_frames]
file mkdir $output
set csv [file join $output ${basename}.csv]
if {[file exists $csv]} {error "Capture exists; refusing overwrite"}
open_hw
connect_hw_server -url localhost:3121
set targets [get_hw_targets -quiet]
if {[llength $targets] != 1} {error "Expected one target"}
current_hw_target [lindex $targets 0]
open_hw_target
set devices [get_hw_devices -quiet]
if {[llength $devices] != 1} {error "Expected one FPGA"}
set device [lindex $devices 0]
if {[get_property PART $device] ne "xc7a200t"} {error "Wrong FPGA"}
set_property PROBES.FILE [file join $root build diag diagnostic.ltx] $device
refresh_hw_device $device
set ilas [get_hw_ilas -quiet -of_objects $device]
set vios [get_hw_vios -quiet -of_objects $device]
if {[llength $ilas] != 1 || [llength $vios] != 1} {error "Expected diagnostic cores"}
set ila [lindex $ilas 0]
set vio [lindex $vios 0]
proc p {core name} {
    set result [get_hw_probes -quiet $name -of_objects $core]
    if {[llength $result] != 1} {error "Missing unique probe $name"}
    return $result
}
refresh_hw_vio $vio
if {[get_property OUTPUT_VALUE [p $vio run]] ne "0" || [get_property OUTPUT_VALUE [p $vio hold_reset]] ne "1"} {error "Expected held/stopped state"}
if {[get_property INPUT_VALUE [p $vio locked]] ne "1"} {error "Clock not locked"}
set outcome [catch {
    foreach probe [get_hw_probes -of_objects $ila] {
        set width [get_property WIDTH $probe]
        set any "eq${width}'b[string repeat X $width]"
        set_property TRIGGER_COMPARE_VALUE $any $probe
        set_property CAPTURE_COMPARE_VALUE $any $probe
    }
    set_property CONTROL.CAPTURE_MODE BASIC $ila
    set_property CONTROL.CAPTURE_CONDITION AND $ila
    if {[get_property CONTROL.TRIGGER_MODE $ila] ne "BASIC_ONLY"} {error "Unexpected trigger mode"}
    set_property CONTROL.TRIGGER_CONDITION AND $ila
    set_property CONTROL.DATA_DEPTH 8192 $ila
    set_property CONTROL.WINDOW_COUNT 1 $ila
    set_property CONTROL.TRIGGER_POSITION 0 $ila
    set_property CAPTURE_COMPARE_VALUE {eq1'b1} [p $ila valid_1]
    set_property TRIGGER_COMPARE_VALUE {eq1'b1} [p $ila valid_1]
    set_property TRIGGER_COMPARE_VALUE {eq1'b1} [p $ila first_1]
    if {$mode eq "sh"} {
        set_property CONTROL.CAPTURE_MODE ALWAYS $ila
        set_property CONTROL.TRIGGER_POSITION 1024 $ila
        set_property TRIGGER_COMPARE_VALUE {eq1'bX} [p $ila valid_1]
        set_property TRIGGER_COMPARE_VALUE {eq1'bX} [p $ila first_1]
        set_property TRIGGER_COMPARE_VALUE {eq1'b1} [p $ila frame_start_1]
    }
    set_property OUTPUT_VALUE 0 [p $vio hold_reset]
    commit_hw_vio [p $vio hold_reset]
    after 20
    refresh_hw_vio $vio
    if {[get_property INPUT_VALUE [p $vio configured]] ne "1"} {error "AFE startup not complete"}
    if {$settle_ms > 0} {
        set_property OUTPUT_VALUE 1 [p $vio run]
        commit_hw_vio [p $vio run]
        after $settle_ms
        run_hw_ila $ila
    } else {
        run_hw_ila $ila
        set_property OUTPUT_VALUE 1 [p $vio run]
        commit_hw_vio [p $vio run]
    }
    # Vivado timeout is in minutes: 0.05 = three seconds, not 50 ms.
    wait_on_hw_ila -timeout 0.05 $ila
} problem]
# Stop acquisition before transferring captured data over slow JTAG.
set_property OUTPUT_VALUE 0 [p $vio run]
commit_hw_vio [p $vio run]
after 2
refresh_hw_vio $vio
puts "STOP_STATUS: busy=[get_property INPUT_VALUE [p $vio busy]], fault=[get_property INPUT_VALUE [p $vio fault]]"
set_property OUTPUT_VALUE 1 [p $vio hold_reset]
commit_hw_vio [p $vio hold_reset]
after 2
refresh_hw_vio $vio
if {[get_property INPUT_VALUE [p $vio hold_reset_2]] ne "1" || [get_property INPUT_VALUE [p $vio run_2]] ne "0"} {error "Failed to restore held/stopped state"}
if {!$outcome} {
    set data [upload_hw_ila_data $ila]
    write_hw_ila_data -csv_file $csv $data
    puts "HARDWARE_CAPTURE_SAVED: $csv; index/frame/pixel validation still required"
} else {
    catch {stop_hw_ila $ila}
}
close_hw_target
disconnect_hw_server
close_hw
if {$outcome} {error $problem}
puts "CAPTURE_FINISHED_HELD_RESET: run=0 hold_reset=1; no Flash or USB transfer"
