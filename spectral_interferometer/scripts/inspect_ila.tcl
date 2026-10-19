if {[llength $argv] != 1} {error "Pass absolute project root"}
set root [lindex $argv 0]
open_hw
connect_hw_server -url localhost:3121
set targets [get_hw_targets -quiet]
if {[llength $targets] != 1} {error "Expected one target"}
current_hw_target [lindex $targets 0]
open_hw_target
set devices [get_hw_devices -quiet]
if {[llength $devices] != 1} {error "Expected one device"}
set device [lindex $devices 0]
set_property PROBES.FILE [file join $root build diag diagnostic.ltx] $device
refresh_hw_device $device
set ilas [get_hw_ilas -quiet -of_objects $device]
if {[llength $ilas] != 1} {error "Expected one ILA"}
set ila [lindex $ilas 0]
foreach property [list_property $ila] {
    if {[string match CONTROL.* $property] || [string match STATUS.* $property]} {
        puts "ILA_PROPERTY: $property=[get_property $property $ila]"
    }
}
foreach probe [get_hw_probes -of_objects $ila] {
    puts "ILA_PROBE: $probe WIDTH=[get_property WIDTH $probe]"
    foreach property {TRIGGER_COMPARE_VALUE CAPTURE_COMPARE_VALUE} {
        if {$property in [list_property $probe]} {puts "  $property=[get_property $property $probe]"}
    }
}
help wait_on_hw_ila
help upload_hw_ila_data
help write_hw_ila_data
close_hw_target
disconnect_hw_server
close_hw
