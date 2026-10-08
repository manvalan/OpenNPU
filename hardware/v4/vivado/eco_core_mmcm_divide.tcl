# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
set_param general.maxThreads 2
open_checkpoint /tmp/claude-1000/-home-michele-Develop-FPGA-Neural--claude-worktrees-bridge-cse-01A7fhzxrKaem5Rky2Cig2CN/43072044-2be3-501e-928d-8f5f3ee5ecb1/scratchpad/eco/m199_eco_best.dcp
set m [get_cells u_mmcm]
puts "MM cell $m [get_property REF_NAME $m] O=[get_property CLKOUT0_DIVIDE_F $m] M=[get_property CLKFBOUT_MULT_F $m] D=[get_property DIVCLK_DIVIDE $m]"
foreach o {7.125 7.250} {
  set_property CLKOUT0_DIVIDE_F $o $m
  update_timing -full
  set clk [get_clocks -of [get_pins $m/CLKOUT0]]
  set w [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
  set h [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
  set wc [get_property SLACK [get_timing_paths -to [get_clocks core_clk_unbuf] -max_paths 1 -setup]]
  puts "MM O=$o period [get_property PERIOD [get_clocks core_clk_unbuf]] core WNS $wc all WNS $w WHS $h"
  if {$w >= 0 && $h >= 0} {
    set tag [string map {. _} $o]
    set R /home/michele/Develop/FPGA-Neural/.claude/worktrees/bridge-cse_01A7fhzxrKaem5Rky2Cig2CN/hardware/v4/docs/pnr/board/fix/m196
    file mkdir $R
    report_timing_summary -max_paths 20 -file $R/timing_summary_O$tag.rpt
    report_route_status -file $R/route_status_O$tag.rpt
    report_drc -file $R/drc_O$tag.rpt
    report_utilization -file $R/util_O$tag.rpt
    write_checkpoint -force /tmp/claude-1000/-home-michele-Develop-FPGA-Neural--claude-worktrees-bridge-cse-01A7fhzxrKaem5Rky2Cig2CN/43072044-2be3-501e-928d-8f5f3ee5ecb1/scratchpad/eco/m199_O$tag.dcp
    write_bitstream -force /tmp/claude-1000/-home-michele-Develop-FPGA-Neural--claude-worktrees-bridge-cse-01A7fhzxrKaem5Rky2Cig2CN/43072044-2be3-501e-928d-8f5f3ee5ecb1/scratchpad/eco/v4_board_area_O$tag.bit
    write_cfgmem -force -format bin -interface SPIx1 -loadbit "up 0x0 /tmp/claude-1000/-home-michele-Develop-FPGA-Neural--claude-worktrees-bridge-cse-01A7fhzxrKaem5Rky2Cig2CN/43072044-2be3-501e-928d-8f5f3ee5ecb1/scratchpad/eco/v4_board_area_O$tag.bit" /tmp/claude-1000/-home-michele-Develop-FPGA-Neural--claude-worktrees-bridge-cse-01A7fhzxrKaem5Rky2Cig2CN/43072044-2be3-501e-928d-8f5f3ee5ecb1/scratchpad/eco/v4_board_area_O$tag.bin
    puts "MM BITSTREAM O=$o"
    break
  }
}
