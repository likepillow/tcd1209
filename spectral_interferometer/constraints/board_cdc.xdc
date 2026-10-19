# Only asynchronous entry points of explicit synchronizers are excepted.
# Their downstream stages remain timed. XPM FIFO pointer max-delay/bus-skew
# constraints are intentionally untouched; no asynchronous clock groups.
set_false_path -to [get_pins -hier -regexp {usb_status_meta_reg.*/D|.*clock_guard/toggle_sync_reg\[0\]/D}]
set fifo_reset_entry [get_pins -hier -filter {NAME =~ instrument/transport/*/crossing/read_reset_reg*/PRE}]
set_false_path -to $fifo_reset_entry
# RX byte unpacker has its own two-stage reset-release synchronizer.
set_false_path -to [get_pins -hier -filter {NAME =~ instrument/transport/rx_bridge/rd_reset_reg*/PRE}]
# Async assertion / synchronous release chains, sixteen stages per domain.
set release_entry [get_pins -hier -filter {NAME =~ sys_release_reg*/CLR || NAME =~ usb_release_reg*/CLR}]
set_false_path -to $release_entry
