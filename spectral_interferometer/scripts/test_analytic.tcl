if {[llength $argv] != 1} {error "Pass absolute spectral_interferometer directory with -tclargs"}
set root [lindex $argv 0]
if {[file pathtype $root] ne "absolute"} {error "Root must be absolute"}
open_project [file join $root build fft_ip spectral_fft.xpr]
foreach name {spectral_transform.v positive_peak_filter.v analytic_spectrum.v} {
    add_files -norecurse [file join $root rtl $name]
}
add_files -fileset sim_1 -norecurse [file join $root sim tb_analytic.sv]
set_property top tb_analytic [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
launch_simulation
close_sim
set logstream [open [file join $root build fft_ip spectral_fft.sim sim_1 behav xsim simulate.log] r]
set logtext [read $logstream]
close $logstream
if {![string match {*PASS: analytic chain protocol*} $logtext]} {error "Analytic simulation did not reach success"}
close_project
