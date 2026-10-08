# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# v4 board -- synthesis + implementation reusing the placement of a closed
# routed checkpoint (dump_placement.tcl), for netlist changes that are
# small but not a pin-only ECO (e.g. the board clocking). Same directives
# as impl_v4_board.tcl. Vivado's incremental implementation would do this
# natively but is not in the BASIC license.
#   vivado -mode batch -source impl_reuse_placement.tcl -tclargs <proj_dir> <placement.tcl> <report_dir> <bit_file>
set_param general.maxThreads 1
set proj_dir [lindex $argv 0]
set rpt [lindex $argv 2]
set bit [lindex $argv 3]
open_project $proj_dir/v4_board.xpr
set_property top v4_board_top [get_filesets sources_1]
update_compile_order -fileset sources_1
foreach f [concat [get_files -of_objects [get_filesets sources_1]] [get_files -of_objects [get_filesets constrs_1]]] {
    if {[string match "*/imports/*" $f]} { puts "STALE-IMPORT $f" }
}
set_property STEPS.SYNTH_DESIGN.ARGS.KEEP_EQUIVALENT_REGISTERS true [get_runs synth_1]
reset_run synth_1
launch_runs synth_1 -jobs 1
wait_on_run synth_1
open_run synth_1 -name synth_1
file mkdir $rpt
opt_design -directive Explore
source [lindex $argv 1]
set have [dict create]
foreach c [get_cells -hier -filter {IS_PRIMITIVE}] { dict set have $c 1 }
set pairs {}
set miss 0
foreach {c sb} $P { if {[dict exists $have $c]} { lappend pairs $c $sb } else { incr miss } }
puts "REUSE [expr {[llength $pairs]/2}] cells, $miss not in the new netlist"
set ok 0; set bad 0
for {set i 0} {$i < [llength $pairs]} {incr i 2000} {
    set chunk [lrange $pairs $i [expr {$i + 1999}]]
    if {[catch {place_cell $chunk}]} {
        foreach {c sb} $chunk { if {[catch {place_cell $c $sb}]} { incr bad } else { incr ok } }
    } else { incr ok [expr {[llength $chunk]/2}] }
}
puts "PLACED-FROM-REFERENCE $ok, failed $bad"
place_design -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design -directive AggressiveExplore
phys_opt_design -directive AggressiveExplore
write_checkpoint -force $rpt/v4_board_routed.dcp
report_timing_summary -max_paths 20 -file $rpt/board_timing.rpt
report_utilization -file $rpt/board_util.rpt
report_clock_interaction -file $rpt/board_clocks.rpt
report_drc -file $rpt/board_drc.rpt
report_io -file $rpt/board_io.rpt
report_route_status -file $rpt/route_status.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "BOARD WNS $wns WHS $whs"
if {$wns >= 0 && $whs >= 0} {
    write_bitstream -force $bit
    puts "BITSTREAM $bit"
} else {
    puts "timing not met: no bitstream"
}
