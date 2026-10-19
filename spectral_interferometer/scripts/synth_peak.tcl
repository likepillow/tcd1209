if {[llength $argv] != 1} {error "Pass absolute spectral_interferometer directory with -tclargs"}
set root [lindex $argv 0]
set output [file join $root build peak_synth]
file mkdir $output
create_project -in_memory -part xc7a200tfbg484-2
read_verilog [file join $root rtl positive_peak_filter.v]
synth_design -mode out_of_context -top positive_peak_filter -part xc7a200tfbg484-2
create_clock -period 10.0 [get_ports clk]
report_utilization -file [file join $output utilization.rpt]
report_timing_summary -file [file join $output timing_synth.rpt]
set brams [get_cells -hier -filter {REF_NAME =~ RAMB*}]
set dsps [get_cells -hier -filter {REF_NAME =~ DSP48*}]
if {[llength $brams] < 4} {error "Complex spectrum and power buffers did not infer BRAM"}
write_checkpoint -force [file join $output peak.dcp]
puts "PEAK_SYNTH_PASS: [llength $brams] BRAM, [llength $dsps] DSP primitives"
