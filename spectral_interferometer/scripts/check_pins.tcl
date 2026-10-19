# Read-only device-database validation. Does not create a bitstream or apply IO constraints.
if {[llength $argv] != 1} {error "Pass absolute spectral_interferometer directory"}
set root [lindex $argv 0]
create_project -in_memory -part xc7a200tfbg484-2
read_verilog [file join $root rtl ad9945_init.v]
synth_design -top ad9945_init -part xc7a200tfbg484-2 -mode out_of_context
set stream [open [file join $root constraints p3_gpio0.csv] r]
gets $stream header
set used_pins {}
set used_ports {}
set count 0
while {[gets $stream line] >= 0} {
    if {$line eq ""} {continue}
    lassign [split $line ,] p3 net port direction p7 gpio pin
    if {$p3 != $p7} {error "This manifest must describe equal-number straight wiring"}
    if {[lsearch -exact $used_pins $pin] >= 0 || [lsearch -exact $used_ports $port] >= 0} {error "Duplicate port/pin"}
    lappend used_pins $pin
    lappend used_ports $port
    set obj [get_package_pins -quiet $pin]
    if {[llength $obj] != 1} {error "Invalid package pin $pin"}
    set bank [get_property BANK $obj]
    set function [get_property PIN_FUNC $obj]
    if {$bank != 16 || ![string match {IO_*} $function]} {error "$pin is not Bank 16 user IO"}
    puts "PIN_CHECK: P3/$p3 $net -> $gpio -> $pin, Bank $bank, $function"
    incr count
}
close $stream
if {$count != 25} {error "Expected 25 signal connections, found $count"}
puts "PIN_CHECK_PASS: 25 unique Bank 16 user IO pins on xc7a200tfbg484-2"
close_project
