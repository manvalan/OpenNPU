#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Converts a quantized ESP-DL MobileFaceNet (.espdl) into a v4 parameter
pack for gen_mfn.c (--params), and face images into the v4 INT8 input.

  espdl_to_v4.py model.espdl out.pack            write the parameter pack
  espdl_to_v4.py --image face.png out.img        112x112 aligned face -> INT8 input
  espdl_to_v4.py --ref model.espdl in.img        float reference embedding (numpy)

Mapping (datasheet section 12):
- every Conv (+ PRelu) becomes one gen_mfn layer, in graph order; Conv
  pairs that ESP-DL split along the output channels and joined again
  with Concat are merged back into one layer;
- the requantization shift is sh = e_out - (e_x + e_w), with e_out the
  exponent of the value the layer finally writes (after PRelu and
  Concat), so a PRelu whose output exponent differs from its input is
  folded into the convolution;
- PReLU slopes: ash = -e_alpha; slopes with ash > 7 (the descriptor
  field is 3 bits) are rescaled to ash 7 with rounding;
- merged Conv pairs whose weight exponents differ are brought to one
  exponent: exactly (x 2^d) when the weights fit in INT8, otherwise by
  rounding the finer half (reported);
- weights are stored by ESP-PPQ for the S3 as (N/16, H, W, C, 16) and
  are un-permuted here.
The residual Adds and Concats must keep their input exponents (checked).
Rounding: the v4 hardware rounds half up; ESP-DL's own int8 kernels may
round differently, so the v4 embedding is not expected to be bit-exact
with ESP-DL, only with gen_mfn.c (the C model of the hardware).
"""
import math
import struct
import sys

from espdl_reader import EspdlModel

ACT_NONE, ACT_PRELU = 0, 2
KIND_PW, KIND_DW, KIND_GD = 0, 1, 2


def rnd_half_up(v):
    return int(math.floor(v + 0.5))


def sat8(v):
    return max(-128, min(127, v))


def scale_int(v, d):
    """v * 2^d, rounding half up when d < 0."""
    if d >= 0:
        return v << d
    return (v + (1 << (-d - 1))) >> (-d)


def filt(t, o, ci, kh, kw, C, H, W):
    """element (out o, in ci, kh, kw) of an S3 S8 conv filter (N16HWC16)."""
    return t.data[((((o // 16) * H + kh) * W + kw) * C + ci) * 16 + o % 16]


class Layer:
    pass


def convert(path, log=print):
    m = EspdlModel(path)
    cons = {}
    for n in m.nodes:
        for i in n.inputs:
            cons.setdefault(i, []).append(n)
    by_out = {n.outputs[0]: n for n in m.nodes}

    def single(v, op):
        c = cons.get(v, [])
        return c[0] if len(c) == 1 and c[0].op == op else None

    def tail(conv):
        """(prelu node or None, value written after PRelu)."""
        p = single(conv.outputs[0], "PRelu")
        return (p, p.outputs[0]) if p else (None, conv.outputs[0])

    for n in m.nodes:       # residual adds / concats keep exponents
        if n.op in ("Add", "Concat"):
            ex = {tuple(m.value_exp[v]) for v in n.inputs + n.outputs}
            if len(ex) != 1:
                raise ValueError("%s mixes exponents %s" % (n.name, ex))
        elif n.op not in ("Conv", "PRelu"):
            raise ValueError("unsupported operator %s (%s)" % (n.op, n.name))

    layers, done = [], set()
    for conv in m.nodes:
        if conv.op != "Conv" or conv.name in done:
            continue
        if conv.attrs.get("activation", "Linear") != "Linear":
            raise ValueError("%s: fused activation %s not supported" % (conv.name, conv.attrs["activation"]))
        prelu, out = tail(conv)
        group = [conv]
        cat = single(out, "Concat")
        if cat:             # the other halves of a split conv
            group = []
            for v in cat.inputs:
                src = by_out[v]
                if src.op == "PRelu":
                    src = by_out[src.inputs[0]]
                if src.op != "Conv" or src.inputs[0] != conv.inputs[0]:
                    raise ValueError("%s: unexpected Concat input %s" % (cat.name, v))
                group.append(src)
            out = cat.outputs[0]
        for g in group:
            done.add(g.name)
        L = Layer()
        L.name = "+".join(g.name for g in group)
        x = conv.inputs[0]
        e_x = m.value_exp[x][0]
        e_out = m.value_exp[out][0]
        ks = conv.attrs["kernel_shape"]
        st = conv.attrs["strides"][0]
        grp = conv.attrs["group"]
        ws = [m.init[g.inputs[1]] for g in group]
        bs = [m.init[g.inputs[2]] for g in group]
        couts = [len(b.data) for b in bs]
        cout = sum(couts)
        e_ws = [w.exponents[0] for w in ws]
        # one weight exponent for the merged layer
        e_w = min(e_ws)
        wq = []             # per member: function (o, ci, kh, kw) -> int
        for w, b, co, ew in zip(ws, bs, couts, e_ws):
            C = 1 if grp > 1 else len(w.data) // (co * ks[0] * ks[1])
            wq.append((w, co, C, ew))
        fits = all(abs(v) << (ew - e_w) <= 127 for w, co, C, ew in wq for v in w.data)
        if not fits:
            e_w = max(e_ws)
        L.reweighted = 0
        cin = wq[0][2] if grp == 1 else grp
        L.kh, L.kw, L.stride, L.group = ks[0], ks[1], st, grp
        L.cin, L.cout = cin, cout
        L.W = {}            # (o, ci, kh, kw) -> int8 (ci = 0 for depthwise)
        L.b, L.a, L.alpha_exp = [], [], []
        o0 = 0
        for g, (w, co, C, ew), b in zip(group, wq, bs):
            d = ew - e_w
            for o in range(co):
                for ci in range(C):
                    for kh in range(ks[0]):
                        for kw in range(ks[1]):
                            v = filt(w, o, ci, kh, kw, C, ks[0], ks[1])
                            nv = sat8(scale_int(v, d))
                            L.reweighted += nv * 2.0 ** e_w != v * 2.0 ** ew
                            L.W[(o0 + o, ci, kh, kw)] = nv
            e_b = b.exponents[0]
            L.b += [scale_int(v, e_b - (e_x + e_w)) for v in b.data]
            p, _ = tail(g)
            if p is not None:
                al = m.init[p.inputs[1]]
                L.a += list(al.data)
                L.alpha_exp += [al.exponents[0]] * co
            o0 += co
        if L.reweighted:
            log("  %s: weight exponents %s merged at %d, %d weights rounded" % (L.name, e_ws, e_w, L.reweighted))
        L.act = ACT_PRELU if prelu else ACT_NONE
        L.sh = e_out - (e_x + e_w)
        if not 0 <= L.sh <= 31:
            raise ValueError("%s: shift %d out of range" % (L.name, L.sh))
        if prelu:
            if len(L.a) != cout:
                raise ValueError("%s: PRelu on only part of a merged conv" % L.name)
            L.ash = min(7, max(-e for e in L.alpha_exp))
            na = [sat8(scale_int(a, L.ash + e)) for a, e in zip(L.a, L.alpha_exp)]
            n_changed = sum(1 for a, e, v in zip(L.a, L.alpha_exp, na) if v * 2.0 ** -L.ash != a * 2.0 ** e)
            if n_changed:
                log("  %s: PReLU slope exponents %s -> shift %d, %d slopes rounded" %
                    (L.name, sorted(set(L.alpha_exp)), L.ash, n_changed))
            L.a = na
        else:
            L.ash, L.a = 0, [0] * cout
        L.e_x, L.e_out, L.input, L.output = e_x, e_out, x, out
        layers.append(L)
    return m, layers


def pack(layers, emb):
    out = bytearray(b"MFNP" + struct.pack("<III", 1, emb, len(layers)))
    for i, L in enumerate(layers):
        if i == 0:          # conv1 3x3 s2 on 3 channels -> pointwise on im2col (k = (kr*3+kc)*3+ch, 27 -> 32)
            assert (L.kh, L.kw, L.stride, L.cin, L.group) == (3, 3, 2, 3, 1), "first layer is not conv1 3x3/2"
            kind, cin = KIND_PW, 32
            w = []
            for o in range(L.cout):
                row = [L.W[(o, ch, kr, kc)] for kr in range(3) for kc in range(3) for ch in range(3)]
                w += row + [0] * 5
        elif L.group == 1:
            assert (L.kh, L.kw, L.stride) == (1, 1, 1), "%s: unsupported conv" % L.name
            kind, cin = KIND_PW, L.cin
            w = [L.W[(o, ci, 0, 0)] for o in range(L.cout) for ci in range(L.cin)]
        elif (L.kh, L.kw) == (3, 3):
            assert L.group == L.cin == L.cout, "%s: grouped conv is not depthwise" % L.name
            kind, cin = KIND_DW, L.cin
            w = [L.W[(c, 0, kr, kc)] for c in range(L.cout) for kr in range(3) for kc in range(3)]
        elif (L.kh, L.kw) == (7, 7):
            assert L.group == L.cin == L.cout == 512 and L.stride == 1, "%s: unsupported GDConv" % L.name
            kind, cin = KIND_GD, 512
            w = [L.W[(c, 0, kr, kc)] for kr in range(7) for kc in range(7) for c in range(512)]
        else:
            raise ValueError("%s: unsupported kernel" % L.name)
        out += struct.pack("<BBBBHH", kind, L.act, L.sh, L.ash, cin, L.cout)
        out += struct.pack("<%db" % len(w), *w)
        out += struct.pack("<%di" % L.cout, *L.b)
        out += struct.pack("<%db" % L.cout, *L.a)
    return bytes(out)


def image_to_int8(path, e_in=-6):
    """aligned 112x112 face -> 112x112x3 INT8, HWC, BGR, (p - 127.5) / 127.5 at
    exponent e_in (ESP-DL FeatImagePreprocessor with rgb_swap)."""
    from PIL import Image
    im = Image.open(path).convert("RGB")
    if im.size != (112, 112):
        raise ValueError("image must be an aligned 112x112 face")
    px = im.tobytes()
    out = bytearray()
    for i in range(112 * 112):
        r, g, b = px[3 * i:3 * i + 3]
        for p in (b, g, r):
            out += struct.pack("<b", sat8(rnd_half_up((p - 127.5) / 127.5 * 2.0 ** -e_in)))
    return bytes(out)


def float_reference(m, img_bytes):
    """dequantized-weight float forward pass of the ESP-DL graph (numpy)."""
    import numpy as np
    v = {}
    e_in = m.value_exp[m.inputs[0]][0]
    v[m.inputs[0]] = np.frombuffer(img_bytes, np.int8).reshape(112, 112, 3).astype(np.float64) * 2.0 ** e_in
    for n in m.nodes:
        if n.op == "Conv":
            x = v[n.inputs[0]]
            w, b = m.init[n.inputs[1]], m.init[n.inputs[2]]
            ks, st, pd, grp = n.attrs["kernel_shape"], n.attrs["strides"][0], n.attrs["pads"][0], n.attrs["group"]
            co = len(b.data)
            C = 1 if grp > 1 else x.shape[2]
            raw = np.array(w.data, np.float64).reshape(co // 16, ks[0], ks[1], C, 16)
            W = raw.transpose(0, 4, 1, 2, 3).reshape(co, ks[0], ks[1], C) * 2.0 ** w.exponents[0]   # [o, kh, kw, c]
            xp = np.pad(x, ((pd, pd), (pd, pd), (0, 0)))
            ho = (xp.shape[0] - ks[0]) // st + 1
            wo = (xp.shape[1] - ks[1]) // st + 1
            y = np.zeros((ho, wo, co))
            for kh in range(ks[0]):
                for kw in range(ks[1]):
                    patch = xp[kh:kh + st * ho:st, kw:kw + st * wo:st, :]
                    if grp == 1:
                        y += patch @ W[:, kh, kw, :].T
                    else:
                        y += patch * W[:, kh, kw, 0]
            v[n.outputs[0]] = y + np.array(b.data) * 2.0 ** b.exponents[0]
        elif n.op == "PRelu":
            x = v[n.inputs[0]]
            al = m.init[n.inputs[1]]
            a = np.array(al.data, np.float64) * 2.0 ** al.exponents[0]
            v[n.outputs[0]] = np.where(x >= 0, x, x * a)
        elif n.op == "Add":
            v[n.outputs[0]] = v[n.inputs[0]] + v[n.inputs[1]]
        elif n.op == "Concat":
            v[n.outputs[0]] = np.concatenate([v[i] for i in n.inputs], axis=2)
    return v


def main(argv):
    if len(argv) == 3 and argv[0] == "--image":
        open(argv[2], "wb").write(image_to_int8(argv[1]))
        return 0
    if len(argv) == 3 and argv[0] == "--ref":
        m = EspdlModel(argv[1])
        v = float_reference(m, open(argv[2], "rb").read())
        e = v[m.outputs[0]].reshape(-1)
        print("embedding float (%d):" % len(e), " ".join("%.5f" % x for x in e))
        return 0
    if len(argv) != 2:
        print(__doc__)
        return 2
    m, layers = convert(argv[0])
    emb = layers[-1].cout
    data = pack(layers, emb)
    open(argv[1], "wb").write(data)
    print("%d layers, embedding %d, %d bytes -> %s" % (len(layers), emb, len(data), argv[1]))
    for L in layers:
        print("  %-24s %-5s %3dx%-3d k%d s%d sh %2d ash %d" % (L.name, "prelu" if L.act else "none", L.cin, L.cout, L.kh, L.stride, L.sh, L.ash))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
