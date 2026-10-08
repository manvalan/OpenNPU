# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
set_param general.maxThreads 1
set rtl /home/michele/Develop/FPGA-Neural/.claude/worktrees/bridge-cse_01JjTaHDDpp7a3tpAaP1SrVY/hardware/v4/rtl
set out /tmp/claude-1000/v4pr
set stage [lindex $argv 0]
read_verilog [list $rtl/v4_core_top.v $rtl/v4_core.v $rtl/gdconv_unit.v $rtl/param_loader.v $rtl/im2col_feeder.v $rtl/fmap_mem.v $rtl/fmap_feeder.v $rtl/conv3_feeder.v $rtl/pool_unit.v $rtl/tile_writer.v \
  $rtl/dwpw_engine.v $rtl/dw_linebuf_grouped.v $rtl/depthwise_mac3x3_pipe.v $rtl/requant_act.v $rtl/pw_array_packed.v]
read_xdc $out/core_top.xdc
synth_design -top v4_core_top -part xc7a100tcsg324-2 -keep_equivalent_registers
read_xdc $out/core_top_post.xdc
report_utilization -file $out/util_synth.rpt
report_timing_summary -file $out/tim_synth.rpt
write_checkpoint -force $out/post_synth.dcp
if {$stage eq "synth"} { exit }
opt_design
place_design -directive ExtraTimingOpt
report_utilization -file $out/util_place.rpt
phys_opt_design -directive AggressiveExplore
route_design -directive AggressiveExplore
phys_opt_design -directive AggressiveExplore
report_utilization -file $out/util_route.rpt
report_timing_summary -max_paths 20 -file $out/tim_route.rpt
write_checkpoint -force $out/post_route.dcp
