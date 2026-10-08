# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# ECO on a closed routed board design (v4-board-199-flashcfg / -189-):
# single 200 MHz LVDS oscillator on N5/P5 instead of 310.078 MHz (sys_clk)
# + 200 MHz (clk_ref, T14/T15). Netlist edits only around the clock inputs
# (same function as rtl/v4_board_top.v on branch v4-sysclk-200):
#   N5/P5 IBUFDS (the MIG's former sys_clk buffer) -> the MIG's clk_ref BUFG
#     -> IDELAYCTRL REFCLK (200 MHz) and -> new MMCM x31/5/4 -> new BUFG
#     -> MIG PLL CLKIN1 (310.0 MHz, was the IBUFDS output)
#   clk_ref IBUFDS and ports clk_ref_p/n removed
#   MIG sys_rst = sys_rst AND MMCM LOCKED; MMCM RST = NOT sys_rst
# Every existing cell keeps its placement and every untouched net its route.
#   vivado -mode batch -source eco_osc200.tcl -tclargs <in.dcp> <out_dir> <tag>
set_param general.maxThreads 1
set in  [lindex $argv 0]
set out [lindex $argv 1]
set tag [lindex $argv 2]
file mkdir $out
open_checkpoint $in
set M  u_mig/u_mig_7series_0_mig
set ibuf_sys $M/u_ddr3_clk_ibuf/diff_input_clk.u_ibufg_sys_clk
set ibuf_ref $M/u_iodelay_ctrl/diff_clk_ref.u_ibufg_clk_ref
set bufg_ref $M/u_iodelay_ctrl/clk_ref_200.u_bufg_clk_ref
set pll      $M/u_ddr3_infrastructure/plle2_i

# placement snapshot to prove nothing else moves
set snap [dict create]
foreach c [get_cells -hier -filter {IS_PRIMITIVE && STATUS == PLACED}] { dict set snap $c [get_property LOC $c] }

set n_osc [get_nets -of [get_pins $ibuf_sys/O]]
set n_refbuf_in [get_nets -of [get_pins $bufg_ref/I]]
set n_ref200 [get_nets -of [get_pins $bufg_ref/O]]
puts "ECO nets: osc=$n_osc ref_in=$n_refbuf_in ref200=$n_ref200"

route_design -unroute -nets [list $n_osc $n_refbuf_in]
disconnect_net -objects [get_pins $pll/CLKIN1]
disconnect_net -objects [get_pins $bufg_ref/I]
connect_net -hier -net $n_osc -objects [get_pins $bufg_ref/I]

# remove the clk_ref input buffer and ports
foreach p [get_pins -of [get_cells $ibuf_ref]] { catch {disconnect_net -objects $p} }
remove_cell [get_cells $ibuf_ref]
foreach p {clk_ref_p clk_ref_n} {
    catch {disconnect_net -objects [get_ports $p]}
    remove_port [get_ports $p]
}

# new MMCM 200 -> 310 MHz and its BUFG
create_cell -reference MMCME2_ADV u_mmcm_mig
set_property -dict {CLKIN1_PERIOD 5.000 CLKFBOUT_MULT_F 31.000 DIVCLK_DIVIDE 5 CLKOUT0_DIVIDE_F 4.000 BANDWIDTH OPTIMIZED COMPENSATION INTERNAL STARTUP_WAIT FALSE} [get_cells u_mmcm_mig]
create_cell -reference BUFG u_bufg_mig
create_net osc_mmcm_fb
create_net mig_sys_clk_unbuf
create_net mig_sys_clk
create_net osc_locked
connect_net -hier -net $n_ref200 -objects [get_pins u_mmcm_mig/CLKIN1]
connect_net -net osc_mmcm_fb -objects [get_pins {u_mmcm_mig/CLKFBOUT u_mmcm_mig/CLKFBIN}]
connect_net -net mig_sys_clk_unbuf -objects [get_pins {u_mmcm_mig/CLKOUT0 u_bufg_mig/I}]
connect_net -hier -net mig_sys_clk -objects [list [get_pins u_bufg_mig/O] [get_pins $pll/CLKIN1]]
connect_net -net osc_locked -objects [get_pins u_mmcm_mig/LOCKED]
# tie-offs
set gnd [get_nets -of [get_pins -of [get_cells -hier -filter {REF_NAME == GND}] -filter {DIRECTION == OUT}]]
set gnd [lindex $gnd 0]
set vcc [lindex [get_nets -of [get_pins -of [get_cells -hier -filter {REF_NAME == VCC}] -filter {DIRECTION == OUT}]] 0]
foreach p {CLKIN2 PWRDWN DCLK DEN DWE PSCLK PSEN PSINCDEC} { connect_net -hier -net $gnd -objects [get_pins u_mmcm_mig/$p] }
foreach p [get_pins {u_mmcm_mig/DADDR[*] u_mmcm_mig/DI[*]}] { connect_net -hier -net $gnd -objects $p }
connect_net -hier -net $vcc -objects [get_pins u_mmcm_mig/CLKINSEL]

# resets: MMCM RST = !sys_rst ; MIG sys_rst = sys_rst & locked
set n_rst [get_nets sys_rst_IBUF]
create_cell -reference LUT1 u_osc_rst_inv
set_property INIT 2'h1 [get_cells u_osc_rst_inv]
create_net osc_mmcm_rst
connect_net -net $n_rst -objects [get_pins u_osc_rst_inv/I0]
connect_net -net osc_mmcm_rst -objects [get_pins {u_osc_rst_inv/O u_mmcm_mig/RST}]
create_cell -reference LUT2 u_mig_rst_and
set_property INIT 4'h8 [get_cells u_mig_rst_and]
create_net mig_sys_rst
disconnect_net -objects [get_pins u_mig/sys_rst]
connect_net -net $n_rst -objects [get_pins u_mig_rst_and/I0]
connect_net -net osc_locked -objects [get_pins u_mig_rst_and/I1]
connect_net -hier -net mig_sys_rst -objects [list [get_pins u_mig_rst_and/O] [get_pins u_mig/sys_rst]]

# oscillator input: LVDS_25 in bank 34 (input only, no internal termination)
set_property IOSTANDARD LVDS_25 [get_ports {sys_clk_p sys_clk_n}]
set_property DIFF_TERM FALSE [get_ports {sys_clk_p sys_clk_n}]
create_clock -period 5.000 -name osc_200 [get_ports sys_clk_p]
# every generated clock is re-derived from osc_200 (new names): re-apply
# the clock-domain-crossing constraints of constr/v4_board_top.xdc
set_max_delay -datapath_only -from [get_clocks -of_objects [get_nets ui_clk]] -to [get_clocks -of_objects [get_nets core_clk]] 5.000
set_max_delay -datapath_only -from [get_clocks -of_objects [get_nets core_clk]] -to [get_clocks -of_objects [get_nets ui_clk]] 6.450
set_max_delay -datapath_only -from [get_clocks qsclk] -to [get_clocks -of_objects [get_nets ui_clk]] 6.450
set_max_delay -datapath_only -from [get_clocks -of_objects [get_nets ui_clk]] -to [get_clocks qsclk] 12.500
# the 200 MHz domain (IDELAYCTRL reference, MIG temperature monitor) meets
# ui_clk only through the MIG's own synchronizers, as with the former
# separate clk_ref oscillator: asynchronous (now they are related through
# the MMCM, and the clock skew would make the 2-flop syncs fail hold)
set_clock_groups -asynchronous -group [get_clocks osc_200] -group [get_clocks -of_objects [get_nets ui_clk]]

# place the 4 new cells by hand (place_design would re-place existing
# cells too): free MMCM and BUFG sites, the two LUTs in an empty SLICEL
set mm [lindex [get_sites -filter {SITE_TYPE == MMCME2_ADV && IS_USED == 0}] 0]
set bg [lindex [get_sites -filter {SITE_TYPE == BUFGCTRL && IS_USED == 0}] 0]
# an empty SLICEL nearest (in site coordinates) to the sys_rst input buffer
regexp {X(\d+)Y(\d+)} [get_sites -of [get_cells sys_rst_IBUF_inst]] -> rx ry
set sl ""; set bd 1e9
foreach t [get_sites -filter {SITE_TYPE == SLICEL && IS_USED == 0}] {
    regexp {X(\d+)Y(\d+)} $t -> tx ty
    set d [expr {abs($tx - $rx) + abs($ty - $ry)}]
    if {$d < $bd} { set bd $d; set sl $t }
}
puts "ECO new cells: MMCM $mm, BUFG $bg, LUTs in $sl"
place_cell [list u_mmcm_mig $mm u_bufg_mig $bg u_osc_rst_inv $sl/A6LUT u_mig_rst_and $sl/B6LUT]
set moved 0
dict for {c loc} $snap { if {[llength [get_cells -quiet $c]] && [get_property LOC [get_cells $c]] ne $loc} { incr moved } }
puts "ECO placed: MMCM [get_property LOC [get_cells u_mmcm_mig]], BUFG [get_property LOC [get_cells u_bufg_mig]]; existing cells moved: $moved"
set eco_nets [get_nets -hier -filter {ROUTE_STATUS != ROUTED && ROUTE_STATUS != INTRASITE && TYPE != POWER && TYPE != GROUND}]
puts "ECO nets to route: [llength $eco_nets] $eco_nets"
route_design -nets $eco_nets
route_design -physical_nets
report_route_status -file $out/route_status.rpt
report_timing_summary -max_paths 20 -file $out/board_timing.rpt
report_clocks -file $out/board_clocks.rpt
report_drc -file $out/board_drc.rpt
report_io -file $out/board_io.rpt
report_utilization -file $out/board_util.rpt
foreach b {14 34} {
    set ports [get_ports -quiet -filter "IOBANK == $b"]
    if {[llength $ports]} { puts "BANK $b ports=[llength $ports] stds=[lsort -unique [get_property IOSTANDARD $ports]]" } else { puts "BANK $b ports=0" }
}
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "ECO $tag WNS $wns WHS $whs"
write_checkpoint -force $out/v4_board_$tag.dcp
report_power -file $out/power_default.rpt
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
if {$wns >= 0 && $whs >= 0} {
    write_bitstream -force $out/v4_board_top_$tag.bit
    puts "BITSIZE [file size $out/v4_board_top_$tag.bit]"
} else { puts "timing not met: no bitstream" }
