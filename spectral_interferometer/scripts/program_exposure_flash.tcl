# User explicitly authorized backup + update. Refuse an unexpected live baseline.
if {[llength $argv] != 1} {error "Pass absolute project root"}
set root [lindex $argv 0]
if {[file pathtype $root] ne "absolute"} {error "Absolute root required"}
set audit [file join $root build exposure_flash_audit]
set old [file join $root build clipping_flash_audit programmed_flash.bin]
set before [file join $audit flash_before_program.bin]
set after [file join $audit programmed_flash.bin]
set mcs [file join $root build exposure_deploy instrument_exposure.mcs]
set gate [file join $audit preflight.json]
if {![file exists $gate]} {error "Missing preflight"}
set f [open $gate r];set gate_text [read $f];close $f
if {[string first {"status": "PASS"} $gate_text] < 0 || [string first {"version": "26102402"} $gate_text] < 0} {error "Preflight failed"}
if {![file exists $old] || [file size $old] != 16777216 || ![file exists $mcs]} {error "Missing baseline/image"}
if {[file exists $before] || [file exists $after]} {error "Prior attempt exists; never overwrite backups"}
open_hw
connect_hw_server -url localhost:3121
set targets [get_hw_targets -quiet]
if {[llength $targets] != 1} {error "Expected one JTAG target"}
current_hw_target [lindex $targets 0];open_hw_target
set devices [get_hw_devices -quiet]
if {[llength $devices] != 1} {error "Expected one FPGA"}
set dev [lindex $devices 0];current_hw_device $dev
if {[get_property PART $dev] ne "xc7a200t"} {error "Wrong FPGA"}
refresh_hw_device $dev
if {[get_property REGISTER.USR_ACCESS $dev] ne "26102402"} {error "Expected tested candidate"}
foreach {prop expected} {
    {REGISTER.CONFIG_STATUS.BIT08_MODE_PIN_M[0]} 1
    {REGISTER.CONFIG_STATUS.BIT09_MODE_PIN_M[1]} 0
    {REGISTER.CONFIG_STATUS.BIT10_MODE_PIN_M[2]} 0
} {if {[get_property $prop $dev] ne $expected} {error "Not Master SPI boot"}}
set parts [get_cfgmem_parts {mx25l12845g-spi-x1_x2_x4}]
if {![llength $parts]} {error "Expected verified Flash part"}
set flash_part [lindex $parts 0]
foreach {prop expected} {NAME mx25l12845g-spi-x1_x2_x4 MEM_DEVICE mx25l12845g MEM_DENSITY 128 MEM_TYPE spi} {
    if {[get_property $prop $flash_part] ne $expected} {error "Wrong Flash property: $prop"}
}
if {[lsearch -exact [get_property COMPATIBLE_PARTS $flash_part] xc7a200t] < 0} {error "Incompatible Flash part"}
create_hw_cfgmem -hw_device $dev $flash_part
set mem [get_property PROGRAM.HW_CFGMEM $dev]
foreach p {ERASE CFG_PROGRAM VERIFY BLANK_CHECK} {set_property PROGRAM.$p 0 $mem}
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev;refresh_hw_device $dev
readback_hw_cfgmem -all -format bin -file $before $mem
proc bytes {path} {set f [open $path rb];set data [read $f];close $f;return $data}
if {[file size $before] != 16777216 || [bytes $before] ne [bytes $old]} {error "Live Flash differs; refusing erase; backup retained"}
puts "EXPOSURE_FLASH_BACKUP_VERIFIED: 16 MiB matches verified 26100301 baseline"
set_property PROGRAM.FILES [list $mcs] $mem
set_property PROGRAM.ADDRESS_RANGE use_file $mem
set_property PROGRAM.UNUSED_PIN_TERMINATION pull-up $mem
set_property PROGRAM.ERASE 1 $mem
set_property PROGRAM.CFG_PROGRAM 1 $mem
set_property PROGRAM.VERIFY 1 $mem
set_property PROGRAM.BLANK_CHECK 0 $mem
program_hw_cfgmem $mem
readback_hw_cfgmem -all -format bin -file $after $mem
puts "EXPOSURE_FLASH_PROGRAM_AND_READBACK_PASS"
close_hw_target;disconnect_hw_server;close_hw
