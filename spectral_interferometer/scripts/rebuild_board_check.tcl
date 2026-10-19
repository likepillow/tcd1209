# Rebuild from current RTL; never reuses the historical unresolved checkpoint.
if {[llength $argv] < 1 || [llength $argv] > 2} {error "Pass project root and optional 30"}
set project_root [lindex $argv 0]
set implementation_args $argv
set mode board
if {[llength $argv] == 2} {
    if {[lindex $argv 1] ne "30"} {error "Unsupported USB variant"}
    set mode board30
}
set argv [list $project_root $mode]
source [file join $project_root scripts synth_processor.tcl]
set argv $implementation_args
source [file join $project_root scripts implement_board_check.tcl]
