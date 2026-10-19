# Analysis only: no bitstream and no change to source electrical constraints.
source [file join [lindex $argv 0] scripts check_fx2_external.tcl]
foreach drive {8 12 16} {
    set_property DRIVE $drive [get_ports usb_slrd_n]
    set setup [get_timing_paths -to [get_ports usb_slrd_n] -delay_type max -max_paths 1]
    set hold [get_timing_paths -to [get_ports usb_slrd_n] -delay_type min -max_paths 1]
    puts "SLRD_DRIVE_SWEEP mA=$drive setup=[get_property SLACK $setup] hold=[get_property SLACK $hold]"
}
puts "DRIVE_SWEEP_COMPLETE: zero PCB/load assumptions; no deployable output"
