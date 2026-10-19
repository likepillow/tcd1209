if {[llength $argv] != 1} {error "Pass absolute spectral_interferometer directory with -tclargs"}
set root [lindex $argv 0]
set output [file join $root build fit_synth]
file mkdir $output
create_project -in_memory -part xc7a200tfbg484-2
read_verilog [file join $root rtl distance_fit.v]
synth_design -mode out_of_context -top distance_fit -part xc7a200tfbg484-2
create_clock -period 10.0 [get_ports clk]
report_utilization -file [file join $output utilization.rpt]
report_timing_summary -file [file join $output timing_synth.rpt]
set brams [get_cells -hier -filter {REF_NAME =~ RAMB*}]
set dsps [get_cells -hier -filter {REF_NAME =~ DSP48*}]
if {[llength $brams] != 2} {error "Expected two coefficient RAM banks"}
if {[llength $dsps] < 1} {error "Fit multiply did not infer DSP"}
write_checkpoint -force [file join $output fit.dcp]
puts "FIT_SYNTH_PASS: [llength $brams] BRAM, [llength $dsps] DSP primitives"
