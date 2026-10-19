set root [lindex $argv 0]
open_checkpoint [file join $root build standalone_implementation routed.dcp]
read_xdc [file join $root constraints board_cdc.xdc]
read_xdc [file join $root constraints fx2_30mhz_feasibility.xdc]
# Reserve 0.5 ns implementation margin; final gate restores the data-sheet min=0.
set_input_delay -clock usb_clock -min -0.5 [get_ports {usb_fd[*] usb_flaga usb_flagb usb_flagc}]
set sync_pin [get_pins -hier -regexp {.*clock_guard/toggle_sync_reg\[0\]/D}]
if {[llength $sync_pin] != 1} {error "Missing first CDC synchronizer"}
route_design -unroute
set enables [get_nets -of_objects [get_pins -hier -filter {NAME =~ *ce_predicted_reg/Q}]]
puts "FFT_ENABLE_NETS: $enables"
if {[llength $enables] != 2} {error "Expected two FFT enable nets"}
phys_opt_design -force_replication_on_nets $enables
route_design
report_timing_summary -report_unconstrained -file [file join $root build standalone_implementation timing_refined.rpt]
report_cdc -details -file [file join $root build standalone_implementation cdc_refined.rpt]
write_checkpoint -force [file join $root build standalone_implementation refined.dcp]
