# Lower-bound feasibility check, NOT board timing signoff. Zero PCB delay.
# FX2LP datasheet 38-08032 Rev AD tables 20, 23, 26, internal IFCLK.
if {[llength $argv] < 1 || [llength $argv] > 3} {error "Pass root, optional routed checkpoint and report directory"}
set root [lindex $argv 0]
set output [file join $root build fx2_external]
if {[llength $argv] == 3} {set output [lindex $argv 2]}
file mkdir $output
set checkpoint [file join $root build board_implementation routed.dcp]
if {[llength $argv] >= 2} {set checkpoint [lindex $argv 1]}
puts "EXTERNAL_CHECK_INPUT: $checkpoint modified=[clock format [file mtime $checkpoint]]"
open_checkpoint $checkpoint
puts "EXTERNAL_CHECK_CLOCK_PERIOD_NS: [get_property PERIOD [get_clocks usb_clock]]"
set_output_delay -clock usb_clock -max 18.7 [get_ports usb_slrd_n]
set_output_delay -clock usb_clock -max 10.4 [get_ports usb_slwr_n]
set_output_delay -clock usb_clock -max 14.6 [get_ports usb_pktend_n]
set_output_delay -clock usb_clock -max 9.2 [get_ports {usb_fd[*]}]
set_output_delay -clock usb_clock -min 0 [get_ports {usb_slrd_n usb_slwr_n usb_pktend_n usb_fd[*]}]
set_input_delay -clock usb_clock -max 11.0 [get_ports {usb_fd[*]}]
set_input_delay -clock usb_clock -max 9.5 [get_ports {usb_flaga usb_flagb usb_flagc}]
# Datasheet does not provide minimum clock-to-output; zero used for diagnosis.
set_input_delay -clock usb_clock -min 0 [get_ports {usb_fd[*] usb_flaga usb_flagb usb_flagc}]
report_timing -to [get_ports {usb_slrd_n usb_slwr_n usb_pktend_n usb_fd[*]}] -max_paths 24 -file [file join $output outputs.rpt]
# Report controller transitions explicitly so reset-release fanout cannot hide
# the actual active read/write path. No false-path exceptions are added.
set active_regs [get_cells -hier -filter {NAME =~ instrument/transport/controller/* && IS_SEQUENTIAL == 1}]
if {![llength $active_regs]} {error "Controller registers not found"}
report_timing -from $active_regs -to [get_ports {usb_slrd_n usb_slwr_n usb_pktend_n usb_fd[*]}] -max_paths 24 -file [file join $output active_outputs.rpt]
report_timing -delay_type min -from $active_regs -to [get_ports {usb_slrd_n usb_slwr_n usb_pktend_n usb_fd[*]}] -max_paths 24 -file [file join $output active_output_hold.rpt]
report_timing -from [get_ports {usb_fd[*] usb_flaga usb_flagb usb_flagc}] -max_paths 24 -file [file join $output inputs.rpt]
report_timing -delay_type min -from [get_ports {usb_fd[*] usb_flaga usb_flagb usb_flagc}] -max_paths 24 -file [file join $output input_hold.rpt]
report_timing_summary -report_unconstrained -file [file join $output summary.rpt]
puts "FX2_ZERO_PCB_FEASIBILITY_CHECK_COMPLETE: no bitstream, no deployment constraints saved"
