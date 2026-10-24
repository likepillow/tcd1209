# Analysis only. Deliberately never generates or programs a bitstream.
if {[llength $argv] < 1 || [llength $argv] > 2} {error "Pass root and optional 30"}
set root [lindex $argv 0]
set variant board
if {[llength $argv] == 2} {
    switch [lindex $argv 1] {
        30 {set variant board30}
        standalone {set variant standalone}
        runtime {set variant runtime}
        control {set variant control}
        clipping {set variant clipping}
        capture40 {set variant capture40}
        exposure {set variant exposure}
        default {error "Unsupported USB variant"}
    }
}
set output [file join $root build ${variant}_implementation]
file mkdir $output
open_checkpoint [file join $root build ${variant}_synth processor.dcp]
if {[get_property PART [current_design]] ne "xc7a200tfbg484-2"} {error "Wrong device"}
read_xdc [file join $root constraints diagnostic.xdc]
read_xdc [file join $root constraints fx2_pins.xdc]
if {[llength [get_ports -quiet user_led*]]} {read_xdc [file join $root constraints user_led.xdc]}
if {![llength [get_clocks -quiet usb_clock]]} {
    error "Synthesized board checkpoint is missing USB clock constraint"
}
report_io -file [file join $output io.rpt]
opt_design
read_xdc [file join $root constraints board_cdc.xdc]
set unresolved [get_cells -quiet -hier -filter {IS_BLACKBOX == 1}]
if {[llength $unresolved]} {error "Post-opt unresolved cells: $unresolved"}
write_checkpoint -force [file join $output optimized.dcp]
place_design
phys_opt_design -directive AggressiveFanoutOpt
route_design
report_drc -file [file join $output drc.rpt]
report_timing_summary -report_unconstrained -file [file join $output timing.rpt]
report_cdc -file [file join $output cdc.rpt]
report_bus_skew -warn_on_violation -file [file join $output bus_skew.rpt]
write_checkpoint -force [file join $output routed.dcp]
puts "BOARD_IMPLEMENTATION_ANALYSIS_COMPLETE: external IO timing not signed off; no bitstream generated"
