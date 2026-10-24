# Offline routed-netlist audit, no hardware connection or checkpoint changes.
if {[llength $argv] != 1} {error "Pass project root"}
set root [lindex $argv 0]
open_checkpoint [file join $root build exposure_deploy instrument_exposure_ready.dcp]
if {[get_property PART [current_design]] ne "xc7a200tfbg484-2"} {error "Wrong part"}
if {[llength [get_ports -quiet user_led*]] != 8} {error "Expected eight user LED outputs"}
foreach index {0 1 2 3 4 5 6 7} expected_pin {M22 N22 L21 K21 K22 J22 H22 M21} {
    set port [get_ports user_led\[$index\]]
    if {[get_property PACKAGE_PIN $port] ne $expected_pin} {error "Wrong LED pin: $port"}
    if {[get_property IOSTANDARD $port] ne "LVCMOS33"} {error "Wrong LED voltage: $port"}
    set pad_net [get_nets -of_objects $port]
    set buffer_cell [get_cells -of_objects [get_pins -of_objects $pad_net -filter {REF_PIN_NAME == O}]]
    if {[llength $buffer_cell] != 1} {error "Missing unique LED output buffer: $port"}
    set input_net [get_nets -of_objects [get_pins -of_objects $buffer_cell -filter {REF_PIN_NAME == I}]]
    set drivers [get_cells -of_objects [get_pins -of_objects $input_net -filter {DIRECTION == OUT}]]
    if {[llength $drivers] != 1 || [get_property REF_NAME $drivers] ne "GND"} {error "LED is not tied low: $port $drivers"}
    puts "LED_OFF_VERIFIED: $port pin=$expected_pin driven_by=GND"
}
puts "EXPOSURE_LED_NETLIST_AUDIT_PASS: no hardware programming performed"
close_design
