#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Static INT8 quantization of the ONNX models made by
../../espdl_v4/export_espdl.py, for ONNX Runtime (QDQ format, per-channel
int8 weights, int8 activations, MinMax calibration on the same images as
ESP-PPQ: the net.bin input + seeded random images).

  quantize_ort.py NET     -> ../../espdl_v4/models/NET/model_ort_int8.onnx
Needs onnxruntime, numpy, torch (venv of ../../espdl_v4/README.md).
"""
import json
import os
import struct
import sys

import numpy as np
import torch
from onnxruntime.quantization import CalibrationDataReader, QuantFormat, QuantType, quantize_static

HERE = os.path.dirname(os.path.abspath(__file__))
M = os.path.join(HERE, "..", "..", "espdl_v4", "models")


def netbin_input(net):
    b = open(os.path.join(HERE, "..", "..", "esp32s3_v4", "nets", net, "net.bin"), "rb").read()
    n = struct.unpack_from("<I", b, 8)[0]
    h, w, c = struct.unpack_from("<HHH", b, 12)
    pack_len, img_len = struct.unpack_from("<II", b, 20)
    p = 32 + 12 * n + pack_len
    img = np.frombuffer(b[p:p + img_len], np.int8).reshape(h, w, c).astype(np.float32) * 2.0 ** -6
    return img.transpose(2, 0, 1)[None], (h, w, c)


class Reader(CalibrationDataReader):
    def __init__(self, net, n=32):
        x, (h, w, c) = netbin_input(net)
        g = torch.Generator().manual_seed(7)     # same images as export_espdl.py
        self.data = [x] + [(torch.rand(c, h, w, generator=g) * 2 - 1).numpy()[None] for _ in range(n - 1)]
        self.it = iter(self.data)

    def get_next(self):
        v = next(self.it, None)
        return None if v is None else {"input": v.astype(np.float32)}


net = sys.argv[1]
src = os.path.join(M, net, "model.onnx")
dst = os.path.join(M, net, "model_ort_int8.onnx")
quantize_static(src, dst, Reader(net), quant_format=QuantFormat.QDQ, per_channel=True,
                activation_type=QuantType.QInt8, weight_type=QuantType.QInt8)
print("wrote", dst)
