# Bounded VIO startup check. Never asserts run, reprograms FPGA, or writes Flash.
if {[llength $argv] != 1} {error "Pass absolute project root"}
set root [lindex $argv 0]
open_hw
connect_hw_server -url localhost:3121
set targets [get_hw_targets -quiet]
if {[llength $targets] != 1} {error "Expected one JTAG target"}
current_hw_target [lindex $targets 0]
open_hw_target
set devices [get_hw_devices -quiet]
if {[llength $devices] != 1} {error "Expected one device"}
set device [lindex $devices 0]
if {[get_property PART $device] ne "xc7a200t"} {error "Wrong FPGA"}
set_property PROBES.FILE [file join $root build diag diagnostic.ltx] $device
refresh_hw_device $device
set vios [get_hw_vios -quiet -of_objects $device]
if {[llength $vios] != 1} {error "Expected diagnostic VIO"}
set vio [lindex $vios 0]
proc probe {name} {
    global vio
    set p [get_hw_probes -quiet $name -of_objects $vio]
    if {[llength $p] != 1} {error "Missing unique VIO probe $name"}
    return $p
}
proc expect_input {name value} {
    set actual [get_property INPUT_VALUE [probe $name]]
    puts "AFE_STATUS: $name=$actual expected=$value"
    if {$actual ne $value} {error "Unexpected $name=$actual"}
}
refresh_hw_vio $vio
if {[get_property OUTPUT_VALUE [probe run]] ne "0" || [get_property OUTPUT_VALUE [probe hold_reset]] ne "1"} {
    error "Expected held reset and stopped state; refusing to alter unexpected state"
}
expect_input locked 1
expect_input board_reset_n 1
expect_input configured 0
set outcome [catch {
    set_property OUTPUT_VALUE 0 [probe hold_reset]
    commit_hw_vio [probe hold_reset]
    after 20
    refresh_hw_vio $vio
    expect_input hold_reset_2 0
    expect_input run_2 0
    expect_input release_pipe 1
    expect_input configured 1
    expect_input busy 0
    expect_input fault 0
    expect_input valid 0
} problem]
# Restore the known held state even when the initialization check fails.
set_property OUTPUT_VALUE 1 [probe hold_reset]
commit_hw_vio [probe hold_reset]
after 10
refresh_hw_vio $vio
expect_input hold_reset_2 1
expect_input run_2 0
expect_input release_pipe 0
expect_input configured 0
expect_input busy 0
expect_input fault 0
close_hw_target
disconnect_hw_server
close_hw
if {$outcome} {error $problem}
puts "AFE_STARTUP_CONTROL_PASS: configured asserted with run=0; restored held reset; serial transmission only, not AD9945 readback"
