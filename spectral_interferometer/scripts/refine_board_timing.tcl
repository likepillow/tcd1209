# Diagnostic timing refinement; does not generate a deployable bitstream.
if {[llength $argv] != 1} {error "Pass project root"}
set root [lindex $argv 0]
set output [file join $root build board_refined]
file mkdir $output
open_checkpoint [file join $root build board_implementation optimized.dcp]
read_xdc [file join $root constraints board_cdc.xdc]
if {[llength [get_pins -hier -filter {NAME =~ usb_status_meta_reg*/D}]] != 4} {error "Status sync pins missing"}
if {[llength [get_pins -hier -filter {NAME =~ instrument/transport/*/crossing/read_reset_reg*/PRE}]] != 4} {error "FIFO reset sync pins missing"}
if {[llength [get_pins -hier -filter {NAME =~ sys_release_reg*/CLR || NAME =~ usb_release_reg*/CLR}]] != 32} {error "Reset release pins missing"}
place_design
phys_opt_design -directive AggressiveFanoutOpt
route_design
report_timing_summary -report_unconstrained -file [file join $output timing.rpt]
report_timing -max_paths 30 -file [file join $output paths.rpt]
report_cdc -details -file [file join $output cdc.rpt]
report_drc -file [file join $output drc.rpt]
report_bus_skew -warn_on_violation -file [file join $output bus_skew.rpt]
write_checkpoint -force [file join $output routed.dcp]
puts "REFINEMENT_COMPLETE_NO_BITSTREAM"
