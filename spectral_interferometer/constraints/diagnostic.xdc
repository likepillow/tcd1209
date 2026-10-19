# ACX720-V3: 50 MHz oscillator and active-low S4 user reset.
# Schematic p2: CFGBVS U8 tied to VCC3V3; p3: VCCO_0 E12/T12 to VCC3V3.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
# Unused active-low FX2 strobes must not be weakly pulled low by FPGA defaults.
# No USB transfer is driven by this diagnostic; unused IO remains inputs.
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup [current_design]
set_property PACKAGE_PIN Y18 [get_ports clk_50mhz]
set_property PACKAGE_PIN B21 [get_ports reset_button_n]
set_property IOSTANDARD LVCMOS33 [get_ports {clk_50mhz reset_button_n}]
create_clock -name board_clk -period 20.000 [get_ports clk_50mhz]
# P3 -> P7(GPIO0) same-number cable; Bank16 VCCO=3.3 V confirmed by user.
set_property PACKAGE_PIN C13 [get_ports ccd_phi2]
set_property PACKAGE_PIN D14 [get_ports ccd_rs]
set_property PACKAGE_PIN D15 [get_ports ccd_phi1]
set_property PACKAGE_PIN C14 [get_ports ccd_sh]
set_property PACKAGE_PIN C15 [get_ports ccd_cp]
set_property PACKAGE_PIN B15 [get_ports ad_shp]
set_property PACKAGE_PIN B16 [get_ports ad_shd]
set_property PACKAGE_PIN D17 [get_ports ad_pblk]
set_property PACKAGE_PIN C17 [get_ports ad_clpob]
set_property PACKAGE_PIN E16 [get_ports {ad_data[11]}]
set_property PACKAGE_PIN D16 [get_ports ad_dataclk]
set_property PACKAGE_PIN B17 [get_ports {ad_data[9]}]
set_property PACKAGE_PIN B18 [get_ports {ad_data[10]}]
set_property PACKAGE_PIN C18 [get_ports {ad_data[7]}]
set_property PACKAGE_PIN C19 [get_ports {ad_data[8]}]
set_property PACKAGE_PIN F16 [get_ports {ad_data[5]}]
set_property PACKAGE_PIN E17 [get_ports {ad_data[6]}]
set_property PACKAGE_PIN D20 [get_ports {ad_data[3]}]
set_property PACKAGE_PIN C20 [get_ports {ad_data[4]}]
set_property PACKAGE_PIN E19 [get_ports {ad_data[1]}]
set_property PACKAGE_PIN D19 [get_ports {ad_data[2]}]
set_property PACKAGE_PIN F18 [get_ports ad_sck]
set_property PACKAGE_PIN E18 [get_ports {ad_data[0]}]
set_property PACKAGE_PIN F19 [get_ports ad_sl]
set_property PACKAGE_PIN F20 [get_ports ad_sdata]
set_property IOSTANDARD LVCMOS33 [get_ports {ccd_* ad_*}]
set_property SLEW SLOW [get_ports {ccd_* ad_shp ad_shd ad_pblk ad_clpob ad_dataclk ad_sck ad_sl ad_sdata}]
set_property DRIVE 8 [get_ports {ccd_* ad_shp ad_shd ad_pblk ad_clpob ad_dataclk ad_sck ad_sl ad_sdata}]
# Intentionally no fabricated ADC input delay, output delay, or broad false
# paths. This diagnostic needs external waveform/delay measurements before
# production IO timing can be signed off. No USB pins are instantiated.
