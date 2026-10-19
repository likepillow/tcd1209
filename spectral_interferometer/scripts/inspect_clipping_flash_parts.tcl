# Read-only tool catalog, no hardware connection or mutation.
open_hw
set parts [get_cfgmem_parts -quiet -filter {NAME == mx25l12845g-spi-x1_x2_x4 && MEM_TYPE == spi}]
puts "EXACT_FLASH_PART_COUNT: [llength $parts]"
foreach part $parts {puts "FLASH_PART: $part";report_property $part}
close_hw
