if {[llength $argv] != 1} {error "Pass project root"}
set standalone_root [lindex $argv 0]
set argv [list $standalone_root standalone]
source [file join $standalone_root scripts synth_processor.tcl]
set argv [list $standalone_root standalone]
source [file join $standalone_root scripts implement_board_check.tcl]
set argv [list $standalone_root]
source [file join $standalone_root scripts refine_standalone.tcl]
