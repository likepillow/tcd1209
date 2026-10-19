# Isolated board diagnostic synthesis/implementation. NEVER programs hardware.
# ADC external IO timing is not yet qualified: reports are NOT timing signoff.
if {[llength $argv] != 1} {error "Pass absolute spectral_interferometer root"}
set root [lindex $argv 0]
if {[file pathtype $root] ne "absolute"} {error "Absolute root required"}
set output [file join $root build diag]
if {[file exists [file join $output diagnostic.xpr]]} {error "Diagnostic project exists; inspect it before rebuilding"}
file mkdir $output
create_project diagnostic $output -part xc7a200tfbg484-2
set_property target_language Verilog [current_project]
foreach source {board_clock_reset.v ad9945_init.v adc_pixel_align.v ccd_afe_timing.v ccd_frontend.v diagnostic_top.v} {
    add_files [file join $root rtl $source]
}
create_ip -name vio -vendor xilinx.com -library ip -version 3.0 -module_name diagnostic_vio
set_property -dict [list CONFIG.C_NUM_PROBE_IN {1} CONFIG.C_PROBE_IN0_WIDTH {16} \
    CONFIG.C_NUM_PROBE_OUT {2} CONFIG.C_PROBE_OUT0_WIDTH {1} CONFIG.C_PROBE_OUT1_WIDTH {1} \
    CONFIG.C_PROBE_OUT0_INIT_VAL {0x0} CONFIG.C_PROBE_OUT1_INIT_VAL {0x1}] [get_ips diagnostic_vio]
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name diagnostic_ila
set_property -dict [list CONFIG.C_NUM_OF_PROBES {7} CONFIG.C_DATA_DEPTH {8192} \
    CONFIG.C_EN_STRG_QUAL {1} CONFIG.C_PROBE0_WIDTH {12} CONFIG.C_PROBE1_WIDTH {11} \
    CONFIG.C_PROBE2_WIDTH {32} CONFIG.C_PROBE3_WIDTH {16} CONFIG.C_PROBE4_WIDTH {13} \
    CONFIG.C_PROBE5_WIDTH {12} CONFIG.C_PROBE6_WIDTH {64}] [get_ips diagnostic_ila]
generate_target all [get_ips]
set_property top diagnostic_top [current_fileset]
add_files -fileset constrs_1 [file join $root constraints diagnostic.xdc]
update_compile_order -fileset sources_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Diagnostic synthesis failed"}
launch_runs impl_1 -to_step route_design -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Diagnostic implementation failed"}
open_run impl_1
report_utilization -file [file join $output utilization.rpt]
report_timing_summary -report_unconstrained -file [file join $output timing_summary.rpt]
report_bus_skew -warn_on_violation -file [file join $output bus_skew.rpt]
check_timing -verbose -file [file join $output check_timing.rpt]
report_drc -file [file join $output drc.rpt]
report_io -file [file join $output io.rpt]
write_debug_probes -force [file join $output diagnostic.ltx]
puts "DIAGNOSTIC_ROUTED: no bitstream generated or hardware programmed; external IO timing remains unqualified"
