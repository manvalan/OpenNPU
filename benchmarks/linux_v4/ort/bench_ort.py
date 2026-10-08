#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Runs an ONNX model with ONNX Runtime on the board (CPU execution
provider: on a Raspberry Pi 5, NEON int8/fp32 kernels), RUNS times per
thread count, on the v4 net.bin input image. Prints CSV<threads>,run,us,0
lines, a RESULT line per thread count and OUT,float32,0,<outputs>.

  bench_ort.py model.onnx net.bin [runs] [threads...]
"""
import struct
import sys
import time

import numpy as np
import onnxruntime as ort

model, netbin = sys.argv[1], sys.argv[2]
runs = int(sys.argv[3]) if len(sys.argv) > 3 else 10
threads = [int(t) for t in sys.argv[4:]] or [1, 4]
b = open(netbin, "rb").read()
n = struct.unpack_from("<I", b, 8)[0]
h, w, c = struct.unpack_from("<HHH", b, 12)
pack_len, img_len = struct.unpack_from("<II", b, 20)
p = 32 + 12 * n + pack_len
x = (np.frombuffer(b[p:p + img_len], np.int8).reshape(h, w, c).astype(np.float32) * 2.0 ** -6).transpose(2, 0, 1)[None].copy()
print("I ort %s, %s, input %dx%dx%d" % (ort.__version__, model, h, w, c))
out = None
for t in threads:
    o = ort.SessionOptions()
    o.intra_op_num_threads = t
    o.inter_op_num_threads = 1
    o.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    s = ort.InferenceSession(model, o, providers=["CPUExecutionProvider"])
    s.run(None, {"input": x})            # warm-up (first run builds kernels)
    best, tot = 1e30, 0.0
    for r in range(runs):
        t0 = time.perf_counter()
        out = s.run(None, {"input": x})[0]
        us = (time.perf_counter() - t0) * 1e6
        best, tot = min(best, us), tot + us
        print("CSV%d,%d,%d,0" % (t, r, round(us)))
    print("I RESULT %d threads: best %.3f ms, mean %.3f ms over %d runs" % (t, best / 1000, tot / 1000 / runs, runs))
print("OUT,float32,0," + ",".join("%.6g" % v for v in out.reshape(-1)))
