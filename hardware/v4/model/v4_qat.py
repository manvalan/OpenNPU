#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Quantization-aware training (QAT) for the v4 accelerator, in PyTorch,
and export of a parameter pack that gen_mfn.c / the FPGA run bit-exactly.

  v4_qat.py --selftest [gen_mfn] [--net NAME] [--out DIR]
                                   random model -> calibrate -> pack; checks
                                   that PyTorch, v4_ref.py, v4_compile.py (and
                                   gen_mfn, for MobileFaceNet) give the same
                                   INT8 output; NAME = a v4_plan.py example
                                   (default mfn); DIR keeps the v4_compile.py
                                   files of the first image (RTL bench input)
  v4_qat.py --pack NAME DIR        random calibrated model of a v4_plan.py
                                   example (as --selftest) -> DIR/model.pack
                                   and DIR/img.bin (its INT8 input): test
                                   models for the FPGA and the S3 bench
  v4_qat.py --demo [gen_mfn]       toy end-to-end run: float training, QAT,
                                   export, accuracy of the INT8 model checked
                                   with the hardware arithmetic

QNet builds the model from any v4_plan.py layer list (the same list
v4_compile.py compiles); MobileFaceNetV4() is QNet on MobileFaceNet in
gen_mfn.c's layer order. Every layer
has two forwards:
  float : ordinary convolution + bias + activation (training from scratch)
  quant : the v4 integer arithmetic (requant_act.v): INT8 activations at a
          power-of-two exponent, INT8 weights, INT32 bias, shift with round
          half up, saturation, PReLU with an INT8 slope and shift ash,
          saturating residual add. Rounding and clamping use the
          straight-through estimator, so the same code trains (QAT) and,
          in float64, reproduces the hardware integers exactly.
BatchNorm is used in float training only: calibrate() folds it into the
convolution weights and biases (the hardware has no BatchNorm).
Exponents (per tensor, powers of two, like ESP-DL) are chosen by
calibrate() from the float model and then kept fixed during QAT.
Needs torch and numpy.
"""
import math
import os
import struct
import subprocess
import sys
import tempfile

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v4_compile  # noqa: E402
import v4_plan as V  # noqa: E402
import v4_ref  # noqa: E402

E_IN = -6           # input image exponent (espdl_to_v4.image_to_int8)
ACT = {"none": 0, "relu": 1, "prelu": 2}


def floor_ste(v):
    return v + (torch.floor(v) - v).detach()


def rnd(v):
    """round half up, straight-through gradient"""
    return floor_ste(v + 0.5)


def sat8(v):
    return torch.clamp(v, -128, 127)


def exp_for(maxabs):
    """smallest exponent e with maxabs <= 127 * 2^e"""
    return math.ceil(math.log2(max(float(maxabs), 1e-12) / 127))


class QLayer(nn.Module):
    """one v4 layer: kind conv1 (3x3 s1/s2 on the image), conv3 (dense 3x3
    s1/s2 on a feature map), pw, dw (3x3), gd
    (global depthwise over a gd = (h, w) map, or gd x gd)."""

    def __init__(self, kind, cin, cout, act, stride=1, gd=7):
        super().__init__()
        self.kind, self.cin, self.cout, self.act, self.stride = kind, cin, cout, act, stride
        k, groups = {"conv1": (3, 1), "conv3": (3, 1), "pw": (1, 1), "dw": (3, cout), "gd": (gd, cout)}[kind]
        kh, kw = k if isinstance(k, tuple) else (k, k)
        self.k, self.groups = (kh, kw), groups
        fan_in = (cin // groups) * kh * kw
        self.weight = nn.Parameter(torch.randn(cout, cin // groups, kh, kw) * math.sqrt(1.0 / fan_in))
        self.bias = nn.Parameter(torch.zeros(cout))
        self.alpha = nn.Parameter(torch.full((cout,), 0.25)) if act == "prelu" else None
        self.bn = nn.BatchNorm2d(cout)      # float training only; fold_bn() merges it into weight/bias
        self.e_in = self.e_w = self.e_out = None     # set by calibrate()
        self.ash = 7
        self.maxabs = 0.0

    def conv(self, x, w):
        pad = {"conv1": 1, "conv3": 1, "pw": 0, "dw": 1, "gd": 0}[self.kind]
        return F.conv2d(x, w, None, self.stride, pad, 1, self.groups)

    def forward_float(self, x):
        y = self.conv(x, self.weight) + self.bias.view(1, -1, 1, 1)
        if self.bn is not None:
            y = self.bn(y)
        self.maxabs = max(self.maxabs, float(y.detach().abs().max()))   # pre-activation range
        if self.act == "relu":
            y = F.relu(y)
        elif self.act == "prelu":
            y = torch.where(y >= 0, y, y * self.alpha.view(1, -1, 1, 1))
        return y

    @torch.no_grad()
    def fold_bn(self):
        """W' = W*g/s, b' = beta + (b - mu)*g/s with s = sqrt(var + eps); then no BN"""
        if self.bn is None:
            return
        bn = self.bn
        k = bn.weight / torch.sqrt(bn.running_var + bn.eps)
        self.weight.mul_(k.view(-1, 1, 1, 1))
        self.bias.copy_(bn.bias + (self.bias - bn.running_mean) * k)
        self.bn = None

    # ---- integer (hardware) arithmetic ----
    @property
    def sh(self):
        return self.e_out - (self.e_in + self.e_w)

    def qweight(self):
        return sat8(rnd(self.weight * 2.0 ** -self.e_w))

    def qbias(self):
        return rnd(self.bias * 2.0 ** -(self.e_in + self.e_w))

    def qalpha(self):
        return sat8(rnd(self.alpha * 2.0 ** self.ash))

    def forward_quant(self, xq):
        """xq: integer-valued tensor at exponent e_in -> integer tensor at e_out"""
        acc = self.conv(xq, self.qweight()) + self.qbias().view(1, -1, 1, 1)
        q = sat8(floor_ste(acc * 2.0 ** -self.sh + (0.5 if self.sh > 0 else 0.0)))
        if self.act == "relu":
            q = torch.clamp(q, min=0)
        elif self.act == "prelu":
            p = q * self.qalpha().view(1, -1, 1, 1)
            p = sat8(floor_ste(p * 2.0 ** -self.ash + (0.5 if self.ash > 0 else 0.0)))
            q = torch.where(q < 0, p, q)
        return q


class QNet(nn.Module):
    """any network of v4_plan.py layers (Conv1, Conv3, PW, DWPW, GDConv, Linear),
    in the order v4_compile.py / v4_ref.run_net expect the pack records.
    DWPW = two QLayers (dw, then pw); its residual adds the input of the
    previous network layer (the block input)."""

    def __init__(self, net):
        super().__init__()
        L, self.prog = [], []           # prog: (kind, [qlayer indices], residual)
        (h, w, c), layers = V.split_input(net)
        self.in_shape = (c, h, w)
        chans = []                      # output channels of every layer (Concat)
        for item in layers:
            if isinstance(item, V.Conv1):
                self.prog.append(("seq", [len(L)], False))
                L.append(QLayer("conv1", c, item.cout, item.act, item.stride))
                h, w, c = -(-h // item.stride), -(-w // item.stride), item.cout
            elif isinstance(item, V.Conv3):
                self.prog.append(("seq", [len(L)], item.residual))
                L.append(QLayer("conv3", c, item.cout, item.act, item.stride))
                h, w, c = -(-h // item.stride), -(-w // item.stride), item.cout
            elif isinstance(item, (V.PW, V.Linear)):
                if isinstance(item, V.PW) and item.residual:
                    raise ValueError("a 1x1 cannot add its own input (same bank as the pass input)")
                self.prog.append(("seq", [len(L)], False))
                L.append(QLayer("pw", c, item.cout, item.act))
                c = item.cout
            elif isinstance(item, V.DWPW):
                self.prog.append(("seq", [len(L), len(L) + 1], item.residual))
                L += [QLayer("dw", c, c, item.dw_act, item.stride), QLayer("pw", c, item.cout, item.pw_act)]
                h, w, c = -(-h // item.stride), -(-w // item.stride), item.cout
            elif isinstance(item, V.Pool):
                self.prog.append(("pool", item, False))
                h, w = item.out(h, w)
            elif isinstance(item, V.Upsample):
                self.prog.append(("up", item, False))
                h, w = 2 * h, 2 * w
            elif isinstance(item, V.Concat):
                j = item.ref(len(self.prog))
                self.prog.append(("cat", j, False))
                c = c + chans[j]
            elif isinstance(item, V.GDConv):
                self.prog.append(("seq", [len(L)], False))
                L.append(QLayer("gd", c, c, item.act, gd=(h, w)))
                h = w = 1
            chans.append(c)
        self.layers = nn.ModuleList(L)
        self.net = net
        self.emb = c
        self.quant = False

    def forward(self, x):
        """x: [N, C, H, W] (the network's Input size, default 3x112x112, BGR). float mode: real values ((p-127.5)/127.5);
        quant mode: the INT8 image (integers at exponent E_IN). Returns the
        output: real values (float) or integers at layers[-1].e_out (quant)."""
        f = (lambda L, v: L.forward_quant(v)) if self.quant else (lambda L, v: L.forward_float(v))
        ins, outs = [], []
        for kind, idx, res in self.prog:
            ins.append(x)
            if kind == "pool":
                x = pool_t(x, idx, self.quant)
                outs.append(x)
                continue
            if kind == "up":
                x = F.interpolate(x, scale_factor=2, mode="nearest")
                outs.append(x)
                continue
            if kind == "cat":
                x = torch.cat([x, outs[idx]], 1)
                outs.append(x)
                continue
            y = x
            for k in idx:
                y = f(self.layers[k], y)
            if res:
                y = sat8(y + ins[-2]) if self.quant else y + ins[-2]
            x = y
            outs.append(x)
        return x.permute(0, 2, 3, 1).flatten(1)       # HWC order (v4_ref, the FPGA)

    def producer(self, n):
        """qlayer index whose output is prog entry n's output (through
        pooling / upsampling / concatenation), None = the network input"""
        while n >= 0 and self.prog[n][0] != "seq":
            n -= 1
        return self.prog[n][1][-1] if n >= 0 else None

    def tied_cat(self):
        """{qlayer index: qlayer index (None = input)}: a concatenation adds
        no rescale, so the map before it takes the exponent of the map it
        is concatenated with"""
        t = {}
        for n, (kind, idx, res) in enumerate(self.prog):
            if kind == "cat":
                k, q = self.producer(n - 1), self.producer(idx)
                if k == q:
                    continue
                if k is None or (q is not None and q > k):
                    raise ValueError("Concat at layer %d: cannot match the exponents" % n)
                t[k] = q
        return t

    def tied(self):
        """{qlayer index of a residual block output: qlayer index whose input is the block input}"""
        t = {}
        for n, (kind, idx, res) in enumerate(self.prog):
            if res:
                if self.prog[n - 1][0] != "seq":
                    raise ValueError("residual block: the previous layer must be a weight layer, not a pooling")
                t[idx[-1]] = self.prog[n - 1][1][0]
        return t


def pool_t(x, L, quant):
    """v4_plan.Pool on [N, C, H, W]: max (padding ignored) or sum of the
    k*k taps (zero padding) times mul / 2^sh; quant: the pool_unit.v
    integers (round half up, saturation), float: the same scale, no
    rounding. The exponent does not change."""
    if L.kind == "max":
        y = F.max_pool2d(x, L.k, L.stride, L.pad)
        return y
    s = F.avg_pool2d(x, L.k, L.stride, L.pad, count_include_pad=True) * (L.k * L.k)
    y = s * (L.mul / 2.0 ** L.sh)
    if quant:
        y = sat8(floor_ste(y + (0.5 if L.sh > 0 else 0.0)))
    return y


def MobileFaceNetV4(emb=128, act="prelu", cfg=None):
    """MobileFaceNet in gen_mfn.c's layer order (the topology gen_mfn knows)."""
    return QNet(V.mobilefacenet(emb, act=act) if cfg is None else V.mobilefacenet(emb, cfg, act))


@torch.no_grad()
def calibrate(model, images):
    """choose every exponent from the float model on `images` (real values).
    Residual adds force the block output's exponent to the block input's
    (the hardware adds the INT8 values directly)."""
    model.quant = False
    model.eval()
    for L in model.layers:
        L.fold_bn()
        L.maxabs = 0.0
    model(images)
    L = model.layers
    tied = model.tied()
    tcat = model.tied_cat()
    for k in tcat:
        if k in tied:
            raise ValueError("qlayer %d: residual and concatenation exponents both forced" % k)
    forced = set(tied) | set(tcat)
    first = {}              # first qlayer of a layer -> producer of its input map (None = input)
    for n, (kind, idx, res) in enumerate(model.prog):
        if kind == "seq":
            first[idx[0]] = model.producer(n - 1)
    for k, layer in enumerate(L):
        if k in first:      # pooling / upsampling / concatenation keep the exponent
            layer.e_in = E_IN if first[k] is None else L[first[k]].e_out
        else:               # second qlayer of a DWPW
            layer.e_in = L[k - 1].e_out
        layer.e_w = exp_for(layer.weight.abs().max())
        layer.e_out = exp_for(layer.maxabs)
        if k in tied:
            layer.e_out = L[tied[k]].e_in               # = block input exponent
        if k in tcat:
            layer.e_out = E_IN if tcat[k] is None else L[tcat[k]].e_out
        if layer.sh < 0:                                # output finer than the accumulator LSB
            if k in forced:
                layer.e_w = layer.e_out - layer.e_in    # finer weights (may saturate a few)
            else:
                layer.e_out = layer.e_in + layer.e_w
        if layer.sh > 31:
            raise ValueError("layer %d: shift %d > 31" % (k, layer.sh))
        if layer.alpha is not None:
            a = float(layer.alpha.abs().max())
            layer.ash = 7
            while layer.ash > 0 and a * 2 ** layer.ash > 127:
                layer.ash -= 1


def export_pack(model, path):
    """write the MFNP parameter pack (v4_compile.py, gen_mfn.c --params, v4_ref)"""
    out = bytearray(b"MFNP" + struct.pack("<III", 1, model.emb, len(model.layers)))
    with torch.no_grad():
        for L in model.layers:
            w = L.qweight().to(torch.int64)
            b = L.qbias().to(torch.int64)
            if b.abs().max() >= 2 ** 31:
                raise ValueError("bias does not fit INT32")
            a = L.qalpha().to(torch.int64) if L.alpha is not None else torch.zeros(L.cout, dtype=torch.int64)
            if L.kind == "conv1":   # rows k = (kr*3+kc)*C+ch, 9C -> 16*ng (27 -> 32 for C = 3)
                kind, cin = 0, 16 * V.conv1_ng(L.cin)
                ww = torch.cat([w.permute(0, 2, 3, 1).reshape(L.cout, 9 * L.cin),
                                torch.zeros(L.cout, cin - 9 * L.cin, dtype=torch.int64)], 1)
            elif L.kind == "conv3":   # [cout][(kr*3+kc)*cin + ci] (conv3_feeder.v order)
                kind, cin, ww = 3, L.cin, w.permute(0, 2, 3, 1).reshape(L.cout, 9 * L.cin)
            elif L.kind == "pw":
                kind, cin, ww = 0, L.cin, w.reshape(L.cout, L.cin)
            elif L.kind == "dw":
                kind, cin, ww = 1, L.cin, w.reshape(L.cout, 9)
            else:                   # gd: [kr*k+kc][ch]
                kind, cin, ww = 2, L.cin, w.reshape(L.cout, L.k[0] * L.k[1]).t()
            out += struct.pack("<BBBBHH", kind, ACT[L.act], L.sh, L.ash if L.alpha is not None else 0, cin, L.cout)
            out += struct.pack("<%db" % ww.numel(), *ww.reshape(-1).tolist())
            out += struct.pack("<%di" % L.cout, *b.tolist())
            out += struct.pack("<%db" % L.cout, *a.tolist())
    open(path, "wb").write(bytes(out))


def to_int_image(real):
    """real BGR image in [-1, 1] -> INT8 at E_IN, same rounding as espdl_to_v4.image_to_int8"""
    return sat8(torch.floor(real * 2.0 ** -E_IN + 0.5))


def hw_check(model, img_int, gen_mfn=None, outdir=None):
    """INT8 output of PyTorch (quant, float64) vs v4_ref.py vs v4_compile.py
    (and gen_mfn for MobileFaceNet, if its path is given). outdir: keep the
    v4_compile.py files there (for the RTL bench). -> (mismatches, values)"""
    with tempfile.TemporaryDirectory() as d:
        pack = os.path.join(d, "model.pack")
        export_pack(model, pack)
        model.quant = True
        with torch.no_grad():
            pt = model.double()(img_int.double().unsqueeze(0)).reshape(-1).to(torch.int64).numpy()
        model.float()
        hwc = img_int.permute(1, 2, 0).to(torch.int8).numpy()
        outs, _ = v4_ref.run_net(model.net, open(pack, "rb").read(), hwc)
        ref = outs[-1].reshape(-1).astype(np.int64)
        bad = int((pt != ref).sum())
        o = v4_compile.build(model.net, open(pack, "rb").read(), hwc)
        if outdir:
            v4_compile.write(o, outdir)
        g = o["golden"].astype(np.int64)        # hardware output: padded to 16-channel groups with zeros
        mask = np.zeros(g.size, bool)
        mask[o["out_index"]] = True
        bad += int((g[o["out_index"]] != ref).sum()) + int((g[~mask] != 0).sum())
        if gen_mfn:
            open(os.path.join(d, "img.bin"), "wb").write(hwc.tobytes())
            subprocess.run([gen_mfn, d, "--params", pack, "--image", os.path.join(d, "img.bin")],
                           check=True, capture_output=True)
            g = np.array([int(v) for v in open(os.path.join(d, "golden_ref.txt")).read().split(":")[1].split()])
            bad += int((g != ref).sum())
        return bad, pt


def toy_batch(n, gen):
    """2-class toy data: horizontal or vertical stripes of random period and
    phase, plus noise; real-valued BGR images in [-1, 1]."""
    y = torch.randint(0, 2, (n,), generator=gen)
    r = torch.arange(112).float()
    per = torch.randint(6, 20, (n,), generator=gen).float().view(n, 1)
    ph = torch.rand(n, 1, generator=gen) * 6.28
    wave = torch.sin(r.view(1, -1) / per * 6.28 + ph)               # [n, 112]
    img = torch.where(y.view(n, 1, 1) == 0, wave.view(n, 112, 1).expand(n, 112, 112),
                      wave.view(n, 1, 112).expand(n, 112, 112))
    img = img.unsqueeze(1).expand(n, 3, 112, 112) * 0.6 + torch.randn(n, 3, 112, 112, generator=gen) * 0.3
    return img.clamp(-1, 1), y


def selftest(gen_mfn=None, net="mfn", outdir=None):
    model, imgs = random_model(net)
    if net not in ("mfn", "mfn512"):
        gen_mfn = None
    total = 0
    for k in range(4):
        bad, _ = hw_check(model, to_int_image(imgs[k]), gen_mfn, outdir if k == 0 else None)
        total += bad
        print("image %d: %d mismatches (PyTorch vs v4_ref.py vs v4_compile.py%s)" % (k, bad, " vs gen_mfn" if gen_mfn else ""))
    print("shifts:", [L.sh for L in model.layers])
    return 1 if total else 0


def random_model(net):
    """random model with non-trivial BatchNorm, calibrated on 4 random
    inputs -> (model, real-valued inputs)"""
    torch.manual_seed(1)
    model = QNet(V.EXAMPLES[net][0]())
    imgs = torch.rand(4, *model.in_shape) * 2 - 1
    with torch.no_grad():
        model.train()
        for L in model.layers:
            L.bn.momentum = 1.0
            L.bn.weight.uniform_(0.5, 1.5)
            L.bn.bias.uniform_(-0.2, 0.2)
        model(imgs)
    calibrate(model, imgs)
    return model, imgs


def write_pack(net, outdir):
    os.makedirs(outdir, exist_ok=True)
    model, imgs = random_model(net)
    export_pack(model, os.path.join(outdir, "model.pack"))
    img = to_int_image(imgs[0]).permute(1, 2, 0).to(torch.int8).numpy()
    open(os.path.join(outdir, "img.bin"), "wb").write(img.tobytes())
    print("%s: model.pack + img.bin (%dx%dx%d) in %s" % (net, img.shape[0], img.shape[1], img.shape[2], outdir))
    return 0


def demo(gen_mfn=None, float_steps=60, qat_steps=30):
    torch.manual_seed(0)
    gen = torch.Generator().manual_seed(0)
    model = MobileFaceNetV4(128)
    opt = torch.optim.Adam(model.parameters(), 1e-3)

    def step(quant):
        x, y = toy_batch(16, gen)
        model.quant = quant
        if quant:
            x = to_int_image(x)
        out = model(x)
        logits = out[:, :2] * (2.0 ** model.layers[-1].e_out if quant else 1.0)
        loss = F.cross_entropy(logits, y)
        opt.zero_grad()
        loss.backward()
        opt.step()
        return loss.item()

    def accuracy(quant, n=200):
        g = torch.Generator().manual_seed(123)
        x, y = toy_batch(n, g)
        model.quant = quant
        model.eval()
        with torch.no_grad():
            out = model(to_int_image(x) if quant else x)
        model.train()
        return float((out[:, :2].argmax(1) == y).float().mean()), x

    model.train()
    for s in range(float_steps):
        loss = step(False)
        if s % 10 == 9:
            print("float step %3d  loss %.3f" % (s + 1, loss))
    acc_f, _ = accuracy(False)
    calibrate(model, toy_batch(64, torch.Generator().manual_seed(7))[0])
    acc_q0, _ = accuracy(True)
    print("float accuracy %.3f; INT8 after calibration only (PTQ) %.3f" % (acc_f, acc_q0))
    opt = torch.optim.Adam(model.parameters(), 2e-4)
    for s in range(qat_steps):
        loss = step(True)
        if s % 10 == 9:
            print("QAT   step %3d  loss %.3f" % (s + 1, loss))
    acc_q, x = accuracy(True)
    print("INT8 accuracy after QAT %.3f (PyTorch, hardware arithmetic)" % acc_q)
    bad = 0
    for k in range(3):
        b, _ = hw_check(model, to_int_image(x[k]), gen_mfn)
        bad += b
    print("export check on 3 images: %d mismatches (PyTorch vs v4_ref.py vs v4_compile.py%s)" % (bad, " vs gen_mfn" if gen_mfn else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "--selftest":
        opt = {"--net": "mfn", "--out": None}
        pos = []
        k = 1
        while k < len(a):
            if a[k] in opt:
                opt[a[k]] = a[k + 1]
                k += 2
            else:
                pos.append(a[k])
                k += 1
        sys.exit(selftest(pos[0] if pos else None, opt["--net"], opt["--out"]))
    if a and a[0] == "--pack" and len(a) == 3:
        sys.exit(write_pack(a[1], a[2]))
    if a and a[0] == "--demo":
        sys.exit(demo(a[1] if len(a) > 1 else None))
    print(__doc__)
