# Program the hardware-qualified RUN-control image while preserving the verified
# runtime full-chip readback. Refuse to erase unless the live Flash still matches.
if {[llength $argv] != 1} {error "Pass project root"}
set root [lindex $argv 0]
set old [file join $root build runtime_flash_audit programmed_flash.bin]
set gate [file join $root build control_hardware control_run_acceptance_pass.json]
set audit [file join $root build control_flash_audit]
set before [file join $audit flash_before_program.bin]
set after [file join $audit programmed_flash.bin]
set mcs [file join $root build control_deploy instrument_control.mcs]
if {![file exists $gate]} {error "Missing control hardware acceptance gate"}
set gf [open $gate r]; set gate_text [read $gf]; close $gf
if {[string first {"result": "PASS"} $gate_text] < 0} {error "Control hardware gate is not PASS"}
if {![file exists $old] || [file size $old] != 16777216} {error "Missing verified runtime full readback"}
if {![file exists $mcs]} {error "Missing control MCS"}
file mkdir $audit
if {[file exists $before] || [file exists $after]} {error "Prior control program attempt exists; inspect before retry"}

open_hw
connect_hw_server -url localhost:3121
set targets [get_hw_targets -quiet]
if {[llength $targets] != 1} {error "Expected one JTAG target"}
current_hw_target [lindex $targets 0]
open_hw_target
set devices [get_hw_devices -quiet]
if {[llength $devices] != 1} {error "Expected one FPGA"}
set dev [lindex $devices 0]
current_hw_device $dev
if {[get_property PART $dev] ne "xc7a200t"} {error "Wrong FPGA"}
refresh_hw_device $dev
foreach {prop expected} {
    {REGISTER.CONFIG_STATUS.BIT08_MODE_PIN_M[0]} 1
    {REGISTER.CONFIG_STATUS.BIT09_MODE_PIN_M[1]} 0
    {REGISTER.CONFIG_STATUS.BIT10_MODE_PIN_M[2]} 0
} {if {[get_property $prop $dev] ne $expected} {error "Not Master SPI boot"}}
create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts {mx25l12845g-spi-x1_x2_x4}] 0]
set mem [get_property PROGRAM.HW_CFGMEM $dev]
foreach p {ERASE CFG_PROGRAM VERIFY BLANK_CHECK} {set_property PROGRAM.$p 0 $mem}
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev
readback_hw_cfgmem -all -format bin -file $before $mem
proc bytes {path} {set f [open $path rb]; set result [read $f]; close $f; return $result}
if {[bytes $before] ne [bytes $old]} {error "Flash differs from verified runtime image; refusing erase"}
set_property PROGRAM.FILES [list $mcs] $mem
set_property PROGRAM.ADDRESS_RANGE use_file $mem
set_property PROGRAM.UNUSED_PIN_TERMINATION pull-up $mem
set_property PROGRAM.ERASE 1 $mem
set_property PROGRAM.CFG_PROGRAM 1 $mem
set_property PROGRAM.VERIFY 1 $mem
set_property PROGRAM.BLANK_CHECK 0 $mem
program_hw_cfgmem $mem
readback_hw_cfgmem -all -format bin -file $after $mem
puts "CONTROL_FLASH_PROGRAM_AND_READBACK_PASS"
close_hw_target
disconnect_hw_server
close_hw
