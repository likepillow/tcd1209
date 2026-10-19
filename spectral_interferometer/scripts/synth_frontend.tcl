if {[llength $argv] != 1} {error "Pass absolute spectral_interferometer root with -tclargs"}
set root [lindex $argv 0]
if {[file pathtype $root] ne "absolute"} {error "Project root must be absolute"}
set output [file join $root build frontend_synth]
file mkdir $output
create_project -in_memory -part xc7a200tfbg484-2
foreach source {ad9945_init.v adc_pixel_align.v ccd_afe_timing.v ccd_frontend.v} {
    read_verilog [file join $root rtl $source]
}
synth_design -top ccd_frontend -part xc7a200tfbg484-2 -mode out_of_context
create_clock -name sys_clk -period 10.000 [get_ports clk]
set unresolved [get_cells -hier -filter {IS_BLACKBOX == 1}]
if {[llength $unresolved]} {error "Unresolved frontend modules: $unresolved"}
report_utilization -file [file join $output utilization.rpt]
report_timing_summary -file [file join $output timing_summary.rpt]
check_timing -verbose -file [file join $output check_timing.rpt]
write_checkpoint -force [file join $output frontend.dcp]
puts "FRONTEND_SYNTH_PASS: no unresolved modules; OOC only, not board IO timing signoff"
