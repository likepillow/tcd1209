# Read-only hardware audit. Temporary bounds expose routed data-path delays;
# they are NOT external timing constraints or a production signoff.
if {[llength $argv] != 1} {error "Pass absolute project root"}
set root [lindex $argv 0]
if {[file pathtype $root] ne "absolute"} {error "Absolute root required"}
set output [file join $root build io_timing_review]
file mkdir $output
open_checkpoint [file join $root build clipping_implementation refined.dcp]
if {[get_property PART [current_design]] ne "xc7a200tfbg484-2"} {error "Wrong part"}
set outputs [get_ports {ccd_* ad_shp ad_shd ad_pblk ad_clpob ad_dataclk ad_sck ad_sl ad_sdata}]
set capture [get_pins -hier -regexp {instrument/frontend/alignment/m_data_reg\[[0-9]+\]/D}]
if {[llength $capture] != 12} {error "Expected twelve ADC capture D pins: $capture"}
set launch [get_cells -hier -filter {IS_SEQUENTIAL == 1 && (NAME =~ instrument/frontend/timing/* || NAME =~ instrument/frontend/startup/*)}]
if {![llength $launch]} {error "Missing frontend launch registers"}
set_max_delay 100 -datapath_only -from $launch -to $outputs
set_min_delay 0 -from $launch -to $outputs
set_max_delay 100 -datapath_only -from [get_ports {ad_data[*]}] -to $capture
set_min_delay 0 -from [get_ports {ad_data[*]}] -to $capture
set fd [open [file join $output routed_frontend_delays.tsv] w]
puts $fd "path\tcorner\tdatapath_delay_ns\tstartpoint\tendpoint"
foreach output_port $outputs {
    foreach delay_type {max min} {
        set paths [get_timing_paths -from $launch -to $output_port -delay_type $delay_type -max_paths 1]
        if {![llength $paths]} {
            puts $fd "$output_port\t$delay_type\tconstant-or-no-register-path\t-\t-"
        } else {
            set path [lindex $paths 0]
            puts $fd "$output_port\t$delay_type\t[get_property DATAPATH_DELAY $path]\t[get_property STARTPOINT_PIN $path]\t[get_property ENDPOINT_PIN $path]"
        }
    }
}
foreach delay_type {max min} {
    set path [get_timing_paths -from [get_ports {ad_data[*]}] -to $capture -delay_type $delay_type -max_paths 1]
    if {![llength $path]} {error "Missing ADC input route"}
    puts $fd "ad_data_to_capture\t$delay_type\t[get_property DATAPATH_DELAY $path]\t[get_property STARTPOINT_PIN $path]\t[get_property ENDPOINT_PIN $path]"
    report_timing -from [get_ports {ad_data[*]}] -to $capture -delay_type $delay_type -max_paths 12 -file [file join $output adc_capture_${delay_type}.rpt]
}
close $fd
report_timing -from $launch -to [get_ports ad_dataclk] -delay_type max -max_paths 1 -file [file join $output dataclk_launch_max.rpt]
puts "FRONTEND_ROUTE_AUDIT_PASS: diagnostic bounds only; no checkpoint, bitstream, hardware or Flash writes"
close_design
