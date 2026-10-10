#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# The 7-network bit-exact check of the generic core (Icarus): for each
# network a random calibrated model (v4_qat.py --selftest, which also
# checks PyTorch = v4_ref.py = v4_compile.py), compiled by v4_compile.py,
# run on tb_v4_core_mfn.v (every pass's output tensor compared).
#   sim/run_nets.sh [out_dir] [python]     (from hardware/v4)
# python: an interpreter with torch + numpy (default python3).
OUT=${1:-/tmp/v4nets}
PY=${2:-python3}
NETS=${NETS:-"bench_small bench_medium resnet_s vgg_pool mfn unet_s mlp784"}
mkdir -p $OUT
source ${OSS_CAD:-$HOME/tools_cache/oss-cad-suite}/environment
CORE="rtl/v4_core.v rtl/param_lutram.v rtl/gdconv_unit.v rtl/param_loader.v rtl/im2col_feeder.v rtl/fmap_mem.v rtl/fmap_feeder.v rtl/conv3_feeder.v rtl/pool_unit.v rtl/tile_writer.v rtl/dwpw_engine.v rtl/dw_linebuf_grouped.v rtl/depthwise_mac3x3_pipe.v rtl/requant_act.v rtl/pw_array_packed.v"
fail=0
for n in $NETS; do
    D=$OUT/$n; mkdir -p $D
    (cd model && $PY v4_qat.py --selftest --net $n --out $D > $D/selftest.log 2>&1) || { echo "$n: SELFTEST FAIL"; fail=1; continue; }
    iverilog -g2012 -DMFN_DIR="\"$D\"" -o $OUT/core_$n sim/tb_v4_core_mfn.v $CORE > $D/build.log 2>&1 || { echo "$n: BUILD FAIL"; fail=1; continue; }
    vvp -n $OUT/core_$n > $D/run.log 2>&1
    r=$(grep -E "^=== network" $D/run.log | sed -E 's/.*errors; TOTAL ([0-9]+) cycles.*/\1/')
    if grep -q "ALL TESTS PASSED" $D/run.log; then echo "$n: bit-exact, $r cycles"; else echo "$n: FAIL ($(grep -c MISMATCH $D/run.log) mismatched passes)"; fail=1; fi
done
exit $fail
