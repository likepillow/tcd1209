set root [lindex $argv 0]
set output [file join $root build standalone_deploy]
set bitfile [file join $output instrument_standalone.bit]
if {[file exists [file join $output instrument_standalone.bin]]} {error "BIN exists"}
write_cfgmem -force -format bin -size 16 -interface SPIx1 -loadbit "up 0x0 $bitfile" -file [file join $output instrument_standalone.bin]
