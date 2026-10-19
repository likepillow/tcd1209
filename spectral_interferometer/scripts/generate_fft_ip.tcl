# Reproducible 2018.3 XFFT 9.1 configuration. No modification of the old .xpr.
if {[llength $argv] != 1} {error "Pass absolute spectral_interferometer directory with -tclargs"}
set root [lindex $argv 0]
if {[file pathtype $root] ne "absolute"} {error "Root must be absolute"}
set output [file join $root build fft_ip]
file mkdir $output
create_project spectral_fft $output -part xc7a200tfbg484-2 -force
foreach name {fft1024 ifft1024} {
    create_ip -name xfft -vendor xilinx.com -library ip -version 9.1 -module_name $name
    set scaling [expr {$name eq "fft1024" ? "scaled" : "unscaled"}]
    set_property -dict [list \
        CONFIG.transform_length {1024} \
        CONFIG.implementation_options {pipelined_streaming_io} \
        CONFIG.input_width {32} \
        CONFIG.phase_factor_width {24} \
        CONFIG.scaling_options $scaling \
        CONFIG.rounding_modes {convergent_rounding} \
        CONFIG.output_ordering {natural_order} \
        CONFIG.throttle_scheme {nonrealtime} \
        CONFIG.aresetn {true} \
        CONFIG.xk_index {true} \
        CONFIG.target_clock_frequency {100}] [get_ips $name]
    if {$name eq "fft1024"} {set_property CONFIG.ovflo true [get_ips $name]}
    generate_target all [get_ips $name]
}
puts "FFT_IP_GENERATION_PASS"
close_project
