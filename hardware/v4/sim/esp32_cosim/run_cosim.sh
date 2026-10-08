#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# ESP32 driver <-> v4 RTL co-simulation. Usage (from hardware/v4):
#   sim/esp32_cosim/run_cosim.sh [out_dir]
#   sim/esp32_cosim/run_cosim.sh out_dir model.pack image.img   (real weights, model/espdl_to_v4.py)
#   sim/esp32_cosim/run_cosim.sh out_dir --compiled dir          (any network: the output
#                                                                 directory of model/v4_compile.py)
# Builds gen_mfn and the model blob, compiles the real ESP32 driver for the
# host (idf_cosim.c stands in for ESP-IDF), builds tb_v4_esp32_cosim.v with
# the whole board RTL and runs both connected by two named pipes.
# Needs gcc, python3, iverilog/vvp (OSS CAD Suite or distro package).
set -e
OUT=${1:-/tmp/v4cosim}
HERE=sim/esp32_cosim
V3=../v3/rtl
FW=../../firmware/esp32/components/fpga_neural
mkdir -p $OUT/mfn
[ -n "$OSS_CAD" ] && source $OSS_CAD/environment
gcc -O2 -o $OUT/gen_mfn model/gen_mfn.c -lm
if [ "$2" = "--compiled" ]; then
    cp "$3"/* $OUT/mfn/
elif [ -n "$2" ]; then
    $OUT/gen_mfn $OUT/mfn --params "$2" --image "$3" > $OUT/gen_mfn.log
else
    $OUT/gen_mfn $OUT/mfn > $OUT/gen_mfn.log
fi
python3 model/ddr_hex_to_bin.py $OUT/mfn/ddr_full.hex $OUT/model.bin

gcc -O2 -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -I$HERE/idf -I$FW/include \
    -o $OUT/cosim_main $HERE/cosim_main.c $HERE/idf_cosim.c \
    $FW/fpga_neural_v4.c $FW/fpga_neural_v4_bringup.c

CORE="rtl/v4_core.v rtl/gdconv_unit.v rtl/param_loader.v rtl/im2col_feeder.v rtl/fmap_mem.v rtl/fmap_feeder.v rtl/conv3_feeder.v rtl/pool_unit.v rtl/tile_writer.v rtl/dwpw_engine.v rtl/dw_linebuf_grouped.v rtl/depthwise_mac3x3_pipe.v rtl/requant_act.v rtl/pw_array_packed.v"
iverilog -g2012 -o $OUT/tb_cosim -DV4_SIM_CLK -DMFN_DIR="\"$OUT/mfn\"" -DPIPE_DIR="\"$OUT\"" \
    $HERE/tb_v4_esp32_cosim.v sim/mig_7series_0_stub.v sim/startupe2_stub.v \
    rtl/v4_board_top.v rtl/v4_boot.v rtl/v4_ddr_stream.v rtl/async_fifo.v rtl/qspi_data_port.v $CORE \
    $V3/mig_native_adapter.v $V3/flash_spi_master.v

rm -f $OUT/cosim_c2v $OUT/cosim_v2c
mkfifo $OUT/cosim_c2v $OUT/cosim_v2c
vvp -n $OUT/tb_cosim > $OUT/tb_cosim.log &
VVP=$!
LOAD=2608; [ "$2" = "--compiled" ] && LOAD=0     # 0: everything before the parameter image
$OUT/cosim_main $OUT/cosim_c2v $OUT/cosim_v2c $OUT/model.bin $OUT/mfn/golden_ref.txt $LOAD > $OUT/cosim_main.log 2>&1 || true
wait $VVP
cat $OUT/cosim_main.log $OUT/tb_cosim.log
grep -q "ALL TESTS PASSED" $OUT/cosim_main.log
