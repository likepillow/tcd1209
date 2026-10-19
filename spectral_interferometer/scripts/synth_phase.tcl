if {[llength $argv] != 1} {error "Pass absolute spectral_interferometer directory with -tclargs"}
set root [lindex $argv 0]
set output [file join $root build phase_synth]
file mkdir $output
create_project -in_memory -part xc7a200tfbg484-2
read_verilog [file join $root rtl phase_cordic.v]
synth_design -mode out_of_context -top phase_cordic -part xc7a200tfbg484-2
create_clock -period 10.0 [get_ports clk]
report_utilization -file [file join $output utilization.rpt]
report_timing_summary -file [file join $output timing_synth.rpt]
write_checkpoint -force [file join $output phase.dcp]
puts "PHASE_SYNTH_PASS"
