if {[llength $argv] < 1 || [llength $argv] > 2} {error "Pass absolute directory and optional capture mode with -tclargs"}
set root [lindex $argv 0]
set capture_mode 0
set packet_mode 0
if {[llength $argv] == 2} {
    if {[lindex $argv 1] ni {capture capture_packet}} {error "Second argument must be capture or capture_packet"}
    set capture_mode 1
    if {[lindex $argv 1] eq "capture_packet"} {set packet_mode 1}
}
if {[file pathtype $root] ne "absolute"} {error "Root must be absolute"}
open_project [file join $root build fft_ip spectral_fft.xpr]
# Vivado 2018.3 can retain a stale central-simulation path when the project is
# moved.  Pin both generated-file directories to this checkout before launch.
set_property ip.user_files_dir [file join $root build fft_ip spectral_fft.ip_user_files] [current_project]
set_property sim.ipstatic.source_dir [file join $root build fft_ip spectral_fft.ip_user_files ipstatic] [current_project]
set_param project.enableCentralSimRepo false
add_files -norecurse [file join $root rtl s0_measurement_packet_tx.v]
foreach name {normalize_frame.v spectral_transform.v positive_peak_filter.v analytic_spectrum.v phase_cordic.v phase_unwrap.v spectral_phase.v distance_fit.v stream_fork_control.v spectral_processor.v frame_ping_pong.v acquisition_core.v} {
    add_files -norecurse [file join $root rtl $name]
}
foreach name {packet_frame_buffer.v s0_export_buffer.v packet_tx.v raw_packet_tx.v raw_stream_packet_tx.v result_packet_tx.v ack_packet_tx.v spectrum_packet_tx.v spectrum_stream_packet_tx.v packet_scheduler.v measurement_packet_tx.v config_packet_rx.v calibration_loader.v calibration_control.v} {
    add_files -norecurse [file join $root rtl $name]
}
foreach name {processor_raw.mem processor_weights.mem processor_exponent.mem processor_config.mem} {
    add_files -fileset sim_1 -norecurse [file join $root build processor_sim $name]
    set_property file_type {Memory Initialization Files} [get_files *$name]
}
add_files -fileset sim_1 -norecurse [file join $root sim tb_processor.sv]
set_property top tb_processor [get_filesets sim_1]
set_property generic "CAPTURE=$capture_mode PACKET=$packet_mode" [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
launch_simulation
close_sim
set logstream [open [file join $root build fft_ip spectral_fft.sim sim_1 behav xsim simulate.log] r]
set logtext [read $logstream]
close $logstream
if {![string match {*PASS: processor protocol*} $logtext]} {error "Processor simulation did not reach success"}
if {$capture_mode && ![string match {*PASS: four continuous 2048-pixel frames*} $logtext]} {error "Continuous capture check did not pass"}
set_property generic {} [get_filesets sim_1]
close_project
