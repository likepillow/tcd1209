# Local generation only: no hardware manager, programming or Flash access.
if {[llength $argv] != 1} {error "Pass absolute spectral_interferometer root"}
set root [lindex $argv 0]
if {[file pathtype $root] ne "absolute"} {error "Absolute root required"}
set output [file join $root build diag]
set checkpoint [file join $output diagnostic.runs impl_1 diagnostic_top_routed.dcp]
if {![file exists $checkpoint]} {error "Missing routed diagnostic checkpoint"}
set bitfile [file join $output diagnostic.bit]
if {[file exists $bitfile]} {error "Diagnostic bitstream already exists; do not overwrite implicitly"}
open_checkpoint $checkpoint
if {[get_property PART [current_design]] ne "xc7a200tfbg484-2"} {error "Wrong part"}
# open_checkpoint creates a checkpoint_* design container and an empty source
# fileset in Vivado 2018.3. Validate the actual netlist interface/debug cores,
# not the source-fileset TOP property (which is empty in this flow).
foreach core {capture control} {
    if {[llength [get_cells -quiet $core]] != 1} {error "Missing diagnostic core: $core"}
    puts "DIAGNOSTIC_CORE: $core REF_NAME=[get_property REF_NAME [get_cells $core]]"
}
foreach port {clk_50mhz reset_button_n ccd_phi1 ccd_phi2 ccd_sh ccd_rs ccd_cp ad_shp ad_shd ad_dataclk ad_clpob ad_pblk ad_sck ad_sdata ad_sl} {
    if {[llength [get_ports -quiet $port]] != 1} {error "Missing diagnostic port: $port"}
}
# Metadata only; these do not change the routed logic or clock constraints.
# Source: ACX720-V3-SCH.pdf p2 CFGBVS U8, p3 VCCO_0 E12/T12.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup [current_design]
foreach property {CFGBVS CONFIG_VOLTAGE BITSTREAM.CONFIG.UNUSEDPIN} {
    puts "CONFIG_PROPERTY: $property=[get_property $property [current_design]]"
}
if {[llength [get_ports]] != 27} {error "Unexpected diagnostic port count"}
foreach port [get_ports] {
    if {[get_property PACKAGE_PIN $port] eq ""} {error "Unassigned pin: $port"}
    if {[get_property IOSTANDARD $port] ne "LVCMOS33"} {error "Wrong IO voltage: $port"}
}
foreach delay_type {max min} {
    set path [get_timing_paths -delay_type $delay_type -max_paths 1]
    if {![llength $path]} {error "No timing path for $delay_type"}
    if {[get_property SLACK $path] < 0} {error "Failing internal $delay_type timing"}
}
report_drc -file [file join $output prebit_drc.rpt]
set severe [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == "Critical Warning"}]
if {[llength $severe]} {error "Blocking DRC violations: $severe"}
report_timing_summary -report_unconstrained -file [file join $output prebit_timing.rpt]
report_bus_skew -warn_on_violation -file [file join $output prebit_bus_skew.rpt]
write_checkpoint [file join $output diagnostic_ready.dcp]
write_debug_probes -force [file join $output diagnostic.ltx]
write_bitstream $bitfile
puts "DIAGNOSTIC_BITSTREAM_GENERATED: local only; external ADC timing not qualified; no programming performed"
