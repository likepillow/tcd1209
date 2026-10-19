# Candidate-only build. Keep deployed control artifacts intact; never program
# hardware or Flash. The existing deployment gates also apply to this variant.
if {[llength $argv] != 1} {error "Pass absolute project root"}
set clipping_root [lindex $argv 0]
if {[file pathtype $clipping_root] ne "absolute"} {error "Absolute root required"}
foreach stage {synth_processor implement_board_check refine_runtime prepare_runtime_bitstream} {
    set argv [list $clipping_root clipping]
    source [file join $clipping_root scripts ${stage}.tcl]
    if {$stage in {implement_board_check refine_runtime}} {close_design}
}
puts "CLIPPING_CANDIDATE_BUILD_PASS: hardware and Flash unchanged"
