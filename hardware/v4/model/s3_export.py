#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Exports a network for the CPU reference runner (firmware/esp32/v4_s3_bench,
v4net.cpp): the same network, parameter pack and input the FPGA runs, plus
the expected INT8 output, in one file net.bin.

  s3_export.py <net> <pack> <net.bin> [--image img.bin]

<net>   a v4_plan.py example name or a Python file with NET = [...]
<pack>  parameter pack (MFNP), e.g. v4_qat.export_pack
--image INT8 HWC input of the network's size (default: zeros)

The expected output is v4_ref.run_net (true channel counts), the same
values the FPGA writes (v4_compile golden, before its zero padding to
16-channel groups): the S3 run must reproduce it bit for bit.
"""
import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v4_compile  # noqa: E402
import v4_plan as V  # noqa: E402
import v4_ref as R  # noqa: E402

TYPES = {V.Conv1: 0, V.Conv3: 1, V.PW: 2, V.Linear: 3, V.DWPW: 4, V.GDConv: 5, V.Pool: 6, V.Upsample: 7, V.Concat: 8}


def layer_rec(L, i):
    t = TYPES[type(L)]
    stride = getattr(L, "stride", 1)
    res = int(bool(getattr(L, "residual", False)))
    cout = getattr(L, "cout", 0)
    if isinstance(L, V.Concat):        # source layer (absolute index) in the cout field
        return struct.pack("<BBBBHBBBBBB", t, 1, 0, 0, L.ref(i), 0, 0, 0, 0, 0, 0)
    if isinstance(L, V.Pool):
        return struct.pack("<BBBBHBBBBBB", t, L.stride, 0, L.pad, 0, int(L.kind == "max"), L.k, L.mul, L.sh, 0, 0)
    return struct.pack("<BBBBHBBBBBB", t, stride, res, 0, cout, 0, 0, 0, 0, 0, 0)


def export(net, pack, img, path):
    (h, w, c), layers = V.split_input(net)
    outs, _ = R.run_net(net, pack, img)
    out = outs[-1].reshape(-1).astype(np.int8)
    body = b"".join(layer_rec(L, i) for i, L in enumerate(layers))
    hdr = b"V4S3" + struct.pack("<IIHHHHIII", 1, len(layers), h, w, c, 0, len(pack), img.size, out.size)
    open(path, "wb").write(hdr + body + pack + img.astype(np.int8).tobytes() + out.tobytes())
    return out


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    net = v4_compile.load_net(argv[0])
    pack = open(argv[1], "rb").read()
    shape, _ = V.split_input(net)
    img = np.zeros(shape, np.int8)
    if len(argv) == 5 and argv[3] == "--image":
        img = np.frombuffer(open(argv[4], "rb").read(), np.int8).reshape(shape)
    out = export(net, pack, img, argv[2])
    # the FPGA output (compiler golden) must be the same values
    o = v4_compile.build(net, pack, img)
    g = o["golden"].astype(np.int8)
    mask = np.zeros(g.size, bool)
    mask[o["out_index"]] = True
    if (g[o["out_index"]] != out).any() or (g[~mask] != 0).any():
        print("ERROR: v4_ref and v4_compile disagree")
        return 1
    print("%s: %d layers, input %dx%dx%d, output %d values (= FPGA golden)" %
          (argv[2], len(V.split_input(net)[1]), shape[0], shape[1], shape[2], out.size))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
