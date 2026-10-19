if {[llength $argv] != 1} {error "Pass project root"}
set control_root [lindex $argv 0]
set argv [list $control_root control]
source [file join $control_root scripts synth_processor.tcl]
set argv [list $control_root control]
source [file join $control_root scripts implement_board_check.tcl]
