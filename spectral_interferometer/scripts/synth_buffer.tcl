if {[llength $argv] != 1} {error "Pass the absolute spectral_interferometer directory with -tclargs"}
set root [lindex $argv 0]
if {[file pathtype $root] ne "absolute"} {error "Project root must be absolute"}
set output [file join $root build buffer_synth]
file mkdir $output
create_project -in_memory -part xc7a200tfbg484-2
read_verilog [file join $root rtl frame_ping_pong.v]
synth_design -top frame_ping_pong -part xc7a200tfbg484-2
report_utilization -file [file join $output utilization.rpt]
set brams [get_cells -hier -filter {REF_NAME =~ RAMB*}]
if {[llength $brams] < 2} {error "Two frame banks did not infer block RAM"}
write_checkpoint -force [file join $output buffer.dcp]
puts "BUFFER_SYNTH_PASS: [llength $brams] block RAM primitives"
