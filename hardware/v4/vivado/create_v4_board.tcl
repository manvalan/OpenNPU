# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# ============================================================
# v4 board -- creates a fresh Vivado project for v4_board_top.
#
#   vivado -mode batch -source create_v4_board.tcl -tclargs <proj_dir> <v3_mig_ip_dir> <mfn_dir> <mig_example_sim_dir>
#
# <v3_mig_ip_dir>: the board's MIG configuration from the v3 project
#   (Vivado/NeuralProcessor/NeuralProcessor.srcs/sources_1/ip/mig_7series_0,
#   containing mig_7series_0.xci + mig_a.prj). import_ip copies them into
#   the new project -- the v3 project is never touched.
# All RTL / constraint / simulation sources are added by reference (no
# imported copies that could go stale -- see CLAUDE.md).
# ============================================================
set_param general.maxThreads 1
set proj_dir [lindex $argv 0]
set mig_src  [lindex $argv 1]
set mfn_dir  [lindex $argv 2]
# Micron DDR3 model + wiredly.v from the MIG example design (static files,
# same for the same MIG configuration; read by reference, never modified)
set exsim    [lindex $argv 3]
set here [file dirname [file normalize [info script]]]
set v4 [file normalize $here/..]
set v3 [file normalize $here/../../v3]

create_project v4_board $proj_dir -part xc7a100tcsg324-2 -force
set_property target_language Verilog [current_project]

# ---- MIG IP (config imported into this project, generated here) ----
import_ip $mig_src/mig_7series_0.xci
set ipdir [file dirname [get_property IP_FILE [get_ips mig_7series_0]]]
file copy -force $mig_src/mig_a.prj $ipdir/
reset_target all [get_ips mig_7series_0]
generate_target all [get_ips mig_7series_0]

# ---- design sources (by reference) ----
set rtl_v4 {v4_board_top v4_boot v4_ddr_stream async_fifo v4_core im2col_feeder param_loader
            gdconv_unit fmap_mem fmap_feeder conv3_feeder pool_unit tile_writer dwpw_engine dw_linebuf_grouped
            depthwise_mac3x3_pipe requant_act pw_array_packed qspi_data_port}
foreach m $rtl_v4 { add_files -norecurse $v4/rtl/$m.v }
foreach m {mig_native_adapter flash_spi_master} {
    add_files -norecurse $v3/rtl/$m.v
}
add_files -fileset constrs_1 -norecurse $v4/constr/v4_board_top.xdc
set_property top v4_board_top [get_filesets sources_1]

# ---- board simulation set (real MIG + Micron DDR3 models) ----
create_fileset -simset sim_board
add_files -fileset sim_board -norecurse [list $v4/sim/tb_v4_board_xsim.v $exsim/ddr3_model.sv \
    $exsim/ddr3_model_parameters.vh $exsim/wiredly.v]
set_property file_type {Verilog Header} [get_files $exsim/ddr3_model_parameters.vh]
set_property top tb [get_filesets sim_board]
set_property verilog_define [list "MFN_DIR=\"$mfn_dir\"" x2Gb sg125] [get_filesets sim_board]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_board]
current_fileset -simset [get_filesets sim_board]
puts "v4_board project created in $proj_dir"
