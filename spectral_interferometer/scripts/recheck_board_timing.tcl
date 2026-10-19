if {[llength $argv] != 1} {error "Pass project root"}
set root [lindex $argv 0]
set output [file join $root build board_recheck]
file mkdir $output
open_checkpoint [file join $root build board_refined routed.dcp]
read_xdc [file join $root constraints board_cdc.xdc]
foreach {pattern expected} {
    usb_status_meta_reg*/D 4
    instrument/transport/*/crossing/read_reset_reg*/PRE 4
    instrument/transport/rx_bridge/rd_reset_reg*/PRE 2
    sys_release_reg*/CLR 16
    usb_release_reg*/CLR 16
} {
    set pins [get_pins -hier -filter "NAME =~ $pattern"]
    if {[llength $pins] != $expected} {error "Unexpected pin count: $pattern"}
}
report_timing_summary -report_unconstrained -file [file join $output timing.rpt]
report_cdc -details -file [file join $output cdc.rpt]
report_bus_skew -warn_on_violation -file [file join $output bus_skew.rpt]
report_drc -file [file join $output drc.rpt]
foreach type {max min} {
    set worst [get_timing_paths -delay_type $type -max_paths 1]
    puts "INTERNAL_TIMING_$type: [get_property SLACK $worst]"
    if {[get_property SLACK $worst] < 0} {error "Internal timing failed"}
}
write_checkpoint -force [file join $output routed.dcp]
puts "INTERNAL_TIMING_RECHECK_PASS: external interface delays still unqualified; no bitstream"
