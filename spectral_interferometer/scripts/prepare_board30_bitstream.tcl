# Generate a volatile-JTAG test image from the routed 30 MHz candidate.
# This never opens Hardware Manager and never writes FPGA configuration Flash.
if {[llength $argv] < 1 || [llength $argv] > 3} {error "Pass root, optional output directory, optional standalone"}
set root [lindex $argv 0]
if {[file pathtype $root] ne "absolute"} {error "Absolute root required"}
set impl [file join $root build board30_implementation]
set checkpoint [file join $impl routed.dcp]
set output [file join $root build board30_deploy]
if {[llength $argv] >= 2} {set output [lindex $argv 1]}
set standalone 0
if {[llength $argv] == 3} {
    if {[lindex $argv 2] ne "standalone"} {error "Unknown mode"}
    set standalone 1
    set checkpoint [file join $root build standalone_implementation refined.dcp]
}
file mkdir $output
set bitfile [file join $output instrument_board30_test.bit]
if {$standalone} {set bitfile [file join $output instrument_standalone.bit]}
if {![file exists $checkpoint]} {error "Missing routed 30 MHz checkpoint"}
if {[file exists $bitfile]} {error "Test bitstream already exists; refusing implicit overwrite"}

open_checkpoint $checkpoint
if {[get_property PART [current_design]] ne "xc7a200tfbg484-2"} {error "Wrong FPGA part"}
set period [get_property PERIOD [get_clocks usb_clock]]
if {abs($period-33.333) > 0.002} {error "Checkpoint is not the 30 MHz USB build: period=$period"}
if {!$standalone && [llength [get_cells -quiet -hier -filter {REF_NAME == diagnostic_vio}]] != 1} {error "Missing safety VIO"}
if {$standalone} {
    if {[llength [get_cells -quiet -hier -filter {REF_NAME == diagnostic_vio}]]} {error "Standalone design must not depend on VIO"}
    if {[llength [get_cells -quiet -hier -filter {NAME =~ *clock_guard/qualified_reg}]] != 1} {error "Missing autonomous clock guard"}
    set_property CONFIG_MODE SPIx1 [current_design]
    set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
    set_property BITSTREAM.CONFIG.CONFIGRATE 16 [current_design]
    set_property BITSTREAM.STARTUP.STARTUPCLK CCLK [current_design]
    set_property BITSTREAM.CONFIG.USR_ACCESS 0x26092304 [current_design]
}
foreach delay_type {max min} {
    set worst [get_timing_paths -delay_type $delay_type -max_paths 1]
    if {![llength $worst] || [get_property SLACK $worst] < 0} {
        error "Internal $delay_type timing gate failed"
    }
}
foreach port [get_ports] {
    if {[get_property PACKAGE_PIN $port] eq ""} {error "Unassigned pin: $port"}
    if {[get_property IOSTANDARD $port] ne "LVCMOS33"} {error "Wrong IO voltage: $port"}
}

# Reapply the FX2LP data-sheet limits solely as a pre-bitstream feasibility gate.
# Board flight time/load are not included; the deliberately reduced IFCLK leaves
# more than 11 ns of active-output setup slack in the routed candidate.
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
set out_setup [get_timing_paths -from $active_regs -to [get_ports {usb_slrd_n usb_slwr_n usb_pktend_n usb_fd[*]}] -delay_type max -max_paths 1]
set out_hold [get_timing_paths -from $active_regs -to [get_ports {usb_slrd_n usb_slwr_n usb_pktend_n usb_fd[*]}] -delay_type min -max_paths 1]
set in_setup [get_timing_paths -from [get_ports {usb_fd[*] usb_flaga usb_flagb usb_flagc}] -delay_type max -max_paths 1]
set in_hold [get_timing_paths -from [get_ports {usb_fd[*] usb_flaga usb_flagb usb_flagc}] -delay_type min -max_paths 1]
foreach pair [list [list active_output_setup $out_setup 5.0] [list active_output_hold $out_hold 0.2] [list input_setup $in_setup 5.0] [list input_hold $in_hold 0.2]] {
    lassign $pair label path minimum
    if {![llength $path]} {error "No timing path for $label"}
    set slack [get_property SLACK $path]
    puts "BOARD30_GATE: $label slack=$slack ns minimum=$minimum ns"
    if {$slack < $minimum} {error "$label margin is below deployment gate"}
}

report_drc -file [file join $output prebit_drc.rpt]
set severe [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == "Critical Warning"}]
if {[llength $severe]} {error "Blocking DRC violations: $severe"}
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
report_timing_summary -report_unconstrained -file [file join $output prebit_timing.rpt]
report_bus_skew -warn_on_violation -file [file join $output prebit_bus_skew.rpt]
write_checkpoint [file join $output instrument_board30_ready.dcp]
if {!$standalone} {write_debug_probes -force [file join $output instrument_board30_test.ltx]}
write_bitstream $bitfile
if {$standalone} {
    write_cfgmem -format mcs -size 16 -interface SPIx1 -loadbit "up 0x0 $bitfile" -file [file join $output instrument_standalone.mcs]
    # MCS and BIN share a generated .prm name; only that fresh metadata is replaced.
    write_cfgmem -force -format bin -size 16 -interface SPIx1 -loadbit "up 0x0 $bitfile" -file [file join $output instrument_standalone.bin]
}
puts "BOARD30_BITSTREAM_GENERATED: volatile JTAG test image only; no programming performed"
