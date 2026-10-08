#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Bit-exact numpy model of the v4 hardware arithmetic, driven by a
parameter pack (the same "MFNP" file gen_mfn.c reads with --params).

  v4_ref.py pack image.bin                 prints the INT8 embedding
  v4_ref.py pack image.bin golden_ref.txt  compares with gen_mfn's output

It is the Python twin of gen_mfn.c (the C model of the RTL): same
requantization (round half up, saturation), same PReLU, same saturating
residual add, same im2col for conv1, same network order. It exists so a
Python training script can check, with the exact integer arithmetic of
the FPGA, what a quantized model will output once deployed (datasheet
chapter "Training"), and as the reference for the worked examples of
chapter "Progettare una rete".

The functions requant(), pw(), dw(), gdconv() work on any tensor shape;
only run_mfn() is tied to the MobileFaceNet topology that gen_mfn.c
builds (the pack records are read in that order).
Needs numpy.
"""
import struct
import sys

import numpy as np

KIND_PW, KIND_DW, KIND_GD, KIND_C3 = 0, 1, 2, 3
ACT_NONE, ACT_RELU, ACT_PRELU = 0, 1, 2


def sat8(v):
    return np.clip(v, -128, 127)


def requant(acc, bias, alpha, sh, ash, act):
    """requant_act.v / gen_mfn.c requant(): acc int64 [..., C] -> int8."""
    s = acc.astype(np.int64) + bias.astype(np.int64)
    if sh > 0:
        s = s + (1 << (sh - 1))
    q = sat8(s >> sh)                       # numpy >> on int64 = arithmetic shift
    if act == ACT_RELU:
        q = np.maximum(q, 0)
    elif act == ACT_PRELU:
        p = q * alpha.astype(np.int64)
        if ash > 0:
            p = p + (1 << (ash - 1))
        q = np.where(q < 0, sat8(p >> ash), q)
    return q.astype(np.int8)


def pw(x, L):
    """1x1 convolution, x [H, W, Cin] int8 -> [H, W, Cout] int8."""
    acc = x.astype(np.int64) @ L["w"].astype(np.int64).T
    return requant(acc, L["b"], L["a"], L["sh"], L["ash"], L["act"])


def dw(x, L, stride):
    """3x3 depthwise, pad 1, stride 1 or 2: out size = ceil(in size / stride)
    (gen_mfn.c dw_run for the even sizes of MobileFaceNet; dw_linebuf_grouped.v
    also emits the last row/column of an odd size)."""
    h, w, c = x.shape
    ho, wo = -(-h // stride), -(-w // stride)
    xp = np.pad(x.astype(np.int64), ((1, 1), (1, 1), (0, 0)))
    k = L["w"].astype(np.int64).reshape(c, 3, 3)
    acc = np.zeros((ho, wo, c), np.int64)
    for kr in range(3):
        for kc in range(3):
            acc += xp[kr:kr + stride * ho:stride, kc:kc + stride * wo:stride, :] * k[:, kr, kc]
    return requant(acc, L["b"], L["a"], L["sh"], L["ash"], L["act"])


def window9(x, stride):
    """[H,W,C] -> [ceil(H/s), ceil(W/s), 9*C]: the 3x3 window (pad 1) of
    every output position, k = (kr*3+kc)*C+ch (conv3_feeder.v order)"""
    h, w, c = x.shape
    ho, wo = -(-h // stride), -(-w // stride)
    xp = np.pad(x, ((1, 1), (1, 1), (0, 0)))
    col = np.zeros((ho, wo, 9 * c), x.dtype)
    for kr in range(3):
        for kc in range(3):
            k = (kr * 3 + kc) * c
            col[:, :, k:k + c] = xp[kr:kr + stride * ho:stride, kc:kc + stride * wo:stride, :]
    return col


def conv3(x, L, stride):
    """dense 3x3 convolution, pad 1, stride 1/2: x [H,W,Cin] -> [Ho,Wo,Cout];
    L["w"] [Cout, 9*Cin], k = (kr*3+kc)*Cin+ci"""
    return pw(window9(x, stride), L)


def pool(x, L):
    """pool_unit.v: max (taps outside the map ignored) or average (sum of
    the k*k taps, outside = 0) times mul / 2^sh, round half up, saturate.
    L: v4_plan.Pool."""
    h, w, c = x.shape
    ho, wo = L.out(h, w)
    k, s, p = L.k, L.stride, L.pad
    xi = x.astype(np.int64)
    acc = np.full((ho, wo, c), -128 if L.kind == "max" else 0, np.int64)
    for kr in range(k):
        for kc in range(k):
            for oi in range(ho):
                r = s * oi - p + kr
                if not 0 <= r < h:
                    continue
                cs = [s * oj - p + kc for oj in range(wo)]
                ok = [j for j, cc in enumerate(cs) if 0 <= cc < w]
                v = xi[r, [cs[j] for j in ok], :]
                if L.kind == "max":
                    acc[oi, ok, :] = np.maximum(acc[oi, ok, :], v)
                else:
                    acc[oi, ok, :] += v
    y = acc * L.mul
    if L.sh > 0:
        y = y + (1 << (L.sh - 1))
    return sat8(y >> L.sh).astype(np.int8)


def gdconv(x, L):
    """global depthwise (7x7 on a 7x7 map) -> [1, 1, C]."""
    h, w, c = x.shape
    k = L["w"].astype(np.int64).reshape(h * w, c)        # [kr*7+kc][ch]
    acc = (x.astype(np.int64).reshape(h * w, c) * k).sum(axis=0)
    return requant(acc, L["b"], L["a"], L["sh"], L["ash"], L["act"]).reshape(1, 1, c)


def res_add(y, x):
    """tile_writer.v residual: y = sat8(y + x)."""
    return sat8(y.astype(np.int16) + x.astype(np.int16)).astype(np.int8)


def read_records(data, pos, kind, cin, cout, npos=49):
    """one pack record at `pos` -> (layer dict, next pos); checks kind and sizes"""
    k, act, sh, ash, ci, co = struct.unpack_from("<BBBBHH", data, pos)
    if (k, ci, co) != (kind, cin, cout):
        raise ValueError("pack record at byte %d: kind %d %dx%d, network expects kind %d %dx%d" %
                         (pos, k, ci, co, kind, cin, cout))
    pos += 8
    nw = {KIND_PW: cin * cout, KIND_DW: cin * 9, KIND_GD: npos * cin, KIND_C3: 9 * cin * cout}[kind]
    w = np.frombuffer(data, np.int8, nw, pos); pos += nw
    b = np.frombuffer(data, "<i4", cout, pos); pos += 4 * cout
    a = np.frombuffer(data, np.int8, cout, pos); pos += cout
    if kind == KIND_PW:
        w = w.reshape(cout, cin)
    elif kind == KIND_C3:
        w = w.reshape(cout, 9 * cin)
    return dict(kind=kind, act=act, sh=sh, ash=ash, cin=cin, cout=cout, w=w, b=b, a=a), pos


def run_net(net, data, img):
    """any network of v4_plan layers (Conv1, Conv3, PW, DWPW, GDConv, Linear) with
    the parameter pack bytes `data`; img [H,W,C] int8 (the size given by
    the network's Input item, default 112x112x3).
    -> (outputs, records): outputs[i] = output tensor of layer i (for DWPW
    also outputs[i] is the 1x1 result, the depthwise one is in records)"""
    import v4_plan as V
    if data[:4] != b"MFNP":
        raise ValueError("not a parameter pack")
    shape, net = V.split_input(net)
    if tuple(img.shape) != shape:
        raise ValueError("image %s, network input %s" % (tuple(img.shape), shape))
    pos, x, outs, recs = 16, img, [], []      # without Conv1 the input is the first map
    ins = []
    for i, L in enumerate(net):
        ins.append(x)
        if isinstance(L, V.Conv1):
            R, pos = read_records(data, pos, KIND_PW, 16 * V.conv1_ng(img.shape[2]), L.cout)
            x = pw(im2col(img, L.stride), R)
            recs.append((R,))
        elif isinstance(L, V.Conv3):
            R, pos = read_records(data, pos, KIND_C3, x.shape[2], L.cout)
            y = conv3(x, R, L.stride)
            if L.residual:
                y = res_add(y, ins[i - 1])
            x = y
            recs.append((R,))
        elif isinstance(L, (V.PW, V.Linear)):
            R, pos = read_records(data, pos, KIND_PW, x.shape[2], L.cout)
            y = pw(x, R)
            if isinstance(L, V.PW) and L.residual:
                y = res_add(y, x)
            x = y
            recs.append((R,))
        elif isinstance(L, V.DWPW):
            c = x.shape[2]
            Rd, pos = read_records(data, pos, KIND_DW, c, c)
            Rp, pos = read_records(data, pos, KIND_PW, c, L.cout)
            d = dw(x, Rd, L.stride)
            y = pw(d, Rp)
            if L.residual:
                y = res_add(y, ins[i - 1])
            x = y
            recs.append((Rd, Rp, d))
        elif isinstance(L, V.Pool):
            x = pool(x, L)
            recs.append(())
        elif isinstance(L, V.Upsample):
            x = np.repeat(np.repeat(x, 2, axis=0), 2, axis=1)
            recs.append(())
        elif isinstance(L, V.Concat):
            r = outs[L.ref(i)]
            if r.shape[:2] != x.shape[:2]:
                raise ValueError("layer %d: Concat of %s and %s" % (i, x.shape, r.shape))
            x = np.concatenate([x, r], axis=2)
            recs.append(())
        elif isinstance(L, V.GDConv):
            h, w, c = x.shape
            R, pos = read_records(data, pos, KIND_GD, c, c, h * w)
            x = gdconv(x, R)
            recs.append((R,))
        outs.append(x)
    if pos != len(data):
        raise ValueError("pack has more records than the network")
    return outs, recs


def read_pack(path):
    data = open(path, "rb").read()
    if data[:4] != b"MFNP":
        raise ValueError("not a parameter pack")
    ver, emb, n = struct.unpack_from("<III", data, 4)
    pos, layers = 16, []
    for _ in range(n):
        kind, act, sh, ash, cin, cout = struct.unpack_from("<BBBBHH", data, pos)
        pos += 8
        nw = {KIND_PW: cin * cout, KIND_DW: cin * 9, KIND_GD: 49 * cin, KIND_C3: 9 * cin * cout}[kind]
        w = np.frombuffer(data, np.int8, nw, pos); pos += nw
        b = np.frombuffer(data, "<i4", cout, pos); pos += 4 * cout
        a = np.frombuffer(data, np.int8, cout, pos); pos += cout
        if kind == KIND_PW:
            w = w.reshape(cout, cin)
        layers.append(dict(kind=kind, act=act, sh=sh, ash=ash, cin=cin, cout=cout, w=w, b=b, a=a))
    if pos != len(data):
        raise ValueError("trailing bytes in pack")
    return emb, layers


def im2col(img, stride=2):
    """[H,W,C] -> [ceil(H/s), ceil(W/s), 16*ng], 3x3 pad 1,
    k = (kr*3+kc)*C+ch, 9C..16ng-1 = 0 (im2col_feeder.v); for 112x112x3
    stride 2 this is gen_mfn.c's conv1 vector (27 values + 5 zeros)."""
    import v4_plan as V
    h, w, c = img.shape
    ho, wo = -(-h // stride), -(-w // stride)
    xp = np.pad(img, ((1, 1), (1, 1), (0, 0)))
    col = np.zeros((ho, wo, 16 * V.conv1_ng(c)), np.int8)
    k = 0
    for kr in range(3):
        for kc in range(3):
            col[:, :, k:k + c] = xp[kr:kr + stride * ho:stride, kc:kc + stride * wo:stride, :]
            k += c
    return col


def im2col_conv1(img):
    """112x112x3 -> 56x56x32, k = (kr*3+kc)*3+ch, 27..31 = 0 (gen_mfn.c)."""
    xp = np.pad(img, ((1, 1), (1, 1), (0, 0)))
    col = np.zeros((56, 56, 32), np.int8)
    k = 0
    for kr in range(3):
        for kc in range(3):
            col[:, :, k:k + 3] = xp[kr:kr + 112:2, kc:kc + 112:2, :]
            k += 3
    return col


def run_mfn(layers, img, trace=None):
    """MobileFaceNet in the pack order of gen_mfn.c; img [112,112,3] int8."""
    it = iter(layers)

    def nxt(kind):
        L = next(it)
        if L["kind"] != kind:
            raise ValueError("pack order does not match MobileFaceNet")
        return L

    def t(name, v):
        if trace is not None:
            trace.append((name, v))
        return v

    x = t("conv1", pw(im2col_conv1(img), nxt(KIND_PW)))
    x = t("dw1", dw(x, nxt(KIND_DW), 1))
    x = t("b1.expand", pw(x, nxt(KIND_PW)))
    x = t("b1.dw", dw(x, nxt(KIND_DW), 2))
    x = t("b1.project", pw(x, nxt(KIND_PW)))
    cin = 64
    for tt, c, n, s in [(2, 64, 4, 1), (4, 128, 1, 2), (2, 128, 6, 1), (4, 128, 1, 2), (2, 128, 2, 1)]:
        for i in range(n):
            st = s if i == 0 else 1
            e = pw(x, nxt(KIND_PW))
            d = dw(e, nxt(KIND_DW), st)
            y = pw(d, nxt(KIND_PW))
            if st == 1 and cin == c:
                y = res_add(y, x)
            x, cin = t("bottleneck", y), c
    x = t("conv1x1", pw(x, nxt(KIND_PW)))
    x = t("gdconv", gdconv(x, nxt(KIND_GD)))
    x = t("linear", pw(x, nxt(KIND_PW)))
    return x.reshape(-1)


def main(argv):
    if len(argv) not in (2, 3):
        print(__doc__)
        return 2
    emb, layers = read_pack(argv[0])
    img = np.frombuffer(open(argv[1], "rb").read(), np.int8).reshape(112, 112, 3)
    e = run_mfn(layers, img)
    if len(argv) == 2:
        print("embedding (%d INT8):" % len(e), " ".join(str(v) for v in e))
        return 0
    ref = [int(v) for v in open(argv[2]).read().split(":")[1].split()]
    diff = sum(1 for a, b in zip(e, ref) if a != b) + abs(len(e) - len(ref))
    print("%d values, %d differences vs %s" % (len(e), diff, argv[2]))
    return 1 if diff else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
