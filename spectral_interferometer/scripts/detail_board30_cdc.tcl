# Read-only CDC audit of the routed 30 MHz candidate.
if {[llength $argv] != 1} {error "Pass absolute spectral_interferometer root"}
set root [lindex $argv 0]
if {[file pathtype $root] ne "absolute"} {error "Absolute root required"}
set checkpoint [file join $root build board30_implementation routed.dcp]
if {![file exists $checkpoint]} {error "Missing routed 30 MHz checkpoint"}
open_checkpoint $checkpoint
report_cdc -details -file [file join $root build board30_implementation cdc_details.rpt]
puts "BOARD30_CDC_DETAILS_COMPLETE: read-only; no checkpoint or hardware changes"
