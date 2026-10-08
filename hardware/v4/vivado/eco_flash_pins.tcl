# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# ECO on a closed routed board design (v4-board-199 / v4-board-189): move
# only the three config-flash ports to the Master SPI pins, clk_ref
# DIFF_TERM FALSE, boot bitstream options. Everything else keeps its
# placement and routing. Real place/route of the moved cells + full STA.
set_param general.maxThreads 1
set in  [lindex $argv 0]
set out [lindex $argv 1]
set tag [lindex $argv 2]
set eco_nets {}
open_checkpoint $in
report_timing_summary -max_paths 5 -file $out/before_timing.rpt
foreach {port pin} {flash_mosi K17 flash_miso K18 flash_cs_n L13} {
    set p [get_ports $port]
    set bufs [get_cells -of_objects [get_nets -of_objects $p] -filter {PRIMITIVE_LEVEL == LEAF}]
    set nets [lsort -unique [get_nets -of_objects [get_pins -of_objects $bufs] -filter {TYPE != POWER && TYPE != GROUND}]]
    puts "ECO $port: old pin [get_property PACKAGE_PIN $p], cells $bufs ([get_property REF_NAME $bufs]) site [get_property LOC $bufs], nets $nets"
    route_design -unroute -nets $nets
    set_property IS_LOC_FIXED false $bufs
    unplace_cell $bufs
    set_property PACKAGE_PIN $pin $p
    set site [get_sites -of_objects [get_package_pins $pin]]
    place_cell $bufs $site
    lappend eco_nets {*}$nets
    puts "ECO $port -> $pin site $site"
}
set_property DIFF_TERM FALSE [get_ports {clk_ref_p clk_ref_n}]
# route only the moved nets: every other net keeps its route
route_design -nets [get_nets $eco_nets]
foreach port {flash_mosi flash_miso flash_cs_n clk_ref_p clk_ref_n} {
    set p [get_ports $port]
    puts "PORT $port pin=[get_property PACKAGE_PIN $p] bank=[get_property IOBANK $p] std=[get_property IOSTANDARD $p] diff_term=[get_property DIFF_TERM $p]"
}
foreach c [get_cells -hier -filter {REF_NAME =~ IBUFDS* || REF_NAME =~ IBUFGDS*}] {
    puts "DIFFBUF $c [get_property REF_NAME $c] DIFF_TERM=[get_property DIFF_TERM $c]"
}
foreach b {0 14 15 16 34 35} {
    set ports [get_ports -quiet -filter "IOBANK == $b"]
    if {[llength $ports]} { puts "BANK $b ports=[llength $ports] stds=[lsort -unique [get_property IOSTANDARD $ports]]" } else { puts "BANK $b ports=0" }
}
report_route_status -file $out/route_status.rpt
report_timing_summary -max_paths 20 -file $out/board_timing.rpt
report_drc -file $out/board_drc.rpt
report_io -file $out/board_io.rpt
report_utilization -file $out/board_util.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "ECO $tag WNS $wns WHS $whs"
write_checkpoint -force $out/v4_board_$tag.dcp
report_power -file $out/power_default.rpt
set_switching_activity -default_toggle_rate 25 -default_static_probability 0.5
report_power -file $out/power_toggle25.rpt
reset_switching_activity -default
puts "CONFIGRATE values: [list_property_value BITSTREAM.CONFIG.CONFIGRATE [current_design]]"
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
if {$wns >= 0 && $whs >= 0} {
    write_bitstream -force $out/v4_board_top_$tag.bit
    write_cfgmem -force -format bin -interface SPIx1 -size 4 -loadbit "up 0x0 $out/v4_board_top_$tag.bit" $out/v4_board_top_${tag}_flash.bin
    puts "BITSIZE [file size $out/v4_board_top_$tag.bit] BINSIZE [file size $out/v4_board_top_${tag}_flash.bin]"
} else { puts "timing not met: no bitstream" }
