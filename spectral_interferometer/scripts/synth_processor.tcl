if {[llength $argv] < 1 || [llength $argv] > 2} {error "Pass absolute directory and optional capture mode with -tclargs"}
set root [lindex $argv 0]
set design_top spectral_processor
set output_name processor_synth
set usb_mhz 48
set autonomous 0
set capture_cycles 2
if {[llength $argv] == 2} {
    switch [lindex $argv 1] {
        capture {set design_top acquisition_core;set output_name acquisition_synth}
        instrument {set design_top instrument_frontend_usb;set output_name instrument_synth}
        board {set design_top instrument_board_top;set output_name board_synth}
        board30 {set design_top instrument_board_top;set output_name board30_synth;set usb_mhz 30}
        standalone {set design_top instrument_board_top;set output_name standalone_synth;set usb_mhz 30;set autonomous 1}
        runtime {set design_top instrument_board_top;set output_name runtime_synth;set usb_mhz 30;set autonomous 1}
        control {set design_top instrument_board_top;set output_name control_synth;set usb_mhz 30;set autonomous 1}
        clipping {set design_top instrument_board_top;set output_name clipping_synth;set usb_mhz 30;set autonomous 1}
        capture40 {set design_top instrument_board_top;set output_name capture40_synth;set usb_mhz 30;set autonomous 1;set capture_cycles 4}
        default {error "Second argument must be capture or instrument"}
    }
}
set output [file join $root build $output_name]
file mkdir $output
open_project [file join $root build fft_ip spectral_fft.xpr]
foreach name {normalize_frame.v spectral_transform.v positive_peak_filter.v analytic_spectrum.v phase_cordic.v phase_unwrap.v spectral_phase.v distance_fit.v stream_fork_control.v spectral_processor.v frame_ping_pong.v acquisition_core.v} {
    add_files -norecurse [file join $root rtl $name]
}
set_property top $design_top [get_filesets sources_1]
if {$design_top in {instrument_frontend_usb instrument_board_top}} {
    foreach name {instrument_frontend_usb instrument_core ccd_frontend ccd_afe_timing adc_pixel_align ad9945_init fx2_transport fx2_slave_fifo usb_stream_bridge usb_word_stream usb_async_fifo config_packet_rx calibration_loader calibration_control packet_tx ack_packet_tx result_packet_tx raw_packet_tx raw_stream_packet_tx spectrum_packet_tx spectrum_stream_packet_tx packet_scheduler measurement_packet_tx packet_frame_buffer s0_export_buffer s0_measurement_packet_tx} {
        set path [file join $root rtl ${name}.v]
        add_files -norecurse $path
        set_property file_type SystemVerilog [get_files $path]
    }
    set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]
}
set ipnames {fft1024 ifft1024}
if {$design_top eq "instrument_board_top"} {
    foreach name {instrument_board_top board_clock_reset usb_clock_qualifier} {
        set path [file join $root rtl ${name}.v]
        add_files -norecurse $path
        set_property file_type SystemVerilog [get_files $path]
    }
    if {[llength [get_ips -quiet diagnostic_vio]] == 0} {
        create_ip -name vio -vendor xilinx.com -library ip -version 3.0 -module_name diagnostic_vio
        set_property -dict [list CONFIG.C_NUM_PROBE_IN {1} CONFIG.C_PROBE_IN0_WIDTH {16} \
            CONFIG.C_NUM_PROBE_OUT {2} CONFIG.C_PROBE_OUT0_WIDTH {1} CONFIG.C_PROBE_OUT1_WIDTH {1} \
            CONFIG.C_PROBE_OUT0_INIT_VAL {0x0} CONFIG.C_PROBE_OUT1_INIT_VAL {0x1}] [get_ips diagnostic_vio]
        generate_target all [get_ips diagnostic_vio]
    }
    if {!$autonomous} {lappend ipnames diagnostic_vio}
}
set pending_runs {}
foreach ipname $ipnames {
    set runname ${ipname}_synth_1
    if {[llength [get_runs -quiet $runname]] == 0} {create_ip_run [get_ips $ipname]}
    if {![string match {*Complete*} [get_property STATUS [get_runs $runname]]]} {
        lappend pending_runs $runname
    }
}
if {[llength $pending_runs]} {
    launch_runs $pending_runs -jobs 2
    foreach runname $pending_runs {wait_on_run $runname}
}
foreach ipname $ipnames {
    set runname ${ipname}_synth_1
    if {![string match {*Complete*} [get_property STATUS [get_runs $runname]]]} {error "IP synthesis failed: $runname"}
}
if {$design_top eq "instrument_board_top"} {
    synth_design -top $design_top -part xc7a200tfbg484-2 -generic [list USB_IFCLK_MHZ=$usb_mhz AUTO_START=$autonomous ADC_CAPTURE_DELAY=$capture_cycles]
} else {
    synth_design -mode out_of_context -top $design_top -part xc7a200tfbg484-2
}
# Depending on project checkpoint settings, IP DCPs may already be linked.
# Explicitly fill any remaining FFT black boxes before reporting resources.
foreach ipname $ipnames {
    set cells [get_cells -hier -filter "REF_NAME == $ipname && IS_BLACKBOX == 1"]
    foreach cell $cells {
        read_checkpoint -cell $cell [file join [get_property DIRECTORY [get_runs ${ipname}_synth_1]] ${ipname}.dcp]
    }
}
set unresolved [get_cells -hier -filter {IS_BLACKBOX == 1}]
if {$design_top eq "instrument_board_top"} {
    # Vivado inserts this debug-hub placeholder for VIO during synthesis.
    # Implementation must resolve it; do not whitelist algorithm/transport IP.
    set unresolved [get_cells -quiet -hier -filter {IS_BLACKBOX == 1 && REF_NAME != dbg_hub_CV}]
}
if {[llength $unresolved]} {
    foreach cell $unresolved {puts "UNRESOLVED: $cell REF_NAME=[get_property REF_NAME $cell]"}
    write_checkpoint -force [file join $output unresolved.dcp]
    error "Unresolved black boxes in processor: $unresolved"
}
if {$design_top eq "instrument_board_top"} {
    read_xdc [file join $root constraints diagnostic.xdc]
    read_xdc [file join $root constraints fx2_pins.xdc]
    create_clock -name usb_clock -period [expr {1000.0/$usb_mhz}] [get_ports usb_ifclk]
    report_io -file [file join $output io.rpt]
} else {
    create_clock -period 10.0 [get_ports clk]
}
if {$design_top eq "instrument_frontend_usb"} {
    create_clock -period 20.833 [get_ports ifclk]
    # OOC connectivity/resource check only. Board I/O delays and CDC constraints
    # are intentionally not claimed complete by this synthesis report.
}
report_utilization -hierarchical -file [file join $output utilization_hier.rpt]
report_utilization -file [file join $output utilization.rpt]
report_timing_summary -file [file join $output timing_synth.rpt]
write_checkpoint -force [file join $output processor.dcp]
puts "PROCESSOR_SYNTH_PASS: $design_top with linked FFT/IFFT checkpoints"
close_project
