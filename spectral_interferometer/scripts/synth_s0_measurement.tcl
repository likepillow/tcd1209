set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build s0_measurement_synth]
file mkdir $out
create_project -in_memory -part xc7a200tfbg484-2
foreach name {packet_frame_buffer s0_export_buffer packet_tx raw_packet_tx raw_stream_packet_tx result_packet_tx spectrum_packet_tx spectrum_stream_packet_tx packet_scheduler measurement_packet_tx s0_measurement_packet_tx} {
    read_verilog [file join $root rtl ${name}.v]
}
synth_design -top s0_measurement_packet_tx -part xc7a200tfbg484-2 -mode out_of_context
create_clock -period 10.000 [get_ports clk]
report_utilization -file [file join $out utilization.rpt]
report_timing_summary -file [file join $out timing.rpt]
if {[llength [get_cells -hier -filter {IS_BLACKBOX == 1}]]} {error "Unresolved blackboxes"}
write_checkpoint -force [file join $out s0_measurement.dcp]
puts "PASS: S0 buffered measurement boundary synthesized without blackboxes; OOC only"
