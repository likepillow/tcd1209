if {[llength $argv] < 1 || [llength $argv] > 2} {error "Pass project root and optional variant"}
set root [lindex $argv 0]
set variant [expr {[llength $argv] == 2 ? [lindex $argv 1] : "runtime"}]
if {$variant ni {runtime control clipping capture40 exposure}} {error "Unsupported variant"}
switch $variant {
    control {set marker 26092402}
    clipping {set marker 26100301}
    capture40 {set marker 26100440}
    exposure {set marker 26102402}
    runtime {set marker 26092401}
}
open_hw
connect_hw_server -url localhost:3121
set targets [get_hw_targets -quiet]
if {[llength $targets] != 1} {error "Expected one JTAG target, got [llength $targets]"}
current_hw_target [lindex $targets 0]
open_hw_target
set devices [get_hw_devices -quiet]
if {[llength $devices] != 1} {error "Expected one FPGA, got [llength $devices]"}
set dev [lindex $devices 0]
if {[get_property PART $dev] ne "xc7a200t"} {error "Wrong FPGA"}
set_property PROBES.FILE {} $dev
set_property PROGRAM.FILE [file join $root build ${variant}_deploy instrument_${variant}.bit] $dev
program_hw_devices $dev
refresh_hw_device $dev
if {[get_property REGISTER.USR_ACCESS $dev] ne $marker} {error "Wrong runtime version"}
puts "[string toupper $variant]_VOLATILE_PROGRAM_PASS: power-up stopped; Flash unchanged"
close_hw_target
disconnect_hw_server
close_hw
