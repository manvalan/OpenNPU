#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Generic network compiler for the v4 accelerator: from a list of layers
(v4_plan.py classes) and a parameter pack to the descriptors, the DDR3
parameter image and the whole board blob. The generalisation of
gen_mfn.c, which only knows MobileFaceNet.

  v4_compile.py <net> <pack> <outdir> [--image img.bin] [--bin model.bin]

<net>    an example name of v4_plan.py (mfn, mfn512, cls16, ...) or a
         Python file defining NET = [Conv1(...), PW(...), ...]
<pack>   parameter pack "MFNP" with one record per weight layer in
         network order (DWPW = dw record then pw record), as written by
         v4_qat.export_pack, espdl_to_v4.py or gen_mfn --dump-params
--image  INT8 HWC input of the network's size (Input item, default
         112x112x3; default content: zeros)
--bin    also write the board blob as a binary file for the ESP32
         (same content as ddr_full.hex, the file make_model.sh builds)

Writes into <outdir> the same files as gen_mfn.c, so the RTL benches
take them unchanged:
  desc.hex ldesc.hex   pass and load descriptors (256 / 128 bit)
  ddr.hex              parameter image (128-bit words)
  wmem.hex dwwmem.hex dwqmem.hex pwqmem.hex   on-chip memory images
  fmap_init.hex        input image in the feature-map memory
  expect.txt           expected output words of every pass
  golden_ref.txt       expected network output (INT8)
  ddr_full.hex         board blob: header @16, descriptors @64, image
                       @256 (after the descriptors above 64 passes),
                       parameters @4096 (or after the image), result
  plan.txt             passes, feature-map allocation, parameter sizes

Feature-map allocation: every tensor gets a contiguous word range of the
3 x 8192-word memory, never overlapping a tensor alive at the same time;
the input and the residual of a pass are put in different banks
(fmap_mem.v has one read port per bank). Largest tensor first, lowest
address first.
"""
import importlib.util
import math
import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v4_plan as V  # noqa: E402
import v4_ref as R  # noqa: E402

P = 16
BANK, NBANK = 8192, 3
FMAP = BANK * NBANK
HDR_W, DESC_W, IMG_W, PARAM_W = 16, 64, 256, 4096
MAGIC = 0x344E4E56


def ilog2(v):
    n = 0
    while (1 << n) < v:
        n += 1
    return n


class Tensor:
    def __init__(self, name, h, w, c, words=None):
        self.name, self.h, self.w, self.c = name, h, w, c
        self.words = words if words is not None else h * w * (c // P)
        self.first = self.last = None      # pass indices of the lifetime
        self.base = None

    def banks(self):
        return set(range(self.base // BANK, (self.base + self.words - 1) // BANK + 1))

    def touch(self, p):
        self.first = p if self.first is None else min(self.first, p)
        self.last = p if self.last is None else max(self.last, p)


class Params:
    """on-chip memory images in network order (gen_mfn.c pw_store/dw_store)"""

    def __init__(self):
        self.wmem, self.dww, self.dwq, self.pwq = [], [], [], []

    @staticmethod
    def _q(b, a, c0):
        q = bytearray(80)
        for l in range(16):
            struct.pack_into("<i", q, l * 4, int(b[c0 + l]))
            q[64 + l] = int(a[c0 + l]) & 255
        return bytes(q)

    def pw(self, Rr):
        ng, nco = Rr["cin"] // P, Rr["cout"] // P
        w = Rr["w"].astype(np.int64)
        base, qbase = len(self.wmem), len(self.pwq)
        for cot in range(nco):
            for g in range(ng):
                blk = w[cot * 16:cot * 16 + 16, g * 16:g * 16 + 16]       # [col][ci]
                self.wmem.append(bytes((blk.reshape(-1) & 255).astype(np.uint8)))
        for cot in range(nco):
            self.pwq.append(self._q(Rr["b"], Rr["a"], cot * 16))
        return base, qbase

    def dw(self, Rr):
        c = Rr["cin"]
        w = Rr["w"].astype(np.int64).reshape(c, 9)
        base = len(self.dww)
        for g in range(c // P):
            self.dww.append(bytes((w[g * 16:g * 16 + 16].reshape(-1) & 255).astype(np.uint8)))
            self.dwq.append(self._q(Rr["b"], Rr["a"], g * 16))
        return base

    def gd(self, Rr, npos):
        c = Rr["cin"]
        ng = c // P
        w = Rr["w"].astype(np.int64).reshape(npos, c)                    # [pos][ch]
        base, qbase = len(self.wmem), len(self.pwq)
        nbeat = npos * ng
        words = [bytearray(256) for _ in range(-(-nbeat // 16))]
        for k in range(nbeat):
            p, g = divmod(k, ng)
            words[k // 16][(k % 16) * 16:(k % 16) * 16 + 16] = bytes((w[p, g * 16:g * 16 + 16] & 255).astype(np.uint8))
        self.wmem += [bytes(x) for x in words]
        for g in range(ng):
            self.pwq.append(self._q(Rr["b"], Rr["a"], g * 16))
        return base, qbase, len(words)

    def offsets(self):
        dww_off = len(self.wmem) * 16
        dwq_off = dww_off + len(self.dww) * 9
        pwq_off = dwq_off + len(self.dww) * 5
        total = pwq_off + len(self.pwq) * 5
        return dww_off, dwq_off, pwq_off, total

    def image(self):
        return b"".join(self.wmem) + b"".join(self.dww) + b"".join(self.dwq) + b"".join(self.pwq)


class Pass:
    def __init__(self, **k):
        self.pw_only = self.s2 = self.res_en = self.gd = self.i2c = self.c3 = 0
        self.pool = None        # v4_plan.Pool of a pooling / copy pass
        self.up2 = 0            # copy pass: 2x nearest upsampling
        self.nge = None         # window feeder: groups emitted (copy into a wider map)
        self.dw = None          # dw record
        self.res = None
        self.pos_off = 0
        self.dwb = 0
        self.ngo_log2 = None
        self.expect = None      # (tensor, word offset, words, values) or None
        self.__dict__.update(k)


def setb(b, lo, width, v):
    v = int(v)
    if v < 0 or v >= (1 << width):
        raise ValueError("descriptor field at bit %d: %d does not fit %d bits" % (lo, v, width))
    for i in range(width):
        if (v >> i) & 1:
            b[(lo + i) // 8] |= 1 << ((lo + i) % 8)


def words_of(t):
    """int8 tensor [h, w, c] -> list of 16-byte words in fmap order"""
    a = np.ascontiguousarray(t.astype(np.int8)).view(np.uint8).reshape(-1, 16)
    return [bytes(r) for r in a]


def hexw(b):
    return bytes(reversed(b)).hex()


def _pad(a, n, axis=-1):
    a = np.asarray(a)
    if a.shape[axis] == n:
        return a
    width = [(0, 0)] * a.ndim
    width[axis] = (0, n - a.shape[axis])
    return np.pad(a, width)


def _scat(a, idx, n, axis=-1):
    """a with its entries along `axis` placed at positions idx of a
    zero array of size n there (channel map of a padded tensor)"""
    a = np.asarray(a)
    shape = list(a.shape)
    shape[axis] = n
    out = np.zeros(shape, a.dtype)
    sl = [slice(None)] * a.ndim
    sl[axis] = list(idx)
    out[tuple(sl)] = a
    return out


def _rec(R0, inmap, cin, cout, npos=None):
    """parameter record for the hardware channels: input channel k of the
    true layer goes to hardware channel inmap[k] (of cin), outputs padded
    to cout with zeros (a depthwise / GDConv record keeps the input map
    on its outputs)"""
    R1 = dict(R0)
    if R0["kind"] in (R.KIND_DW, R.KIND_GD):
        R1["b"], R1["a"] = _scat(R0["b"], inmap, cout), _scat(R0["a"], inmap, cout)
    else:
        R1["b"], R1["a"] = _pad(R0["b"], cout), _pad(R0["a"], cout)
    if R0["kind"] == R.KIND_PW:
        R1["w"] = _scat(_pad(R0["w"], cout, 0), inmap, cin, 1)
    elif R0["kind"] == R.KIND_C3:            # [cout][(kr*3+kc)*cin + ci]
        w3 = R0["w"].reshape(R0["cout"], 9, R0["cin"])
        R1["w"] = _scat(_pad(w3, cout, 0), inmap, cin, 2).reshape(cout, 9 * cin)
    elif R0["kind"] == R.KIND_DW:
        R1["w"] = _scat(R0["w"].reshape(R0["cin"], 9), inmap, cout, 0).reshape(-1)
    else:
        R1["w"] = _scat(R0["w"].reshape(npos, R0["cin"]), inmap, cout, 1).reshape(-1)
    R1["cin"], R1["cout"] = cin, cout
    return R1


def pad_to(hnet, outs, recs):
    """outputs and records of v4_ref.run_net (true sizes) -> the hardware
    channels of the lowered network. Every tensor has a channel map (true
    channel k -> hardware channel map[k]): a layer with weights writes its
    true outputs first and zeros after them; pooling / upsampling keep the
    map; a concatenation puts the second part after the first part's
    hardware groups. -> (hardware tensors, records, maps)"""
    (h, w, c), layers = V.split_input(hnet)
    po, pr, maps = [], [], []
    hw = [None] * len(layers)          # hardware channels of every layer output
    cin = c                            # input channels (padded) when the first layer is not Conv1
    m = None
    for i, L in enumerate(layers):
        o = outs[i]
        if m is None:                  # input map: true channels first
            m = list(range(c))
        if isinstance(L, V.Conv1):
            Rr = recs[i][0]
            pr.append((_rec(Rr, range(Rr["cin"]), Rr["cin"], L.cout),))
            cin, m = L.cout, list(range(o.shape[2]))
        elif isinstance(L, (V.PW, V.Linear, V.Conv3)):
            pr.append((_rec(recs[i][0], m, cin, L.cout),))
            cin, m = L.cout, list(range(o.shape[2]))
        elif isinstance(L, V.DWPW):
            Rd, Rp, d = recs[i]
            pr.append((_rec(Rd, m, cin, cin), _rec(Rp, m, cin, L.cout), _scat(d, m, cin)))
            cin, m = L.cout, list(range(o.shape[2]))
        elif isinstance(L, (V.Pool, V.Upsample)):
            pr.append(())
        elif isinstance(L, V.Concat):
            j = L.ref(i)
            ga = cin // P
            ngo = ga + hw[j] // P
            if o.shape[0] * o.shape[1] > 1:
                ngo = 1 << (ngo - 1).bit_length()
            m = m + [ga * P + k for k in maps[j]]
            cin = ngo * P
            pr.append(())
        elif isinstance(L, V.GDConv):
            Rr = recs[i][0]
            npos = Rr["w"].size // Rr["cin"]
            pr.append((_rec(Rr, m, cin, cin, npos),))
        hw[i] = cin
        maps.append(m)
        po.append(_scat(o, m, cin))
    return po, pr, maps


def build(net, data, img):
    passes_plan, errors, _, _ = V.plan(net)
    if errors:
        raise ValueError("network breaks the v4 rules:\n  " + "\n  ".join(errors))
    outs, recs = R.run_net(net, data, img)
    # hardware channel counts (zero padding, v4_plan.lower): parameters and
    # expected tensors padded the same way
    outs, recs, maps = pad_to(V.lower(net), outs, recs)
    (ih, iw, ic), net = V.split_input(V.lower(net))
    prm = Params()
    passes, tensors = [], []

    def tensor(*a, **k):
        t = Tensor(*a, **k)
        tensors.append(t)
        return t

    if isinstance(net[0], V.Conv1):
        # raw image for im2col_feeder.v: each row from a word boundary, zero-padded
        img_rw = -(-iw * ic // P)
        rows = np.zeros((ih, img_rw * P), np.uint8)
        rows[:, :iw * ic] = np.ascontiguousarray(img.astype(np.int8)).view(np.uint8).reshape(ih, -1)
        raw = rows.reshape(-1)
        img_words = [bytes(raw[k:k + 16]) for k in range(0, len(raw), 16)]
        imgt = tensor("image", ih, iw, ic, ih * img_rw)
        cur = None
    else:
        # no im2col: the input is the first feature map (channels padded)
        img_words = words_of(_pad(img, ic))
        imgt = tensor("input", ih, iw, ic)
        cur = imgt
    imgt.touch(-1)
    ins = []                # input tensor of every layer
    outt = []               # output tensor of every layer (Concat sources)
    i = 0
    while i < len(net):
        L = net[i]
        ins.append(cur)
        if isinstance(L, V.Conv1):
            Rr = recs[i][0]
            wb, qb = prm.pw(Rr)
            ho, wo, ng = -(-ih // L.stride), -(-iw // L.stride), V.conv1_ng(ic)
            out = tensor("L%d conv1" % i, ho, wo, L.cout)
            passes.append(Pass(name=out.name, pw_only=1, i2c=1, s2=int(L.stride == 2), w=wo, h=ho, ng=ng,
                               nco=L.cout // P, pw=Rr, wb=wb, wcnt=ng * (L.cout // P), qb=qb, inp=imgt, out=out,
                               rf=0, rl=ho - 1, val=outs[i]))
            cur = out
        elif isinstance(L, V.Conv3):
            Rr = recs[i][0]
            ngi, nco_all = cur.c // P, L.cout // P
            ng = 9 * ngi
            wb, qb = prm.pw(dict(Rr, cin=9 * cur.c))
            ho, wo = -(-cur.h // L.stride), -(-cur.w // L.stride)
            out = tensor("L%d conv3x3" % i, ho, wo, L.cout,
                         ho * wo * (1 << ilog2(nco_all)) if ho * wo > 1 else nco_all)
            per = max(1, min(nco_all, 256 // ng, 32))
            per = 1 << int(math.log2(per))
            nparts = -(-nco_all // per)
            for k in range(nparts):
                nco = min(per, nco_all - k * per)
                one = ho * wo == 1
                passes.append(Pass(name=out.name + (" part %d/%d" % (k + 1, nparts) if nparts > 1 else ""),
                                   pw_only=1, c3=1, s2=int(L.stride == 2), w=wo, h=ho, ng=ng, ngi=ngi,
                                   nco=nco, pw=Rr, wb=wb + k * per * ng, wcnt=ng * nco, qb=qb + k * per,
                                   inp=cur, out=out, out_off=k * per,
                                   ngo_log2=ilog2(nco) if one else ilog2(nco_all), rf=0, rl=ho - 1,
                                   res=ins[i - 1] if L.residual else None,
                                   val=outs[i] if k == nparts - 1 else None))
            cur = out
        elif isinstance(L, V.Pool):
            ng = cur.c // P
            ho, wo = L.out(cur.h, cur.w)
            out = tensor("L%d %s pool" % (i, L.kind), ho, wo, cur.c)
            passes.append(Pass(name=out.name, pw_only=1, pool=L, s2=int(L.stride == 2), w=wo, h=ho, ng=ng, ngi=ng,
                               nco=0, pw=dict(sh=0, ash=0, act=0), wb=0, wcnt=0, qb=0, inp=cur, out=out,
                               ngo_log2=ilog2(ng), rf=0, rl=ho - 1, val=outs[i]))
            cur = out
        elif isinstance(L, V.Upsample):
            ng = cur.c // P
            out = tensor("L%d upsample" % i, 2 * cur.h, 2 * cur.w, cur.c)
            passes.append(Pass(name=out.name, pw_only=1, pool=V.Pool("max", 1, 1, pad=0), up2=1,
                               w=out.w, h=out.h, ng=ng, ngi=ng, nco=0, pw=dict(sh=0, ash=0, act=0),
                               wb=0, wcnt=0, qb=0, inp=cur, out=out, ngo_log2=ilog2(ng), rf=0, rl=out.h - 1,
                               val=outs[i]))
            cur = out
        elif isinstance(L, V.Concat):
            j = L.ref(i)
            A, B = cur, outt[j]
            if B is None:
                raise ValueError("layer %d: Concat of a banded layer's output" % i)
            ga, gb = A.c // P, B.c // P
            ngo = ga + gb
            if A.h * A.w > 1:
                ngo = 1 << (ngo - 1).bit_length()
            out = tensor("L%d concat" % i, A.h, A.w, ngo * P)
            for k, (src, off, nge) in enumerate(((A, 0, ga), (B, ga, ngo - ga))):
                passes.append(Pass(name="%s part %d/2" % (out.name, k + 1), pw_only=1,
                                   pool=V.Pool("max", 1, 1, pad=0), w=A.w, h=A.h, ng=nge, ngi=src.c // P,
                                   nge=nge, nco=0, pw=dict(sh=0, ash=0, act=0), wb=0, wcnt=0, qb=0,
                                   inp=src, out=out, out_off=off, ngo_log2=ilog2(ngo), rf=0, rl=A.h - 1,
                                   val=outs[i] if k == 1 else None))
            cur = out
        elif isinstance(L, (V.PW, V.Linear)):
            Rr = recs[i][0]
            wb, qb = prm.pw(Rr)
            ng, nco_all = cur.c // P, L.cout // P
            out = tensor("L%d %s" % (i, "linear" if isinstance(L, V.Linear) else "1x1"), cur.h, cur.w, L.cout,
                         cur.h * cur.w * (1 << ilog2(nco_all)) if cur.h * cur.w > 1 else nco_all)
            per = max(1, min(nco_all, 256 // ng, 32))
            per = 1 << int(math.log2(per))
            nparts = -(-nco_all // per)
            for k in range(nparts):
                nco = min(per, nco_all - k * per)
                one = cur.h * cur.w == 1
                passes.append(Pass(name=out.name + (" part %d/%d" % (k + 1, nparts) if nparts > 1 else ""),
                                   pw_only=1, w=cur.w, h=cur.h, ng=ng, nco=nco, pw=Rr,
                                   wb=wb + k * per * ng, wcnt=ng * nco, qb=qb + k * per, inp=cur, out=out,
                                   out_off=k * per, ngo_log2=ilog2(nco) if one else ilog2(nco_all),
                                   rf=0, rl=cur.h - 1,
                                   res=cur if (isinstance(L, V.PW) and L.residual) else None,
                                   val=outs[i] if k == nparts - 1 else None))
            cur = out
        elif isinstance(L, V.DWPW) and L.bands > 1:
            C = net[i + 1] if i + 1 < len(net) else None
            if not (isinstance(C, V.DWPW) and C.bands == L.bands and L.stride == 1 and not L.residual and not C.residual):
                raise ValueError("layer %d: bands= needs a stride-1 DWPW followed by a DWPW with the same bands, no residual" % i)
            Rd, Rp, _ = recs[i]
            Cd, Cp, _ = recs[i + 1]
            db, (wb, qb) = prm.dw(Rd), prm.pw(Rp)
            cdb, (cwb, cqb) = prm.dw(Cd), prm.pw(Cp)
            H, W = cur.h, cur.w
            E = outs[i]                                    # full producer output (reference only)
            s = C.stride
            Ho, Wo = -(-H // s), -(-W // s)
            ng, nge, ngy = cur.c // P, L.cout // P, C.cout // P
            bounds = [Ho * k // L.bands for k in range(L.bands + 1)]
            spans = []
            for k in range(L.bands):
                o0, o1 = bounds[k], bounds[k + 1]
                a = max(0, s * o0 - 1)
                e = min(H - 1, s * (o1 - 1) + 1)
                spans.append((o0, o1, a, e))
            buf = tensor("L%d band buffer" % i, max(e - a + 1 for _, _, a, e in spans), W, L.cout)
            y = tensor("L%d" % (i + 1), Ho, Wo, C.cout)
            for o0, o1, a, e in spans:
                nr = e - a + 1
                passes.append(Pass(name="L%d dw+1x1 rows %d-%d" % (i, a, e), w=W, h=H, ng=ng, nco=nge,
                                   dw=Rd, dwb=db, pw=Rp, wb=wb, wcnt=ng * nge, qb=qb, inp=cur, out=buf,
                                   rf=a, rl=e + 2, val=E[a:e + 1], band_expect=True))
                passes.append(Pass(name="L%d dw+1x1 out rows %d-%d" % (i + 1, o0, o1 - 1), s2=int(s == 2),
                                   w=W, h=nr, ng=nge, nco=ngy, dw=Cd, dwb=cdb, pw=Cp, wb=cwb, wcnt=nge * ngy,
                                   qb=cqb, inp=buf, out=y, rf=s * o0 - a, rl=s * (o1 - 1) - a + 2,
                                   pos_off=o0 * Wo, val=outs[i + 1][o0:o1], rows=(o0, o1)))
            ins.append(buf)
            cur = y
            outt += [None, y]
            i += 2
            continue
        elif isinstance(L, V.DWPW):
            Rd, Rp, _ = recs[i]
            db, (wb, qb) = prm.dw(Rd), prm.pw(Rp)
            ng, nco = cur.c // P, L.cout // P
            Ho, Wo = -(-cur.h // L.stride), -(-cur.w // L.stride)
            out = tensor("L%d dw+1x1" % i, Ho, Wo, L.cout)
            passes.append(Pass(name=out.name, s2=int(L.stride == 2), w=cur.w, h=cur.h, ng=ng, nco=nco,
                               dw=Rd, dwb=db, pw=Rp, wb=wb, wcnt=ng * nco, qb=qb, inp=cur, out=out,
                               rf=0, rl=cur.h + 1, res=ins[i - 1] if L.residual else None, val=outs[i]))
            cur = out
        elif isinstance(L, V.GDConv):
            Rr = recs[i][0]
            wb, qb, wcnt = prm.gd(Rr, cur.h * cur.w)
            ng = cur.c // P
            out = tensor("L%d GDConv" % i, 1, 1, cur.c)
            passes.append(Pass(name=out.name, pw_only=1, gd=1, w=cur.w, h=cur.h, ng=ng, nco=0, pw=Rr,
                               wb=wb, wcnt=wcnt, qb=qb, inp=cur, out=out, ngo_log2=ilog2(ng),
                               rf=0, rl=cur.h - 1, val=outs[i]))
            cur = out
        outt.append(cur)
        i += 1
    final = cur

    # ---- lifetimes ----
    for p, ps in enumerate(passes):
        ps.inp.touch(p)
        ps.out.touch(p)
        if ps.res is not None:
            ps.res.touch(p)
    final.touch(len(passes))                     # read back by v4_boot after the last pass

    # ---- allocation: first fit, bank-disjoint input/residual ----
    pairs = [(ps.inp, ps.res) for ps in passes if ps.res is not None]
    done = []
    for t in sorted(tensors, key=lambda t: (-t.words, t.first)):
        if t.first is None:
            continue
        cands = sorted({0, BANK, 2 * BANK} | {u.base + u.words for u in done})
        for b in cands:
            if b + t.words > FMAP:
                continue
            t.base = b
            ok = all(u.last < t.first or t.last < u.first or u.base + u.words <= b or b + t.words <= u.base
                     for u in done)
            for x, r in pairs:
                if ok and (x is t or r is t):
                    o = r if x is t else x
                    if o.base is not None and o in done and t.banks() & o.banks():
                        ok = False
            if ok:
                break
        else:
            raise ValueError("feature-map memory: no room for %s (%d words)" % (t.name, t.words))
        done.append(t)

    # ---- descriptors ----
    dww_off, dwq_off, pwq_off, ptotal = prm.offsets()
    desc, ldesc, expect = [], [], []
    for p, ps in enumerate(passes):
        d = bytearray(32)
        ngo_log2 = ps.ngo_log2 if ps.ngo_log2 is not None else ilog2(ps.out.c // P)
        setb(d, 0, 1, ps.pw_only); setb(d, 1, 1, ps.s2); setb(d, 2, 1, ps.res is not None)
        setb(d, 3, 1, p == len(passes) - 1)
        setb(d, 4, 8, ps.w); setb(d, 12, 8, ps.h); setb(d, 20, 6, ps.ng & 63); setb(d, 189, 3, ps.ng >> 6); setb(d, 26, 6, ps.nco)
        if ps.dw is not None:
            setb(d, 32, 5, ps.dw["sh"]); setb(d, 37, 3, ps.dw["ash"]); setb(d, 40, 2, ps.dw["act"])
        setb(d, 42, 5, ps.pw["sh"]); setb(d, 47, 3, ps.pw["ash"]); setb(d, 50, 2, ps.pw["act"])
        setb(d, 52, 15, ps.inp.base)
        setb(d, 67, 15, ps.out.base + getattr(ps, "out_off", 0))
        if ps.i2c:                              # im2col pass: image height
            setb(d, 82, 8, ps.inp.h)
        else:
            # same layout as the output: a part's group offset applies to both
            setb(d, 82, 15, ps.res.base + getattr(ps, "out_off", 0) if ps.res is not None else 0)
        setb(d, 97, 3, ngo_log2)
        setb(d, 100, 8, ps.rf); setb(d, 108, 8, ps.rl); setb(d, 116, 16, ps.pos_off)
        pad = 0 if ps.pw_only else 1
        if ps.i2c:                              # im2col pass: image width, channels
            setb(d, 173, 8, ps.inp.w); setb(d, 181, 3, ps.inp.c)
        else:
            setb(d, 173, 15, ps.inp.base + max(ps.rf - pad, 0) * ps.w * ps.ng)
        setb(d, 132, 16, (p % 2) * 256); setb(d, 148, 12, (p % 2) * 32); setb(d, 160, 12, (p % 2) * 32)
        setb(d, 172, 1, ps.gd); setb(d, 188, 1, ps.i2c)
        if ps.c3 or ps.pool:                    # window feeder: input map size, groups, row stride
            setb(d, 192, 1, ps.c3); setb(d, 193, 8, ps.inp.w); setb(d, 201, 8, ps.inp.h)
            setb(d, 209, 6, ps.ngi); setb(d, 215, 15, ps.inp.w * ps.ngi)
        if ps.pool:                             # pooling / copy: window, padding, kind, scale
            L = ps.pool
            setb(d, 230, 1, 1); setb(d, 231, 1, L.k == 2); setb(d, 232, 1, L.pad == 0)
            setb(d, 233, 1, L.kind == "max"); setb(d, 234, 8, L.mul); setb(d, 242, 4, L.sh)
            setb(d, 246, 1, L.k == 1); setb(d, 247, 1, ps.up2)
            setb(d, 248, 6, ps.nge if ps.nge is not None else ps.ngi)
        desc.append(bytes(d))
        l = bytearray(16)
        groups = 0 if (ps.pw_only or ps.gd) else ps.ng
        tiles = ps.ng if ps.gd else ps.nco
        if ps.wcnt > 256 or groups > 32 or tiles > 32:
            raise ValueError("pass %d too big for the half buffers" % p)
        setb(l, 0, 25, ps.wb * 16); setb(l, 25, 9, ps.wcnt)
        setb(l, 34, 25, dww_off + ps.dwb * 9); setb(l, 59, 6, groups)
        setb(l, 65, 25, dwq_off + ps.dwb * 5)
        setb(l, 90, 25, pwq_off + ps.qb * 5); setb(l, 115, 6, tiles)
        ldesc.append(bytes(l))
        # expected words written by this pass
        if ps.val is not None:
            ngo = 1 << ngo_log2 if ps.out.h * ps.out.w > 1 else ps.out.c // P
            if getattr(ps, "band_expect", False):
                base = ps.out.base
            elif hasattr(ps, "rows"):
                base = ps.out.base + ps.rows[0] * ps.out.w * ngo
            else:
                base = ps.out.base
            wl = words_of(ps.val)
            if ngo != ps.out.c // P:
                raise ValueError("%s: output channel groups not a power of two" % ps.name)
            expect.append((p, base, wl))
    fo = outs[-1]
    fm = maps[-1]
    out_index = [p * fo.shape[2] + k for p in range(fo.shape[0] * fo.shape[1]) for k in fm]
    return dict(net=net, passes=passes, tensors=tensors, final=final, imgt=imgt, img_words=img_words, prm=prm, desc=desc,
                out_index=np.array(out_index),
                ldesc=ldesc, expect=expect, golden=outs[-1].reshape(-1), ptotal=ptotal, img=img)


def write(o, outdir, bin_path=None):
    os.makedirs(outdir, exist_ok=True)
    prm, passes = o["prm"], o["passes"]

    def wr(name, words):
        with open(os.path.join(outdir, name), "w") as f:
            for w in words:
                f.write(hexw(w) + "\n")

    wr("desc.hex", o["desc"])
    wr("ldesc.hex", o["ldesc"])
    pimg = prm.image()
    pwords = [pimg[k:k + 16] for k in range(0, len(pimg), 16)]
    wr("ddr.hex", pwords)
    wr("wmem.hex", prm.wmem); wr("dwwmem.hex", prm.dww); wr("dwqmem.hex", prm.dwq); wr("pwqmem.hex", prm.pwq)
    iw = o["img_words"]
    with open(os.path.join(outdir, "fmap_init.hex"), "w") as f:
        f.write("@%x\n" % o["imgt"].base)
        for w in iw:
            f.write(hexw(w) + "\n")
    with open(os.path.join(outdir, "expect.txt"), "w") as f:
        for p, base, wl in o["expect"]:
            f.write("pass %d %d %d\n" % (p, base, len(wl)))
            for w in wl:
                f.write(hexw(w) + "\n")
    g = o["golden"]
    with open(os.path.join(outdir, "golden_ref.txt"), "w") as f:
        f.write("embedding (%d INT8): %s\n" % (len(g), " ".join(str(int(v)) for v in g)))
    # board blob
    ptotal = o["ptotal"]
    nd = len(passes)
    final = o["final"]
    out_words = final.words
    # image at W 256 (room for 64 passes x 3 descriptor words), or after
    # a longer descriptor table; parameters at W 4096, or after the image
    img_w = max(IMG_W, -(-(DESC_W + 3 * nd) // 256) * 256)
    param_w = max(PARAM_W, -(-(img_w + len(iw)) // 256) * 256)
    result_w = 80000 if param_w + ptotal <= 80000 else (param_w + ptotal + 4095) // 4096 * 4096
    blob = {}
    h0 = bytearray(16)
    struct.pack_into("<HIIHH", h0, 0, nd, DESC_W, img_w, len(iw), o["imgt"].base)
    h1 = bytearray(16)
    struct.pack_into("<IHHII", h1, 0, result_w, final.base, out_words, param_w, MAGIC)
    blob[HDR_W] = [bytes(h0), bytes(h1)]
    tab = []
    for k in range(nd):
        tab += [o["desc"][k][:16], o["desc"][k][16:32], o["ldesc"][k]]
    blob[DESC_W] = tab
    blob[img_w] = iw
    blob[param_w] = pwords
    with open(os.path.join(outdir, "ddr_full.hex"), "w") as f:
        for at, ws in blob.items():
            f.write("@%x\n" % at)
            for w in ws:
                f.write(hexw(w) + "\n")
    if bin_path:
        size = (param_w + ptotal) * 16
        b = bytearray(size)
        for at, ws in blob.items():
            for k, w in enumerate(ws):
                b[(at + k) * 16:(at + k + 1) * 16] = w
        open(bin_path, "wb").write(bytes(b))
    with open(os.path.join(outdir, "plan.txt"), "w") as f:
        f.write("%d passes, parameter image %d words, result @%d (%d words from fmap %d)\n" %
                (nd, ptotal, result_w, out_words, final.base))
        for k, ps in enumerate(passes):
            f.write("%2d %-36s in %5d out %5d%s\n" % (k, ps.name, ps.inp.base, ps.out.base + getattr(ps, "out_off", 0),
                                                       " res %d" % (ps.res.base + getattr(ps, "out_off", 0)) if ps.res is not None else ""))
        f.write("feature-map tensors (words, base, passes alive):\n")
        for t in o["tensors"]:
            f.write("  %-28s %6d @%5d  %s..%s\n" % (t.name, t.words, t.base, t.first, t.last))
    return nd, ptotal, result_w


def load_net(arg):
    if arg in V.EXAMPLES:
        return V.EXAMPLES[arg][0]()
    spec = importlib.util.spec_from_file_location("netdef", arg)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m.NET


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    net = load_net(argv[0])
    data = open(argv[1], "rb").read()
    shape, _ = V.split_input(net)
    img = np.zeros(shape, np.int8)
    bin_path = None
    k = 3
    while k < len(argv):
        if argv[k] == "--image":
            img = np.frombuffer(open(argv[k + 1], "rb").read(), np.int8).reshape(shape)
        elif argv[k] == "--bin":
            bin_path = argv[k + 1]
        else:
            print("unknown option", argv[k])
            return 2
        k += 2
    o = build(net, data, img)
    nd, ptotal, rw = write(o, argv[2], bin_path)
    print("%d passes, parameter image %d words (%d KB), output %d values, result @%d -> %s" %
          (nd, ptotal, ptotal * 16 // 1024, len(o["golden"]), rw, argv[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
