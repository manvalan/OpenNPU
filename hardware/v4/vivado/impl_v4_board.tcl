# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# ============================================================
# v4 board -- synthesis + implementation + bitstream of v4_board_top in
# the project made by create_v4_board.tcl (same flow as the core-only
# signoff, constr/pr_core.tcl). Used for V4-B7/B8 (PROGRESS_LOG.md).
#
#   vivado -mode batch -source impl_v4_board.tcl -tclargs <proj_dir> <report_dir> <bit_file> [<reference_routed.dcp>]
#
# One thread (thermal limit of the build machine); a run takes 3-12 h.
# The core clock is set by the MMCM in rtl/v4_board_top.v
# (CLKOUT0_DIVIDE_F 7.000 -> 199.34 MHz, 7.375 -> 189.20 MHz).
# ============================================================
set_param general.maxThreads 1
set proj_dir [lindex $argv 0]
set rpt      [lindex $argv 1]
set bit      [lindex $argv 2]
open_project $proj_dir/v4_board.xpr
set here [file dirname [file normalize [info script]]]
set rtl [file normalize $here/../rtl]
if {[llength [get_files -quiet $rtl/qspi_data_port.v]] == 0} { add_files -norecurse $rtl/qspi_data_port.v }
set_property top v4_board_top [get_filesets sources_1]
update_compile_order -fileset sources_1
# every source must be a direct reference (CLAUDE.md: stale imported copies)
foreach f [concat [get_files -of_objects [get_filesets sources_1]] [get_files -of_objects [get_filesets constrs_1]]] {
    if {[string match "*/imports/*" $f]} { puts "STALE-IMPORT $f" }
}
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
# optional 4th argument: a routed checkpoint for incremental implementation
# (keeps the placement/routing of a closed build where the netlist matches)
if {[llength $argv] > 3} {
    set_property incremental_checkpoint [lindex $argv 3] [get_runs impl_1]
    set_property INCREMENTAL_CHECKPOINT.DIRECTIVE TimingClosure [get_runs impl_1]
    puts "INCREMENTAL [lindex $argv 3]"
}
set_property STEPS.SYNTH_DESIGN.ARGS.KEEP_EQUIVALENT_REGISTERS true [get_runs synth_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraTimingOpt [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
reset_run synth_1
launch_runs synth_1 -jobs 1
wait_on_run synth_1
launch_runs impl_1 -jobs 1
wait_on_run impl_1
open_run impl_1
file mkdir $rpt
report_timing_summary -max_paths 20 -file $rpt/board_timing.rpt
report_utilization -file $rpt/board_util.rpt
report_clock_interaction -file $rpt/board_clocks.rpt
report_drc -file $rpt/board_drc.rpt
report_io -file $rpt/board_io.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "BOARD WNS $wns WHS $whs"
if {$wns >= 0 && $whs >= 0} {
    write_bitstream -force $bit
    puts "BITSTREAM $bit"
} else {
    puts "timing not met: no bitstream"
}
