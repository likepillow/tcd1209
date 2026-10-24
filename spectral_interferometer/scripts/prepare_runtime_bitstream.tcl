if {[llength $argv] < 1 || [llength $argv] > 2} {error "Pass project root and optional variant"}
set root [lindex $argv 0]
if {[file pathtype $root] ne "absolute"} {error "Absolute root required"}
set variant [expr {[llength $argv] == 2 ? [lindex $argv 1] : "runtime"}]
if {$variant ni {runtime control clipping capture40 exposure}} {error "Unsupported variant"}
switch $variant {
    control {set marker 0x26092402}
    clipping {set marker 0x26100301}
    capture40 {set marker 0x26100440}
    exposure {set marker 0x26102402}
    runtime {set marker 0x26092401}
}
set output [file join $root build ${variant}_deploy]
set checkpoint [file join $root build ${variant}_implementation refined.dcp]
set bitfile [file join $output instrument_${variant}.bit]
file mkdir $output
if {![file exists $checkpoint]} {error "Missing refined runtime checkpoint"}

open_checkpoint $checkpoint
if {[get_property PART [current_design]] ne "xc7a200tfbg484-2"} {error "Wrong FPGA part"}
set period [get_property PERIOD [get_clocks usb_clock]]
if {abs($period-33.333) > 0.002} {error "Checkpoint is not the 30 MHz USB build: period=$period"}
if {[llength [get_cells -quiet -hier -filter {REF_NAME == diagnostic_vio}]]} {error "Runtime design must not depend on VIO"}
if {[llength [get_cells -quiet -hier -filter {NAME =~ *clock_guard/qualified_reg}]] != 1} {error "Missing autonomous clock guard"}
foreach delay_type {max min} {
    set worst [get_timing_paths -delay_type $delay_type -max_paths 1]
    if {![llength $worst] || [get_property SLACK $worst] < 0} {error "Internal $delay_type timing gate failed"}
}
foreach port [get_ports] {
    if {[get_property PACKAGE_PIN $port] eq ""} {error "Unassigned pin: $port"}
    if {[get_property IOSTANDARD $port] ne "LVCMOS33"} {error "Wrong IO voltage: $port"}
}

# Restore FX2LP data-sheet timing for a deployment feasibility gate.
set_output_delay -clock usb_clock -max 18.7 [get_ports usb_slrd_n]
set_output_delay -clock usb_clock -max 10.4 [get_ports usb_slwr_n]
set_output_delay -clock usb_clock -max 14.6 [get_ports usb_pktend_n]
set_output_delay -clock usb_clock -max 9.2 [get_ports {usb_fd[*]}]
set_output_delay -clock usb_clock -min 0 [get_ports {usb_slrd_n usb_slwr_n usb_pktend_n usb_fd[*]}]
set_input_delay -clock usb_clock -max 11.0 [get_ports {usb_fd[*]}]
set_input_delay -clock usb_clock -max 9.5 [get_ports {usb_flaga usb_flagb usb_flagc}]
set_input_delay -clock usb_clock -min 0 [get_ports {usb_fd[*] usb_flaga usb_flagb usb_flagc}]
set active_regs [get_cells -hier -filter {NAME =~ instrument/transport/controller/* && IS_SEQUENTIAL == 1}]
if {![llength $active_regs]} {error "Controller registers not found"}
set checks [list \
    [list active_output_setup [get_timing_paths -from $active_regs -to [get_ports {usb_slrd_n usb_slwr_n usb_pktend_n usb_fd[*]}] -delay_type max -max_paths 1] 5.0] \
    [list active_output_hold [get_timing_paths -from $active_regs -to [get_ports {usb_slrd_n usb_slwr_n usb_pktend_n usb_fd[*]}] -delay_type min -max_paths 1] 0.2] \
    [list input_setup [get_timing_paths -from [get_ports {usb_fd[*] usb_flaga usb_flagb usb_flagc}] -delay_type max -max_paths 1] 5.0] \
    [list input_hold [get_timing_paths -from [get_ports {usb_fd[*] usb_flaga usb_flagb usb_flagc}] -delay_type min -max_paths 1] 0.2]]
foreach check $checks {
    lassign $check label path minimum
    if {![llength $path]} {error "No timing path for $label"}
    set slack [get_property SLACK $path]
    puts "RUNTIME_GATE: $label slack=$slack ns minimum=$minimum ns"
    if {$slack < $minimum} {error "$label margin is below deployment gate"}
}

report_drc -file [file join $output prebit_drc.rpt]
set severe [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == "Critical Warning"}]
if {[llength $severe]} {error "Blocking DRC violations: $severe"}
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CONFIG_MODE SPIx1 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 16 [current_design]
set_property BITSTREAM.STARTUP.STARTUPCLK CCLK [current_design]
set_property BITSTREAM.CONFIG.USR_ACCESS $marker [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
report_timing_summary -report_unconstrained -file [file join $output prebit_timing.rpt]
report_utilization -file [file join $output prebit_utilization.rpt]
report_bus_skew -warn_on_violation -file [file join $output prebit_bus_skew.rpt]
write_checkpoint -force [file join $output instrument_${variant}_ready.dcp]
write_bitstream -force $bitfile
write_cfgmem -force -format mcs -size 16 -interface SPIx1 -loadbit "up 0x0 $bitfile" -file [file join $output instrument_${variant}.mcs]
write_cfgmem -force -format bin -size 16 -interface SPIx1 -loadbit "up 0x0 $bitfile" -file [file join $output instrument_${variant}.bin]
puts "[string toupper $variant]_BITSTREAM_GENERATED: no hardware programming performed"
