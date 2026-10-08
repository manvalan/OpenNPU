# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
set_param general.maxThreads 2
open_checkpoint /tmp/claude-1000/-home-michele-Develop-FPGA-Neural--claude-worktrees-bridge-cse-01A7fhzxrKaem5Rky2Cig2CN/43072044-2be3-501e-928d-8f5f3ee5ecb1/scratchpad/eco/m199_routed.dcp
proc wns {} { return [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]] }
puts "ECO start WNS [wns]"
set best [wns]
foreach step {
  {phys_opt_design -directive AggressiveExplore}
  {phys_opt_design -directive AlternateFlowWithRetiming}
  {route_design -directive AggressiveExplore}
  {phys_opt_design -directive AggressiveFanoutOpt}
  {phys_opt_design -directive Explore}
  {route_design -directive Explore}
  {phys_opt_design -directive AggressiveExplore}
  {route_design -directive AggressiveExplore}
} {
  if {[wns] >= 0} break
  if {[catch {eval $step} e]} { puts "ECO step failed: $step $e" }
  set w [wns]; set h [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
  puts "ECO after {$step}: WNS $w WHS $h"
  if {$w > $best} { set best $w; write_checkpoint -force /tmp/claude-1000/-home-michele-Develop-FPGA-Neural--claude-worktrees-bridge-cse-01A7fhzxrKaem5Rky2Cig2CN/43072044-2be3-501e-928d-8f5f3ee5ecb1/scratchpad/eco/m199_eco_best.dcp }
}
set w [wns]; set h [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
report_route_status -file /tmp/claude-1000/-home-michele-Develop-FPGA-Neural--claude-worktrees-bridge-cse-01A7fhzxrKaem5Rky2Cig2CN/43072044-2be3-501e-928d-8f5f3ee5ecb1/scratchpad/eco/route_status.rpt
puts "ECO final WNS $w WHS $h"
if {$w >= 0 && $h >= 0} {
  write_checkpoint -force /tmp/claude-1000/-home-michele-Develop-FPGA-Neural--claude-worktrees-bridge-cse-01A7fhzxrKaem5Rky2Cig2CN/43072044-2be3-501e-928d-8f5f3ee5ecb1/scratchpad/eco/m199_eco_closed.dcp
  file mkdir /home/michele/Develop/FPGA-Neural/.claude/worktrees/bridge-cse_01A7fhzxrKaem5Rky2Cig2CN/hardware/v4/docs/pnr/board/fix/m199/eco
  report_timing_summary -max_paths 20 -file /home/michele/Develop/FPGA-Neural/.claude/worktrees/bridge-cse_01A7fhzxrKaem5Rky2Cig2CN/hardware/v4/docs/pnr/board/fix/m199/eco/eco_timing_summary.rpt
  report_utilization -file /home/michele/Develop/FPGA-Neural/.claude/worktrees/bridge-cse_01A7fhzxrKaem5Rky2Cig2CN/hardware/v4/docs/pnr/board/fix/m199/eco/eco_util.rpt
  report_drc -file /home/michele/Develop/FPGA-Neural/.claude/worktrees/bridge-cse_01A7fhzxrKaem5Rky2Cig2CN/hardware/v4/docs/pnr/board/fix/m199/eco/eco_drc.rpt
  report_route_status -file /home/michele/Develop/FPGA-Neural/.claude/worktrees/bridge-cse_01A7fhzxrKaem5Rky2Cig2CN/hardware/v4/docs/pnr/board/fix/m199/eco/eco_route_status.rpt
  write_bitstream -force /tmp/claude-1000/-home-michele-Develop-FPGA-Neural--claude-worktrees-bridge-cse-01A7fhzxrKaem5Rky2Cig2CN/43072044-2be3-501e-928d-8f5f3ee5ecb1/scratchpad/eco/v4_board_area_199.bit
  write_cfgmem -force -format bin -interface SPIx1 -loadbit "up 0x0 /tmp/claude-1000/-home-michele-Develop-FPGA-Neural--claude-worktrees-bridge-cse-01A7fhzxrKaem5Rky2Cig2CN/43072044-2be3-501e-928d-8f5f3ee5ecb1/scratchpad/eco/v4_board_area_199.bit" /tmp/claude-1000/-home-michele-Develop-FPGA-Neural--claude-worktrees-bridge-cse-01A7fhzxrKaem5Rky2Cig2CN/43072044-2be3-501e-928d-8f5f3ee5ecb1/scratchpad/eco/v4_board_area_199.bin
  puts "ECO BITSTREAM"
}
