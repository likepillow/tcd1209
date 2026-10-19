# FX2 data-sheet bounds with zero board flight delay: feasibility, not PCB signoff.
set_output_delay -clock usb_clock -max 18.7 [get_ports usb_slrd_n]
set_output_delay -clock usb_clock -max 10.4 [get_ports usb_slwr_n]
set_output_delay -clock usb_clock -max 14.6 [get_ports usb_pktend_n]
set_output_delay -clock usb_clock -max 9.2 [get_ports {usb_fd[*]}]
set_output_delay -clock usb_clock -min 0 [get_ports {usb_slrd_n usb_slwr_n usb_pktend_n usb_fd[*]}]
set_input_delay -clock usb_clock -max 11.0 [get_ports {usb_fd[*]}]
set_input_delay -clock usb_clock -max 9.5 [get_ports {usb_flaga usb_flagb usb_flagc}]
set_input_delay -clock usb_clock -min 0 [get_ports {usb_fd[*] usb_flaga usb_flagb usb_flagc}]
