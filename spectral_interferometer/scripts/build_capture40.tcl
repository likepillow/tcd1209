# Offline diagnostic candidate only. No hardware manager or Flash operation.
# Keep the deployed clipping artifacts and capture delay default unchanged.
if {[llength $argv] != 1} {error "Pass absolute project root"}
set capture40_root [lindex $argv 0]
if {[file pathtype $capture40_root] ne "absolute"} {error "Absolute root required"}
foreach stage {synth_processor implement_board_check refine_runtime prepare_runtime_bitstream} {
    set argv [list $capture40_root capture40]
    source [file join $capture40_root scripts ${stage}.tcl]
    if {$stage in {implement_board_check refine_runtime}} {close_design}
}
puts "CAPTURE40_OFFLINE_BUILD_PASS: hardware and Flash unchanged"
