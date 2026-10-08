# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# Real-MIG + Micron DDR3 simulation of the whole board (tb_v4_board_xsim.v).
#   vivado -mode batch -source run_board_xsim.tcl -tclargs <n_pass> <proj_dir> <mfn_dir>
# 40 passes = the whole network, about 3 h of CPU.
set_param general.maxThreads 1
open_project [lindex $argv 1]/v4_board.xpr
set npass [lindex $argv 0]
set here [file dirname [file normalize [info script]]]
set rtl [file normalize $here/../rtl]
if {[llength [get_files -quiet $rtl/qspi_data_port.v]] == 0} { add_files -norecurse $rtl/qspi_data_port.v }
foreach f [get_files -of_objects [get_filesets sources_1]] { if {[string match "*/imports/*" $f]} { puts "STALE-IMPORT $f" } }
update_compile_order -fileset sources_1
set_property verilog_define [list "MFN_DIR=\"[lindex $argv 2]\"" x2Gb sg125 "N_PASS=$npass"] [get_filesets sim_board]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_board]
set_property -name {xsim.simulate.log_all_signals} -value {false} -objects [get_filesets sim_board]
launch_simulation -simset sim_board -mode behavioral
close_sim
