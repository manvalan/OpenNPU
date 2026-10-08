#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Exports a v4 benchmark network to ONNX and quantizes it for ESP-DL.

  export_espdl.py NET OUTDIR [--target esp32s3]

NET is a hardware/v4/model/v4_plan.py example (bench_small, bench_medium,
bench_heavy, mfn). The model is v4_qat.random_model(NET): the same seeded,
calibrated random model whose INT8 pack is in ../esp32s3_v4/nets/NET/net.bin
(checked: identical, or at most 1 byte in
10,000 different from float rounding on another machine; reported). Its float form (BatchNorm folded) is rebuilt with
standard layers (Conv, ReLU, PRelu, pooling, Add, Concat, Resize) and
exported to OUTDIR/model.onnx, then ESP-PPQ quantizes it (8 bit, per-tensor
power-of-two exponents, Espressif's own rounding) into OUTDIR/model.espdl.

OUTDIR/meta.json keeps what the S3 app and compare.py need: input shape,
the v4 input exponent (-6) and output exponent, the float output and the
v4 INT8 output (the FPGA's) of the net.bin input image.
Needs torch, onnx, onnxruntime, esp-ppq (see README.md).
"""
import argparse
import json
import os
import struct
import sys

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.path.join(HERE, "..", "..", "hardware", "v4", "model")
sys.path.insert(0, MODEL)
import v4_qat as Q  # noqa: E402
import v4_plan as V  # noqa: E402


class FloatNet(nn.Module):
    """QNet's float forward with standard ONNX ops (output NCHW, not flattened)"""

    def __init__(self, q):
        super().__init__()
        self.prog = q.prog
        self.convs = nn.ModuleList()
        self.acts = nn.ModuleList()
        for L in q.layers:
            pad = {"conv1": 1, "conv3": 1, "pw": 0, "dw": 1, "gd": 0}[L.kind]
            c = nn.Conv2d(L.cin, L.cout, L.k, L.stride, pad, groups=L.groups, bias=True)
            with torch.no_grad():
                c.weight.copy_(L.weight)
                c.bias.copy_(L.bias)
            self.convs.append(c)
            if L.act == "relu":
                a = nn.ReLU()
            elif L.act == "prelu":
                a = nn.PReLU(L.cout)
                with torch.no_grad():
                    a.weight.copy_(L.alpha)
            else:
                a = nn.Identity()
            self.acts.append(a)

    def forward(self, x):
        ins, outs = [], []
        for kind, idx, res in self.prog:
            ins.append(x)
            if kind == "pool":
                P = idx
                if P.kind == "max":
                    x = F.max_pool2d(x, P.k, P.stride, P.pad)
                else:
                    x = F.avg_pool2d(x, P.k, P.stride, P.pad, count_include_pad=True) * (P.k * P.k * P.mul / 2.0 ** P.sh)
            elif kind == "up":
                x = F.interpolate(x, scale_factor=2, mode="nearest")
            elif kind == "cat":
                x = torch.cat([x, outs[idx]], 1)
            else:
                y = x
                for k in idx:
                    y = self.acts[k](self.convs[k](y))
                if res:
                    y = y + ins[-2]
                x = y
            outs.append(x)
        return x


def netbin_parts(path):
    b = open(path, "rb").read()
    n = struct.unpack_from("<I", b, 8)[0]
    h, w, c = struct.unpack_from("<HHH", b, 12)
    pack_len, img_len, out_len = struct.unpack_from("<III", b, 20)
    p = 32 + 12 * n
    return (h, w, c), b[p:p + pack_len], b[p + pack_len:p + pack_len + img_len], b[p + pack_len + img_len:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("net")
    ap.add_argument("outdir")
    ap.add_argument("--target", default="esp32s3")
    ap.add_argument("--calib", type=int, default=32, help="random calibration images")
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)

    q, imgs = Q.random_model(a.net)
    # same model as the measured net.bin?
    (h, w, c), pack, img, expected = netbin_parts(os.path.join(HERE, "..", "esp32s3_v4", "nets", a.net, "net.bin"))
    tmp = os.path.join(a.outdir, "model.pack")
    Q.export_pack(q, tmp)
    mine = open(tmp, "rb").read()
    os.remove(tmp)
    ndiff = sum(x != y for x, y in zip(mine, pack)) if len(mine) == len(pack) else -1
    # a few bytes may differ from the net.bin made on another machine: float
    # rounding of values on a .5 boundary in calibration (torch version / CPU)
    print("%s: parameter pack vs net.bin: %d of %d bytes differ" % (a.net, ndiff, len(pack)))
    if ndiff < 0 or ndiff > len(pack) // 10000:
        sys.exit("random_model(%s) does not match net.bin's parameter pack" % a.net)
    x_int = torch.tensor(np.frombuffer(img, np.int8).reshape(h, w, c).astype(np.float64)).permute(2, 0, 1)[None]
    if not torch.equal(x_int[0].to(torch.int64), Q.to_int_image(imgs[0]).to(torch.int64)):
        sys.exit("net.bin input is not the first calibration image")
    x_real = (x_int * 2.0 ** Q.E_IN).float()

    f = FloatNet(q).eval()
    with torch.no_grad():       # same graph? compared in float64 (no summation-order noise)
        ref = q.double()(x_real.double()).numpy().reshape(-1)       # QNet float (HWC flatten)
        y64 = FloatNet(q).double().eval()(x_real.double())
        err = float(np.abs(ref - y64.permute(0, 2, 3, 1).reshape(-1).numpy()).max())
        q.float()
        y = f(x_real)
        mine = y.permute(0, 2, 3, 1).reshape(-1).numpy()
    print("%s: FloatNet vs QNet float (float64) max diff %.2e, output %s" % (a.net, err, tuple(y.shape)))
    if err > 1e-9:
        sys.exit("FloatNet does not reproduce the QNet float forward")

    onnx_path = os.path.join(a.outdir, "model.onnx")
    torch.onnx.export(f, x_real, onnx_path, input_names=["input"], output_names=["output"],
                      opset_version=13, dynamo=False)

    from esp_ppq.api import espdl_quantize_onnx
    g = torch.Generator().manual_seed(7)
    calib = [x_real[0]] + [torch.rand(c, h, w, generator=g) * 2 - 1 for _ in range(a.calib - 1)]
    espdl = os.path.join(a.outdir, "model.espdl")
    espdl_quantize_onnx(onnx_import_file=onnx_path, espdl_export_file=espdl,
                        calib_dataloader=torch.utils.data.DataLoader(calib, batch_size=1),
                        calib_steps=len(calib), input_shape=[1, c, h, w], inputs=[x_real],
                        target=a.target, num_of_bits=8, device="cpu", error_report=True,
                        export_test_values=True, verbose=0)

    meta = dict(net=a.net, target=a.target, input_hwc=[h, w, c], e_in_v4=Q.E_IN,
                e_out_v4=q.layers[-1].e_out, output_nchw=list(y.shape),
                float_output_hwc=[float(v) for v in mine],
                v4_output_int8=[int(v) for v in np.frombuffer(expected, np.int8)],
                calib_images=len(calib), torch=torch.__version__, pack_bytes_differing_from_netbin=ndiff)
    json.dump(meta, open(os.path.join(a.outdir, "meta.json"), "w"), indent=1)
    print("wrote", onnx_path, espdl, "meta.json")


if __name__ == "__main__":
    main()
