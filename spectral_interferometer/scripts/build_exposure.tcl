# Offline candidate only; does not connect JTAG or write Flash.
if {[llength $argv] != 1} {error "Pass absolute project root"}
set exposure_root [lindex $argv 0]
if {[file pathtype $exposure_root] ne "absolute"} {error "Absolute root required"}
foreach stage {synth_processor implement_board_check refine_runtime prepare_runtime_bitstream} {
    set argv [list $exposure_root exposure]
    source [file join $exposure_root scripts ${stage}.tcl]
    if {$stage in {implement_board_check refine_runtime}} {close_design}
}
puts "EXPOSURE_OFFLINE_BUILD_PASS: no programming operation"
