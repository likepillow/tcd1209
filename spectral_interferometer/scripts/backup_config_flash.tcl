# Installs only the volatile Xilinx SPI access helper; never erases/programs Flash.
if {[llength $argv] != 1} {error "Pass absolute project root"}
set root [lindex $argv 0]
set backup [file join $root build flash_audit original_flash.bin]
if {[file exists $backup]} {error "Backup exists; refusing overwrite"}
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
foreach {property expected} {
    {REGISTER.CONFIG_STATUS.BIT08_MODE_PIN_M[0]} 1
    {REGISTER.CONFIG_STATUS.BIT09_MODE_PIN_M[1]} 0
    {REGISTER.CONFIG_STATUS.BIT10_MODE_PIN_M[2]} 0
} {
    if {[get_property $property $dev] ne $expected} {error "Not Master SPI boot"}
}
set part [lindex [get_cfgmem_parts {mx25l12845g-spi-x1_x2_x4}] 0]
create_hw_cfgmem -hw_device $dev $part
set mem [get_property PROGRAM.HW_CFGMEM $dev]
foreach property {ERASE CFG_PROGRAM VERIFY BLANK_CHECK} {set_property PROGRAM.$property 0 $mem}
set_property PROGRAM.CHECKSUM 0 $mem
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev
report_property $mem
readback_hw_cfgmem -all -format bin -file $backup $mem
report_property $mem
if {[file size $backup] != 16777216} {error "Unexpected backup size"}
puts "FLASH_BACKUP_PASS: $backup; no nonvolatile writes performed"
close_hw_target
disconnect_hw_server
close_hw
