# Bounded board30 startup check. Keeps run=0 and restores hold_reset=1.
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
proc p {name} {
    global vio
    set result [get_hw_probes -quiet $name -of_objects $vio]
    if {[llength $result] != 1} {error "Missing unique VIO probe $name"}
    return [lindex $result 0]
}
proc expect_input {name expected} {
    set actual [get_property INPUT_VALUE [p $name]]
    puts "BOARD30_STARTUP_STATUS: $name=$actual expected=$expected"
    if {$actual ne $expected} {error "Unexpected $name=$actual"}
}
refresh_hw_vio $vio
if {[get_property OUTPUT_VALUE [p run]] ne "0" || [get_property OUTPUT_VALUE [p hold_reset]] ne "1"} {
    error "Unexpected initial VIO state; refusing startup check"
}
expect_input board_reset_n 1
expect_input locked 1
set outcome [catch {
    set_property OUTPUT_VALUE 0 [p hold_reset]
    commit_hw_vio [p hold_reset]
    after 250
    refresh_hw_vio $vio
    if {[get_property OUTPUT_VALUE [p run]] ne "0"} {error "run changed unexpectedly"}
    expect_input hold_reset_1 0
    expect_input run_1 0
    expect_input sys_release 1
    expect_input afe_configured 1
    expect_input configured 0
    expect_input fault 0
    expect_input receive_error 0
    set usb [get_property INPUT_VALUE [p usb_status_sync]]
    puts "BOARD30_STARTUP_STATUS: usb_status_sync=$usb (bit3 must be release)"
    if {[scan $usb %x usb_value] != 1 || [expr {$usb_value & 8}] == 0} {
        error "USB reset release did not synchronize; 30 MHz MMCM may not be locked"
    }
} problem]
# Always restore the externally observable safe state.
set_property OUTPUT_VALUE 1 [p hold_reset]
commit_hw_vio [p hold_reset]
after 50
refresh_hw_vio $vio
set restore_problem ""
if {[get_property INPUT_VALUE [p hold_reset_1]] ne "1" ||
    [get_property INPUT_VALUE [p run_1]] ne "0" ||
    [get_property INPUT_VALUE [p sys_release]] ne "0"} {
    set restore_problem "Failed to restore held-reset state"
}
close_hw_target
disconnect_hw_server
close_hw
if {$restore_problem ne ""} {error $restore_problem}
if {$outcome} {error $problem}
puts "BOARD30_STARTUP_PASS: 30 MHz clock locked, AD9945 configured, S/K still unset, run remained 0, restored hold_reset=1"
