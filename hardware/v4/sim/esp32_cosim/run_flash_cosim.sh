#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# ESP32 configuration driver tests. Usage (from hardware/v4):
#   sim/esp32_cosim/run_flash_cosim.sh [out_dir]
# 1. jtag_tap_test: fpga_v4_jtag_* against a C model of the 7-series TAP.
# 2. config-flash co-simulation: fpga_v4_flash_* (real driver, compiled for
#    the host with idf_cosim.c) against v4_board_top RTL + a W25Q32JV model
#    (tb_v4_flash_cosim.v), connected by two named pipes.
# Needs gcc and iverilog/vvp (OSS CAD Suite or distro package).
set -e
OUT=${1:-/tmp/v4flashcosim}
HERE=sim/esp32_cosim
V3=../v3/rtl
FW=../../firmware/esp32/components/fpga_neural
mkdir -p $OUT
[ -n "$OSS_CAD" ] && source $OSS_CAD/environment
CF="-O2 -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -I$HERE/idf -I$FW/include"

gcc $CF -o $OUT/jtag_tap_test $HERE/jtag_tap_test.c $FW/fpga_neural_v4_config.c
$OUT/jtag_tap_test > $OUT/jtag_tap_test.log 2>&1 || true
cat $OUT/jtag_tap_test.log

# FLASH_HZ=<hz> overrides the driver's FLASH_XFER clock (margin sweeps)
[ -n "$FLASH_HZ" ] && CF="$CF -DFLASH_SPI_HZ=$FLASH_HZ"
# SMALL=1: 300-byte image instead of 4400 (about 1/10 of the simulation time)
[ -n "$SMALL" ] && CF="$CF -DSMALL_IMAGE"
gcc $CF -o $OUT/cosim_flash_main $HERE/cosim_flash_main.c $HERE/idf_cosim.c \
    $FW/fpga_neural_v4.c $FW/fpga_neural_v4_config.c

CORE="rtl/v4_core.v rtl/gdconv_unit.v rtl/param_loader.v rtl/im2col_feeder.v rtl/fmap_mem.v rtl/fmap_feeder.v rtl/conv3_feeder.v rtl/pool_unit.v rtl/tile_writer.v rtl/dwpw_engine.v rtl/dw_linebuf_grouped.v rtl/depthwise_mac3x3_pipe.v rtl/requant_act.v rtl/pw_array_packed.v"
iverilog -g2012 -o $OUT/tb_flash -DV4_SIM_CLK -DPIPE_DIR="\"$OUT\"" \
    $HERE/tb_v4_flash_cosim.v sim/w25q32_model.v sim/mig_7series_0_stub.v sim/startupe2_stub.v \
    rtl/v4_board_top.v rtl/v4_boot.v rtl/v4_ddr_stream.v rtl/async_fifo.v rtl/qspi_data_port.v $CORE \
    $V3/mig_native_adapter.v $V3/flash_spi_master.v

rm -f $OUT/cosim_c2v $OUT/cosim_v2c
mkfifo $OUT/cosim_c2v $OUT/cosim_v2c
vvp -n $OUT/tb_flash > $OUT/tb_flash.log &
VVP=$!
$OUT/cosim_flash_main $OUT/cosim_c2v $OUT/cosim_v2c $OUT > $OUT/cosim_flash_main.log 2>&1 || true
wait $VVP
cat $OUT/cosim_flash_main.log $OUT/tb_flash.log
grep -q "ALL TESTS PASSED" $OUT/jtag_tap_test.log
grep -q "ALL TESTS PASSED" $OUT/cosim_flash_main.log
grep -q "BENCH PASS" $OUT/tb_flash.log
