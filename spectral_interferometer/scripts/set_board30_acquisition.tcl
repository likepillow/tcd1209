# Start/stop the volatile board30 test design through its safety VIO.
if {[llength $argv] != 2} {error "Pass absolute spectral_interferometer root and start|stop"}
set root [lindex $argv 0]
set action [lindex $argv 1]
if {$action ni {start stop}} {error "Action must be start or stop"}
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
proc p {name} {
    global vio
    set result [get_hw_probes -quiet $name -of_objects $vio]
    if {[llength $result] != 1} {error "Missing unique VIO probe $name"}
    return [lindex $result 0]
}
proc input {name} {return [get_property INPUT_VALUE [p $name]]}
refresh_hw_vio $vio
set outcome 0
set problem ""
if {$action eq "start"} {
    if {[get_property OUTPUT_VALUE [p run]] ne "0" || [get_property OUTPUT_VALUE [p hold_reset]] ne "1"} {
        set outcome 1;set problem "Start requires run=0 and hold_reset=1"
    } else {
        set outcome [catch {
            set_property OUTPUT_VALUE 0 [p hold_reset]
            commit_hw_vio [p hold_reset]
            after 300
            refresh_hw_vio $vio
            if {[input sys_release] ne "1" || [input afe_configured] ne "1" || [input fault] ne "0" || [input receive_error] ne "0"} {
                error "Startup status invalid: release=[input sys_release] afe_configured=[input afe_configured] fault=[input fault] receive_error=[input receive_error]"
            }
            set_property OUTPUT_VALUE 1 [p run]
            commit_hw_vio [p run]
            after 20
            refresh_hw_vio $vio
            if {[input run_1] ne "1" || [input fault] ne "0"} {error "Acquisition failed to start cleanly"}
            puts "BOARD30_ACQUISITION_STARTED: run=1 hold_reset=0 afe_configured=1"
        } problem]
        if {$outcome} {
            set_property OUTPUT_VALUE 0 [p run]
            commit_hw_vio [p run]
            after 5
            set_property OUTPUT_VALUE 1 [p hold_reset]
            commit_hw_vio [p hold_reset]
        }
    }
} else {
    set_property OUTPUT_VALUE 0 [p run]
    commit_hw_vio [p run]
    after 10
    set_property OUTPUT_VALUE 1 [p hold_reset]
    commit_hw_vio [p hold_reset]
    after 30
    refresh_hw_vio $vio
    if {[input run_1] ne "0" || [input hold_reset_1] ne "1" || [input sys_release] ne "0"} {
        set outcome 1;set problem "Failed to restore stopped/held state"
    } else {
        puts "BOARD30_ACQUISITION_STOPPED: run=0 hold_reset=1"
    }
}
close_hw_target
disconnect_hw_server
close_hw
if {$outcome} {error $problem}
