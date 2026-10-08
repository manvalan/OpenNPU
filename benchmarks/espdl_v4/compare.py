#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Accuracy of an accelerated run (ESP-DL, ONNX Runtime) against the float
network and against the FPGA's INT8 output (both from meta.json), on the
net.bin input image. Reads the OUT,<dtype>,<exponent>,v0,v1,... line of each
<net>.serial.log in a results folder; writes accuracy.csv there.

  compare.py RESULTS_DIR
Columns: cosine similarity and max |diff| / max |float| of the output vs
float, the same for the FPGA (v4) output vs float (reference: how close
the bit-exact INT8 FPGA is), and the argmax agreement with float.
"""
import csv
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
R = sys.argv[1]
rows = []
for net in ("bench_small", "bench_medium", "bench_heavy", "mfn"):
    log = os.path.join(R, net + ".serial.log")
    if not os.path.exists(log):
        continue
    line = [l.strip() for l in open(log, errors="replace") if l.startswith("OUT,")]
    if not line:
        continue
    f = line[-1].split(",")
    y = np.array([float(v) for v in f[3:]]) * 2.0 ** int(f[2])
    m = json.load(open(os.path.join(HERE, "models", net, "meta.json")))
    ref = np.array(m["float_output_hwc"])
    v4 = np.array(m["v4_output_int8"]) * 2.0 ** m["e_out_v4"]
    if y.size != ref.size:
        sys.exit("%s: %d outputs, float has %d" % (net, y.size, ref.size))

    def cos(a, b):
        return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-30))

    def rel(a, b):
        return float(np.abs(a - b).max() / (np.abs(b).max() + 1e-30))

    rows.append(dict(net=net, outputs=y.size, cos_vs_float=round(cos(y, ref), 6), maxrel_vs_float=round(rel(y, ref), 5),
                     argmax_eq_float=int(np.argmax(y) == np.argmax(ref)),
                     cos_v4_vs_float=round(cos(v4, ref), 6), maxrel_v4_vs_float=round(rel(v4, ref), 5),
                     argmax_v4_eq_float=int(np.argmax(v4) == np.argmax(ref)),
                     cos_vs_v4=round(cos(y, v4), 6)))
with open(os.path.join(R, "accuracy.csv"), "w", newline="") as fo:
    w = csv.DictWriter(fo, fieldnames=list(rows[0].keys()))
    w.writeheader()
    for r in rows:
        w.writerow(r)
for r in rows:
    print(r)
