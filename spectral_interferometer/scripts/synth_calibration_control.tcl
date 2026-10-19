set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build calibration_control_synth]
file mkdir $out
create_project -in_memory -part xc7a200tfbg484-2
foreach name {config_packet_rx calibration_loader packet_tx ack_packet_tx calibration_control} {
    read_verilog [file join $root rtl ${name}.v]
}
synth_design -top calibration_control -part xc7a200tfbg484-2 -mode out_of_context
create_clock -period 10.000 [get_ports clk]
report_utilization -file [file join $out utilization.rpt]
report_timing_summary -file [file join $out timing.rpt]
if {[llength [get_cells -hier -filter {IS_BLACKBOX == 1}]]} {error "Unresolved blackboxes"}
write_checkpoint -force [file join $out control.dcp]
puts "PASS: calibration control synthesized without blackboxes; OOC only"
