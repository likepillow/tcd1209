if {[llength $argv] != 1} {error "Pass absolute spectral_interferometer directory with -tclargs"}
set root [lindex $argv 0]
if {[file pathtype $root] ne "absolute"} {error "Root must be absolute"}
set output [file join $root build normalize_synth]
file mkdir $output
create_project -in_memory -part xc7a200tfbg484-2
read_verilog [file join $root rtl normalize_frame.v]
synth_design -mode out_of_context -top normalize_frame -part xc7a200tfbg484-2
create_clock -period 10.0 [get_ports clk]
report_utilization -file [file join $output utilization.rpt]
report_timing_summary -file [file join $output timing_synth.rpt]
set brams [get_cells -hier -filter {REF_NAME =~ RAMB*}]
set dsps [get_cells -hier -filter {REF_NAME =~ DSP48*}]
if {[llength $brams] < 3} {error "Coefficient and data memories did not infer BRAM"}
if {[llength $dsps] < 1} {error "Reciprocal multiply did not infer DSP"}
write_checkpoint -force [file join $output normalize.dcp]
puts "NORMALIZE_SYNTH_PASS: [llength $brams] BRAM, [llength $dsps] DSP primitives"
