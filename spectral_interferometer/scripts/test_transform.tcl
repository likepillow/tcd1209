if {[llength $argv] != 1} {error "Pass absolute spectral_interferometer directory with -tclargs"}
set root [lindex $argv 0]
if {[file pathtype $root] ne "absolute"} {error "Root must be absolute"}
open_project [file join $root build fft_ip spectral_fft.xpr]
add_files -norecurse [file join $root rtl spectral_transform.v]
add_files -fileset sim_1 -norecurse [file join $root sim tb_transform.sv]
set_property top tb_transform [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
launch_simulation
close_sim
set logpath [file join $root build fft_ip spectral_fft.sim sim_1 behav xsim simulate.log]
set logstream [open $logpath r]
set logtext [read $logstream]
close $logstream
if {![string match {*PASS: generated XFFT FFT/IFFT*} $logtext]} {error "Transform simulation did not reach its success assertion"}
close_project
