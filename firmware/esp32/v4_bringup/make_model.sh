#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# Builds model/model.bin (DDR3 image: header, descriptors, input image,
# parameters) and model/golden.bin (expected output, INT8, hardware layout:
# channels padded to 16-channel groups) for the app.
#   ./make_model.sh                              random test model (128 embedding)
#   ./make_model.sh model.espdl face_112.png     real ESP-DL MobileFaceNet (512 embedding)
#   ./make_model.sh model.pack face_112.png      parameter pack already made
#                                                (e.g. hardware/v4/model/v4_qat.py export_pack)
#   ./make_model.sh --net NET model.pack input   any network (hardware/v4/model/v4_compile.py):
#                                                NET = a v4_plan.py example name or a .py
#                                                file with NET = [...]; input = img.bin (INT8
#                                                HWC of the network's input size, e.g. from
#                                                v4_qat.py --pack) or a 112x112 face image
# face_112.png: a face aligned to 112x112 (hardware/v4/model/align_face.py).
# Needs gcc and python3 (+ numpy/Pillow for the real model).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
V4=$HERE/../../../hardware/v4
OUT=$HERE/model
TMP=$(mktemp -d)
mkdir -p $OUT
gcc -O2 -o $TMP/gen_mfn $V4/model/gen_mfn.c -lm
if [ "$1" = "--net" ]; then
    case "$4" in
        *.bin) cp "$4" $TMP/face.img ;;
        *)     python3 $V4/model/espdl_to_v4.py --image "$4" $TMP/face.img ;;
    esac
    python3 $V4/model/v4_compile.py "$2" "$3" $TMP --image $TMP/face.img > $TMP/gen.log
elif [ -n "$1" ]; then
    case "$1" in
        *.pack) cp "$1" $TMP/model.pack ;;
        *)      python3 $V4/model/espdl_to_v4.py "$1" $TMP/model.pack > $TMP/convert.log ;;
    esac
    python3 $V4/model/espdl_to_v4.py --image "$2" $TMP/face.img
    $TMP/gen_mfn $TMP --params $TMP/model.pack --image $TMP/face.img > $TMP/gen.log
else
    $TMP/gen_mfn $TMP > $TMP/gen.log
fi
python3 $V4/model/ddr_hex_to_bin.py $TMP/ddr_full.hex $OUT/model.bin
python3 - $TMP/golden_ref.txt $OUT/golden.bin <<'PY'
import struct, sys
t = open(sys.argv[1]).read().split(":")[1].split()
open(sys.argv[2], "wb").write(struct.pack("<%db" % len(t), *map(int, t)))
print("golden.bin: %d values" % len(t))
PY
cat $TMP/gen.log
rm -rf $TMP
