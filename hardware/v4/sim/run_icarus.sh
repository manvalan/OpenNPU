#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# v4 regression in Icarus (OSS CAD Suite). Usage: sim/run_icarus.sh [out_dir]
# Builds the C golden model, then runs the unit tests, the whole-network
# core test and the whole-board test (image, registers and status over Quad-SPI,
# embedding compared bit for bit). Run from hardware/v4.
set -e
OUT=${1:-/tmp/v4sim}
V3=../v3/rtl
mkdir -p $OUT/mfn
source ${OSS_CAD:-$HOME/tools_cache/oss-cad-suite}/environment
gcc -O2 -o $OUT/gen_mfn model/gen_mfn.c -lm
$OUT/gen_mfn $OUT/mfn > $OUT/gen_mfn.log

CORE="rtl/v4_core.v rtl/param_lutram.v rtl/gdconv_unit.v rtl/param_loader.v rtl/im2col_feeder.v rtl/fmap_mem.v rtl/fmap_feeder.v rtl/conv3_feeder.v rtl/pool_unit.v rtl/tile_writer.v rtl/dwpw_engine.v rtl/dw_linebuf_grouped.v rtl/depthwise_mac3x3_pipe.v rtl/requant_act.v rtl/pw_array_packed.v"
run() { name=$1; shift; iverilog -g2012 -o $OUT/$name "$@"; vvp -n $OUT/$name > $OUT/$name.log; grep -E "ALL TESTS PASSED|FAIL" $OUT/$name.log | tail -1; }
run tb_requant_act     sim/tb_requant_act.v rtl/requant_act.v
run tb_pw_array_packed sim/tb_pw_array_packed.v rtl/pw_array_packed.v
run tb_dw_linebuf      sim/tb_dw_linebuf_grouped.v rtl/dw_linebuf_grouped.v rtl/depthwise_mac3x3_pipe.v rtl/param_lutram.v
run tb_dwpw_engine     sim/tb_dwpw_engine.v rtl/dwpw_engine.v rtl/param_lutram.v rtl/dw_linebuf_grouped.v rtl/depthwise_mac3x3_pipe.v rtl/requant_act.v rtl/pw_array_packed.v
run tb_im2col_feeder   sim/tb_im2col_feeder.v rtl/im2col_feeder.v
run tb_conv3_feeder    sim/tb_conv3_feeder.v rtl/conv3_feeder.v
run tb_async_fifo      sim/tb_async_fifo.v rtl/async_fifo.v
run tb_v4_ddr_stream   sim/tb_v4_ddr_stream.v rtl/v4_ddr_stream.v $V3/mig_native_adapter.v
run tb_qspi_data_port  sim/tb_qspi_data_port.v rtl/qspi_data_port.v rtl/async_fifo.v
run tb_v4_core_mfn     -DMFN_DIR="\"$OUT/mfn\"" sim/tb_v4_core_mfn.v $CORE
run tb_v4_board_top    -DV4_SIM_CLK -DMFN_DIR="\"$OUT/mfn\"" sim/tb_v4_board_top.v sim/mig_7series_0_stub.v sim/startupe2_stub.v \
    rtl/v4_board_top.v rtl/v4_boot.v rtl/v4_ddr_stream.v rtl/async_fifo.v rtl/qspi_data_port.v $CORE \
    $V3/mig_native_adapter.v $V3/flash_spi_master.v
