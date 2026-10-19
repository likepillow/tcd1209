if {[llength $argv] != 1} {error "Pass project root"}
set runtime_root [lindex $argv 0]
set argv [list $runtime_root runtime]
source [file join $runtime_root scripts synth_processor.tcl]
set argv [list $runtime_root runtime]
source [file join $runtime_root scripts implement_board_check.tcl]
