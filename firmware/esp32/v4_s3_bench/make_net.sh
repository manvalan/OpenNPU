#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# Builds net/net.bin for the S3 app: network + parameter pack + input +
# expected output (the FPGA's, bit for bit).
#   ./make_net.sh NET                     random calibrated model (as v4_qat --selftest)
#   ./make_net.sh NET model.pack img.bin  your own pack and INT8 input
# NET = a hardware/v4/model/v4_plan.py example name (bench_small,
# bench_medium, bench_heavy, mfn, ...) or a .py file with NET = [...].
# Needs python3 + numpy (+ torch for the random model).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
M=$HERE/../../../hardware/v4/model
mkdir -p $HERE/net
if [ -n "$2" ]; then
    python3 $M/s3_export.py "$1" "$2" $HERE/net/net.bin --image "$3"
else
    TMP=$(mktemp -d)
    python3 $M/v4_qat.py --pack "$1" $TMP
    python3 $M/s3_export.py "$1" $TMP/model.pack $HERE/net/net.bin --image $TMP/img.bin
    cp $TMP/model.pack $TMP/img.bin $HERE/net/
    rm -rf $TMP
fi
