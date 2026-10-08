#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Pass planner and rule checker for networks on the v4 accelerator.

  v4_plan.py                  lists the example networks
  v4_plan.py <name>           pass table, rule check, parameter size,
                              feature-map memory and a cycle ESTIMATE
  v4_plan.py <file.py>        the same for a network file defining
                              NET = [Input(...), Conv1(...), ...]
  v4_plan.py --calibrate      compares the estimate with the RTL cycle
                              counts measured on MobileFaceNet

A network is a list of layers (classes below) applied in order to an
INT8 image; an optional first item Input(h, w, c) gives the image size
(default 112x112x3, the MobileFaceNet benchmark). The planner maps every layer to engine passes the
way gen_mfn.c does for MobileFaceNet, checks every limit of the v4 RTL
(datasheet chapter "Progettare una rete", table of rules) and estimates
the cycles with the rules of mfn_cycle_model.py, recalibrated on the RTL
run docs/mfn_rtl_run.log (--calibrate prints the error per pass).

What it does NOT do: write descriptors (v4_compile.py does, for the
same network list). Cycle numbers are estimates, not measurements.
"""
import math
import sys

P = 16                      # channels per 128-bit word / per array beat
FMAP_WORDS = 3 * 8192       # fmap_mem: 3 banks x 8192 words x 128 bit = 384 KB
BANK = 8192
LBDEPTH = 512               # dw line buffer words: (W+2)*ng must fit
HALF_W = 256                # pw weight words (2048 bit) per half buffer
HALF_Q = 32                 # dw groups / pw tiles per half buffer
MAXNGV = 256                # pointwise input groups: Cin <= 4096
NDESC = 256                 # passes per network
DDR_RATE = 0.63             # parameter words (128 bit) per core cycle, measured
                            # on the 512x512 linear passes (~4,096 words in
                            # ~6,500 cycles, datasheet 4.7)
TAIL_DW = 88                # fused dw+pw pipeline tail, measured


def ceil(a, b):
    return -(-a // b)


class Input:
    """image size: h x w pixels, c = 1..4 channels (HWC, INT8). Optional
    first item of a network; without it the image is 112x112x3."""
    def __init__(self, h, w, c=3):
        self.h, self.w, self.c = h, w, c


def split_input(net):
    """-> ((h, w, c), layers without the Input item)"""
    if net and isinstance(net[0], Input):
        return (net[0].h, net[0].w, net[0].c), list(net[1:])
    return (112, 112, 3), list(net)


def conv1_ng(c):
    """beats per position of the im2col vector (9*c values, ng >= 2)"""
    return max(2, ceil(9 * c, P))


class Conv1:
    """first layer: 3x3 pad 1, stride 1 or 2, on the image, through
    im2col_feeder, run as a pointwise pass (9*c values padded to
    16*ng) -> cout."""
    def __init__(self, cout, act="prelu", stride=2):
        self.cout, self.act, self.stride = cout, act, stride


class Conv3:
    """dense 3x3 convolution (pad 1, stride 1 or 2) anywhere in the
    network, run through conv3_feeder as a pointwise pass with 9*Cin
    inputs per neuron. residual=True adds the block input (the input of
    the previous layer), like DWPW (ResNet basic block)."""
    def __init__(self, cout, act="relu", stride=1, residual=False):
        self.cout, self.act, self.stride, self.residual = cout, act, stride, residual


class Pool:
    """max or average pooling over a k x k window (k = 2 or 3), stride 1
    or 2, zero padding pad = 0 or 1 (default: 0 for k = 2, 1 for k = 3),
    channels unchanged, no parameters (pool_unit.v). Output size
    floor((in + 2*pad - k) / stride) + 1. Average = sum of the k*k taps
    (outside = 0) times mul / 2^sh, rounded (default 1/4 for 2x2,
    57/512 ~ 1/9 for 3x3); max ignores the taps outside the map."""
    def __init__(self, kind="max", k=2, stride=2, pad=None, mul=None, sh=None):
        self.kind, self.k, self.stride = kind, k, stride
        self.pad = (0 if k == 2 else 1) if pad is None else pad
        if kind == "max":
            self.mul, self.sh = 1, 0
        else:
            dm, ds = (1, 2) if k == 2 else (57, 9)
            self.mul = dm if mul is None else mul
            self.sh = ds if sh is None else sh

    def out(self, h, w):
        return (h + 2 * self.pad - self.k) // self.stride + 1, (w + 2 * self.pad - self.k) // self.stride + 1


class Upsample:
    """2x nearest-neighbour upsampling (each pixel repeated 2x2), channels
    unchanged, no parameters: a copy pass through conv3_feeder +
    pool_unit (1x1 window, up2)."""
    def __init__(self, factor=2):
        self.factor = factor


class Concat:
    """channel concatenation: [current map, output of layer src] (src =
    index of an earlier layer in the list, Input not counted; a negative
    src counts back from this layer: -2 = two layers before). Both maps
    must have the same height and width; no parameters. Two copy passes
    into a new map (U-Net / FPN skip connections). On the hardware the
    second part starts at the first part's padded channel count; the
    compiler places the next layer's weights accordingly."""
    def __init__(self, src):
        self.src = src

    def ref(self, i):
        return self.src if self.src >= 0 else i + self.src


class PW:
    """1x1 convolution (pointwise-only pass)."""
    def __init__(self, cout, act="prelu", residual=False):
        self.cout, self.act, self.residual = cout, act, residual


class DWPW:
    """3x3 depthwise (pad 1, stride 1/2) fused with the 1x1 that follows."""
    def __init__(self, stride, cout, dw_act="prelu", pw_act="none", residual=False, bands=1):
        self.stride, self.cout, self.dw_act, self.pw_act = stride, cout, dw_act, pw_act
        self.residual, self.bands = residual, bands


class GDConv:
    """global depthwise over the whole HxW map -> 1x1xC (gdconv_unit)."""
    def __init__(self, act="none"):
        self.act = act


class Linear:
    """fully connected on a 1x1 map = pointwise pass, split by 128 outputs."""
    def __init__(self, cout, act="none"):
        self.cout, self.act = cout, act


def bottleneck(cin, t, c, s, hw):
    """MobileNetV2 / MobileFaceNet inverted residual: expand + (dw + project)."""
    res = s == 1 and cin == c
    return [PW(cin * t, "prelu"), DWPW(s, c, "prelu", "none", residual=res)]


def mobilefacenet(emb=128, cfg=((2, 64, 5, 2), (4, 128, 1, 2), (2, 128, 6, 1), (4, 128, 1, 2), (2, 128, 2, 1)),
                  act="prelu"):
    net = [Conv1(64, act)]
    # dw 3x3 64 + first expand fused, then dw s2 + project, in 4 row bands
    # (the 56x56x128 expanded tensor does not fit in the 384 KB fmap memory)
    net += [DWPW(1, 128, act, act, bands=4), DWPW(2, 64, act, "none", bands=4)]
    cin, first = 64, True
    for t, c, n, s in cfg:
        for i in range(n):
            st = s if i == 0 else 1
            if first:           # b1 is the banded pair above
                first = False
                cin = c
                continue
            net += [PW(cin * t, act), DWPW(st, c, act, "none", residual=(st == 1 and cin == c))]
            cin = c
    net += [PW(512, act), GDConv("none"), Linear(emb, "none")]
    return net


def nfb_lite():
    """MobileFaceNet with half the 14x14 stage (3 bottlenecks instead of 6)."""
    return mobilefacenet(128, ((2, 64, 5, 2), (4, 128, 1, 2), (2, 128, 3, 1), (4, 128, 1, 2), (2, 128, 2, 1)))


def classifier16():
    """example classifier: MobileFaceNet body with ReLU, 16 output logits
    (up to 16 classes, unused ones zero), softmax on the ESP32."""
    net = mobilefacenet(128, act="relu")
    net[-1] = Linear(16, "none")
    return net


def demo_net():
    """small test network that is not MobileFaceNet: ReLU, stride 2 on an
    odd size (7 -> 4), GDConv 4x4, a linear head split in two passes"""
    return [Conv1(32, "relu"),
            DWPW(2, 64, "relu", "relu"),                  # 56 -> 28
            PW(128, "relu"), DWPW(2, 128, "relu", "none"),  # 28 -> 14
            PW(256, "relu"), DWPW(1, 128, "relu", "none", residual=True),
            PW(256, "relu"), DWPW(2, 256, "relu", "relu"),  # 14 -> 7
            DWPW(2, 256, "relu", "relu"),                 # 7 -> 4
            GDConv("none"), Linear(48, "none")]


def rgb160():
    """input not 112x112: 160x120 RGB (non-square), stride-2 first layer,
    GDConv over 10x8, 32 outputs"""
    return [Input(120, 160, 3),
            Conv1(32, "relu"),                              # 120x160 -> 60x80
            DWPW(2, 64, "relu", "relu"),                    # -> 30x40
            PW(128, "relu"), DWPW(2, 128, "relu", "none"),  # -> 15x20
            PW(256, "relu"), DWPW(2, 256, "relu", "relu"),  # -> 8x10
            GDConv("none"), Linear(32, "none")]


def gray_s1():
    """grayscale 64x48 input, stride-1 first layer, 16 outputs"""
    return [Input(48, 64, 1),
            Conv1(32, "relu", stride=1),                    # 48x64
            DWPW(2, 64, "relu", "relu"),                    # -> 24x32
            PW(128, "relu"), DWPW(2, 128, "relu", "none"),  # -> 12x16
            PW(256, "relu"), DWPW(2, 256, "relu", "relu"),  # -> 6x8
            GDConv("none"), Linear(16, "none")]


def fc4096():
    """fully connected layers with 4096 neurons: GDConv 4x4x256, then
    256 -> 4096 (16 passes) and 4096 -> 16 (4096 inputs per neuron)"""
    return [Conv1(32, "relu"),                              # 112 -> 56
            DWPW(2, 64, "relu", "relu"),                    # -> 28
            DWPW(2, 128, "relu", "relu"),                   # -> 14
            DWPW(2, 256, "relu", "relu"),                   # -> 7
            DWPW(2, 256, "relu", "relu"),                   # -> 4
            GDConv("relu"), Linear(4096, "relu"), Linear(16, "none")]


def odd():
    """any channel counts: 37x53 RGB image, 20/40/100/70/7 channels, a
    single neuron (Linear 1), 4095 neurons fed by 1 input each, then 13
    outputs with 4095 inputs each; the compiler pads to 16-channel groups"""
    return [Input(37, 53, 3),
            Conv1(20, "relu"),                              # -> 19x27
            DWPW(2, 40, "relu", "relu"),                    # -> 10x14
            PW(100, "relu"), DWPW(2, 70, "relu", "none"),   # -> 5x7
            PW(7, "relu"), GDConv("relu"),
            Linear(1, "none"), Linear(4095, "relu"), Linear(13, "none")]


def resnet_s():
    """small ResNet: dense 3x3 convolutions in the middle of the network,
    basic blocks with residual (conv3 -> conv3 + block input), stride-2
    3x3 convolutions, 64x64 RGB, 10 outputs"""
    return [Input(64, 64, 3),
            Conv1(32, "relu"),                              # 64 -> 32
            Conv3(32, "relu"), Conv3(32, "none", residual=True),
            Conv3(64, "relu", stride=2),                    # -> 16
            Conv3(64, "relu"), Conv3(64, "none", residual=True),
            Conv3(128, "relu", stride=2),                   # -> 8
            GDConv("relu"), Linear(10, "none")]


def mlp784():
    """no convolution at all: a 784-value input vector (28x28 MNIST
    flattened), fully connected 784 -> 128 -> 64 -> 10"""
    return [Input(1, 1, 784), Linear(128, "relu"), Linear(64, "relu"), Linear(10, "none")]


def vgg_pool():
    """VGG-style network with pooling: 3x3 convolutions, 2x2 max pooling,
    3x3 stride-2 average pooling, GDConv, 80x80 RGB"""
    return [Input(80, 80, 3),
            Conv1(32, "relu", stride=1),                    # 80x80
            Pool("max", 2, 2),                              # -> 40
            Conv3(64, "relu"), Pool("max", 2, 2),           # -> 20
            Conv3(128, "relu"), Conv3(128, "relu"),
            Pool("avg", 3, 2),                              # -> 10
            Conv3(128, "relu"), Pool("max", 2, 2),          # -> 5
            GDConv("relu"), Linear(20, "none")]


def unet_s():
    """small U-Net (segmentation): encoder 3x3 + max pooling, decoder 2x
    upsampling + concatenation with the encoder maps (skip connections),
    40x40 RGB in, 40x40 map of 8 classes out"""
    return [Input(40, 40, 3),
            Conv1(32, "relu", stride=1),                    # 0: e1 40x40x32
            Pool("max", 2, 2),                              # 1: 20
            Conv3(64, "relu"),                              # 2: e2 20x20x64
            Pool("max", 2, 2),                              # 3: 10
            Conv3(128, "relu"),                             # 4: bottleneck 10x10x128
            Upsample(),                                     # 5: 20x20x128
            Concat(2),                                      # 6: + e2 -> 192
            Conv3(64, "relu"),                              # 7
            Upsample(),                                     # 8: 40x40x64
            Concat(0),                                      # 9: + e1 -> 96
            Conv3(32, "relu"),                              # 10
            PW(8, "none")]                                  # 11: 8 classes per pixel


def bench_small():
    """final test, small: 32x32 RGB image classifier (CIFAR-10 size),
    dense 3x3 convolutions with stride 2, 10 outputs"""
    return [Input(32, 32, 3),
            Conv1(16, "relu", stride=1),                    # 32x32x16
            Conv3(32, "relu", stride=2),                    # -> 16x16x32
            Conv3(64, "relu", stride=2),                    # -> 8x8x64
            GDConv("relu"), Linear(10, "none")]


def bench_medium():
    """final test, medium: 96x96 RGB, MobileNet-style depthwise-separable
    body (person detection size), 2 outputs"""
    return [Input(96, 96, 3),
            Conv1(32, "relu"),                              # 96 -> 48
            DWPW(1, 64, "relu", "relu"),
            DWPW(2, 128, "relu", "relu"),                   # -> 24
            DWPW(1, 128, "relu", "relu"),
            DWPW(2, 256, "relu", "relu"),                   # -> 12
            DWPW(1, 256, "relu", "relu"),
            DWPW(2, 256, "relu", "relu"),                   # -> 6
            GDConv("relu"), Linear(2, "none")]


def bench_heavy():
    """final test, heavy: 128x128 RGB, VGG/ResNet mix -- dense 3x3
    convolutions up to 256 -> 256 channels, residual blocks, max pooling,
    fully connected 256 -> 1024 -> 100"""
    return [Input(128, 128, 3),
            Conv1(32, "relu"),                              # 128 -> 64x64x32
            Conv3(64, "relu"), Pool("max", 2, 2),           # -> 32x32x64
            Conv3(128, "relu"),
            Conv3(128, "relu"), Conv3(128, "none", residual=True),
            Pool("max", 2, 2),                              # -> 16x16x128
            Conv3(256, "relu"),
            Conv3(256, "relu"), Conv3(256, "none", residual=True),
            Pool("max", 2, 2),                              # -> 8x8x256
            Conv3(256, "relu"),
            GDConv("relu"), Linear(1024, "relu"), Linear(100, "none")]


def too_big():
    """deliberately wrong network: shows what the checker rejects."""
    return [Conv1(32, "relu"), PW(48, "relu"), DWPW(1, 64, "relu", "none"),
            PW(1024, "relu"), DWPW(2, 128, "relu", "none"), GDConv(), Linear(1000)]


EXAMPLES = {
    "mfn": (lambda: mobilefacenet(128), "MobileFaceNet, embedding 128 (modello di prova, gen_mfn)"),
    "mfn512": (lambda: mobilefacenet(512), "MobileFaceNet ESP-DL, embedding 512 (modello reale)"),
    "mfn_lite": (nfb_lite, "MobileFaceNet con 3 bottleneck a 14x14 invece di 6"),
    "cls16": (classifier16, "classificatore 112x112, ReLU, 16 uscite"),
    "demo": (demo_net, "rete di prova non MobileFaceNet (ReLU, 7->4, GDConv 4x4, lineare 256->48)"),
    "rgb160": (rgb160, "ingresso 160x120 RGB (non 112x112), GDConv 10x8, 32 uscite"),
    "gray_s1": (gray_s1, "ingresso 64x48 in scala di grigi, primo strato stride 1, 16 uscite"),
    "fc4096": (fc4096, "strati fully connected da 4096 neuroni, 4096 ingressi per neurone"),
    "odd": (odd, "canali qualsiasi (20, 40, 100, 70, 7, 1, 4095, 13), ingresso 53x37"),
    "resnet_s": (resnet_s, "ResNet piccola: convoluzioni 3x3 dense con residual, 64x64 RGB, 10 uscite"),
    "mlp784": (mlp784, "solo fully connected, nessuna convoluzione: vettore 784 -> 128 -> 64 -> 10"),
    "vgg_pool": (vgg_pool, "stile VGG: 3x3 dense, max pooling 2x2, average pooling 3x3, 80x80 RGB, 20 uscite"),
    "unet_s": (unet_s, "U-Net piccola: upsampling 2x e concatenazione con le mappe dell'encoder, 40x40 -> 40x40x8"),
    "bench_small": (bench_small, "test finale, piccola: 32x32 RGB, 3x3 dense stride 2, 10 uscite"),
    "bench_medium": (bench_medium, "test finale, media: 96x96 RGB, depthwise-separable (stile MobileNet), 2 uscite"),
    "bench_heavy": (bench_heavy, "test finale, pesante: 128x128 RGB, 3x3 dense fino a 256->256, residual, max pooling, FC 1024"),
    "too_big": (too_big, "rete sbagliata apposta (mostra le regole violate)"),
}


def lower(net):
    """the network as the hardware runs it: every layer's output channels
    padded with zero channels (zero weights, bias and slope, so the extra
    outputs are 0 and the next layer ignores them) to what the RTL needs:
    a multiple of 16, at least 32 (a 1x1 pass needs ng >= 2), a power of
    two of 16-channel groups on maps larger than 1x1 (tile_writer.v), at
    least 4 groups before a GDConv; the network's last output only to a
    multiple of 16. The designer writes any channel count from 1 up;
    v4_ref / v4_qat use the true sizes, v4_compile pads the parameters.
    -> new list (Input item kept), same layer classes."""
    import copy
    shape, layers = split_input(net)
    h, w, c0 = shape
    if layers and not isinstance(layers[0], Conv1):
        # the input goes straight into the feature-map memory as a map
        g = max(ceil(c0, P), 2)
        nxt = 0
        while nxt < len(layers) and isinstance(layers[nxt], Pool):
            nxt += 1
        if nxt < len(layers) and isinstance(layers[nxt], GDConv):
            g = max(g, 3)
        if h * w > 1:
            g = 1 << (g - 1).bit_length()
        shape = (h, w, g * P)
    out = []
    for i, L in enumerate(layers):
        M = copy.copy(L)
        if isinstance(L, (Conv1, Conv3, DWPW)):
            h, w = ceil(h, L.stride), ceil(w, L.stride)
        elif isinstance(L, Pool):
            h, w = L.out(h, w)
        elif isinstance(L, Upsample):
            h, w = 2 * h, 2 * w
        elif isinstance(L, GDConv):
            h = w = 1
        if hasattr(L, "cout"):
            g = ceil(L.cout, P)
            last = i == len(layers) - 1
            if not last:
                g = max(g, 2)
                nxt = i + 1
                while nxt < len(layers) and isinstance(layers[nxt], Pool):
                    nxt += 1
                if nxt < len(layers) and isinstance(layers[nxt], GDConv):
                    g = max(g, 3)
            if h * w > 1:
                g = 1 << (g - 1).bit_length()
            M.cout = g * P
        out.append(M)
    return [Input(*shape)] + out


class Pass:
    pass


def plan(net):
    """-> (passes, errors, warnings, param_words); channel counts are
    padded first (lower())"""
    (h, w, c), net = split_input(lower(net))
    passes, errors, warns = [], [], []
    param_words = 0

    def err(i, msg):
        errors.append("layer %d: %s" % (i, msg))

    def check_c(i, ch, what, npos=2):
        """npos: positions of the map these channels belong to (a power of
        two of groups is only needed on maps larger than 1x1)"""
        if ch % P:
            err(i, "%s = %d is not a multiple of 16 (pad with zero channels)" % (what, ch))
        elif npos > 1 and ch // P & (ch // P - 1):
            err(i, "%s = %d: %s/16 = %d is not a power of two (tile_writer ngo_log2)" % (what, ch, what, ch // P))

    def fmap(i, words, what):
        if words > 2 * BANK:
            err(i, "%s tensor %d words > 16384 (two banks): needs row bands" % (what, words))

    def add(name, kind, cyc, ddr, npos, ng, nco, macs):
        p = Pass()
        p.name, p.kind, p.cyc, p.ddr, p.npos, p.ng, p.nco, p.macs = name, kind, cyc, ddr, npos, ng, nco, macs
        passes.append(p)

    shapes = []             # input shape of every layer (residual = input of the previous layer)
    outshape = []           # output shape of every layer (hardware channels)
    if net and not isinstance(net[0], Conv1):
        fmap(0, h * w * (c // P), "input")
    for i, L in enumerate(net):
        shapes.append((h, w, c))
        if i:
            outshape.append((h, w, c))
        if isinstance(L, Conv1):
            if i != 0:
                err(i, "Conv1 (im2col) can only be the first layer")
            check_c(i, L.cout, "Cout")
            if not 1 <= c <= 4:
                err(i, "image channels = %d: im2col_feeder takes 1..4" % c)
            if L.stride not in (1, 2):
                err(i, "Conv1 stride %d: 1 or 2" % L.stride)
            if not (1 <= h <= 255 and 1 <= w <= 255):
                err(i, "image %dx%d: 1..255 per side (8-bit descriptor fields)" % (h, w))
            if w * c > 496:
                err(i, "image row %d x %d = %d bytes > 496 (im2col_feeder row RAM: 31 words + tail)" % (w, c, w * c))
            rw = ceil(w * c, P)
            fmap(i, h * rw, "image")
            cin = c
            h, w = ceil(h, L.stride), ceil(w, L.stride)
            ng, nco = conv1_ng(cin), L.cout // P
            fmap(i, h * w * nco, "output")
            if ng * nco > HALF_W:
                err(i, "conv1 weights %d words > %d" % (ng * nco, HALF_W))
            arr = ceil(h * w, 2) * ng * nco
            ddr = ng * nco * 16 + nco * 5
            param_words += ddr
            add("conv1 3x3 s%d %d->%d (im2col)" % (L.stride, cin, L.cout), "pw", arr + 90, ddr, h * w, ng, nco,
                h * w * 9 * cin * L.cout)
            c = L.cout
        elif isinstance(L, Conv3):
            check_c(i, c, "Cin")
            check_c(i, L.cout, "Cout")
            ngi, nco_all = c // P, L.cout // P
            ng = 9 * ngi
            if ng > MAXNGV:
                err(i, "Conv3 Cin = %d: 9*Cin = %d inputs per neuron > %d (Cin <= 256)" % (c, 9 * c, MAXNGV * P))
            if L.stride not in (1, 2):
                err(i, "Conv3 stride %d: 1 or 2" % L.stride)
            if not (1 <= h <= 255 and 1 <= w <= 255):
                err(i, "map %dx%d: 1..255 per side (8-bit descriptor fields)" % (h, w))
            ho, wo = ceil(h, L.stride), ceil(w, L.stride)
            if L.residual and (L.stride != 1 or i == 0 or shapes[i - 1] != (ho, wo, L.cout)):
                err(i, "residual: the block input (input of the previous layer) must have the output's shape")
            fmap(i, h * w * ngi, "input")
            fmap(i, ho * wo * nco_all, "output")
            per = max(1, min(nco_all, HALF_W // max(ng, 1), HALF_Q))
            per = 1 << int(math.log2(per))
            nparts = ceil(nco_all, per)
            npos = ho * wo
            param_words += ng * nco_all * 16 + nco_all * 5
            for k in range(nparts):
                nco = min(per, nco_all - k * per)
                arr = ceil(npos, 2) * ng * nco
                feed = npos * ng                    # conv3_feeder: one word per cycle
                add("conv3x3 s%d %dx%d %d->%d%s%s" % (L.stride, h, w, c, L.cout, " residual" if L.residual else "",
                                                     " (part %d/%d)" % (k + 1, nparts) if nparts > 1 else ""),
                    "pw", max(arr, feed) + 2 * ng + 40, ng * nco * 16 + nco * 5, npos, ng, nco,
                    npos * 9 * c * nco * P)
            h, w, c = ho, wo, L.cout
        elif isinstance(L, Pool):
            check_c(i, c, "C", h * w)
            ng = c // P
            if L.kind not in ("max", "avg"):
                err(i, "Pool kind %r: max or avg" % L.kind)
            if L.k not in (2, 3) or L.stride not in (1, 2) or L.pad not in (0, 1):
                err(i, "Pool %dx%d stride %d pad %d: window 2 or 3, stride 1 or 2, pad 0 or 1" % (L.k, L.k, L.stride, L.pad))
            if ng > 63:
                err(i, "Pool on %d channels > 1008 (6-bit group field)" % c)
            if not (1 <= h <= 255 and 1 <= w <= 255):
                err(i, "map %dx%d: 1..255 per side (8-bit descriptor fields)" % (h, w))
            if not (1 <= L.mul <= 255 and 0 <= L.sh <= 15):
                err(i, "Pool mul %d sh %d: mul 1..255, sh 0..15" % (L.mul, L.sh))
            ho, wo = L.out(h, w)
            if ho < 1 or wo < 1:
                err(i, "Pool window larger than the %dx%d map" % (h, w))
            fmap(i, ho * wo * ng, "output")
            add("%s pool %dx%d s%d %dx%dx%d" % (L.kind, L.k, L.k, L.stride, h, w, c), "pool",
                ho * wo * ng * L.k * L.k + 40, 0, ho * wo, ng, 0, 0)
            h, w = ho, wo
        elif isinstance(L, Upsample):
            ng = c // P
            if L.factor != 2:
                err(i, "Upsample factor %d: only 2" % L.factor)
            if ng > 63:
                err(i, "Upsample on %d channels > 1008 (6-bit group field)" % c)
            if not (2 * h <= 255 and 2 * w <= 255):
                err(i, "Upsample to %dx%d: 255 per side at most (8-bit descriptor fields)" % (2 * h, 2 * w))
            h, w = 2 * h, 2 * w
            fmap(i, h * w * ng, "output")
            add("upsample 2x -> %dx%dx%d" % (h, w, c), "copy", h * w * ng + 40, 0, h * w, ng, 0, 0)
        elif isinstance(L, Concat):
            j = L.ref(i)
            if not 0 <= j < i:
                err(i, "Concat src %d: an earlier layer (0..%d)" % (L.src, i - 1))
                continue
            hr, wr, cr = outshape[j]
            if (hr, wr) != (h, w):
                err(i, "Concat: map %dx%d and layer %d's %dx%d differ" % (h, w, j, hr, wr))
            ga, gb = c // P, cr // P
            ngo = ga + gb
            if h * w > 1:
                ngo = 1 << (ngo - 1).bit_length()
            if ngo > 63:
                err(i, "Concat: %d groups > 63 (6-bit group field): %d channels at most" % (ngo, 63 * P))
            fmap(i, h * w * ngo, "output")
            add("concat %dx%d %d + layer %d's %d -> %d" % (h, w, c, j, cr, ngo * P), "copy",
                h * w * ngo + 80, 0, h * w, ngo, 0, 0)
            c = ngo * P
        elif isinstance(L, (PW, Linear)):
            if isinstance(L, Linear) and (h, w) != (1, 1):
                err(i, "Linear needs a 1x1 map (put GDConv before it)")
            check_c(i, c, "Cin", h * w)
            if not isinstance(L, Linear):
                check_c(i, L.cout, "Cout", h * w)
            elif L.cout % P:
                err(i, "Cout = %d is not a multiple of 16" % L.cout)
            ng, nco_all = c // P, L.cout // P
            if ng < 2:
                err(i, "Cin = %d < 32: a 1x1 pass needs ng >= 2 (tile_writer)" % c)
            if ng > MAXNGV:
                err(i, "Cin = %d > %d (pair vector buffer, dwpw_engine.v MAXNGV)" % (c, MAXNGV * P))
            # split along Cout so each pass's weights fit one half buffer
            per = max(1, min(nco_all, HALF_W // max(ng, 1), HALF_Q))
            per = 1 << int(math.log2(per))
            nparts = ceil(nco_all, per)
            npos = h * w
            fmap(i, npos * nco_all, "output")
            if isinstance(L, PW) and L.residual:
                err(i, "a 1x1 cannot add its own input: the residual must be in other banks than the pass input (fmap_mem.v)")
            words = ng * nco_all * 16 + nco_all * 5
            param_words += words
            for k in range(nparts):
                nco = min(per, nco_all - k * per)
                arr = ceil(npos, 2) * ng * nco
                add("%s %dx%d %d->%d%s" % ("linear" if isinstance(L, Linear) else "1x1", h, w, c, L.cout,
                                           " (part %d/%d)" % (k + 1, nparts) if nparts > 1 else ""),
                    "pw", arr + 2 * ng + 40, ng * nco * 16 + nco * 5, npos, ng, nco, npos * c * nco * P)
            c = L.cout
        elif isinstance(L, DWPW):
            check_c(i, c, "Cin")
            check_c(i, L.cout, "Cout")
            ng, nco = c // P, L.cout // P
            if ng > 32:
                err(i, "depthwise on %d channels > 512 (32 groups per half buffer)" % c)
            if (w + 2) * ng > LBDEPTH:
                err(i, "line buffer: (W+2)*Cin/16 = %d*%d = %d > %d" % (w + 2, ng, (w + 2) * ng, LBDEPTH))
            if ng * nco > HALF_W:
                err(i, "pw weights %d words > %d: split the project layer" % (ng * nco, HALF_W))
            if w + 2 > 255 or h + 2 > 255:
                err(i, "map %dx%d: padded size > 255 (8-bit descriptor fields)" % (h, w))
            if L.residual and (L.stride != 1 or i == 0 or shapes[i - 1] != (h, w, L.cout)):
                err(i, "residual: the block input (input of the previous layer) must have the output's shape")
            ho, wo = ceil(h, L.stride), ceil(w, L.stride)
            if L.bands == 1:
                fmap(i, h * w * ng, "input")
            if L.bands == 1 or L.stride == 2:
                fmap(i, ho * wo * nco, "output")
            words = ng * nco * 16 + nco * 5 + ng * 14
            param_words += words
            for b in range(L.bands):
                if L.bands == 1:
                    hin, hout = h, ho
                else:           # MobileFaceNet block-1 banding (gen_mfn.c)
                    if L.stride == 1:           # producer: E rows a..b of band b
                        R = ho // L.bands // 2
                        a = max(0, 2 * R * b - 1)
                        e = 2 * R * (b + 1) - 1
                        hout = e - a + 1
                        hin = hout + 2 - (1 if a == 0 else 0) - (1 if e == h - 1 else 0)
                    else:                       # consumer over the band
                        hout = ho // L.bands
                        hin = 2 * hout + (1 if b else 0)
                wp = w + 2
                pairs_row = ceil(wo, 2)
                arr = ceil(hout * wo, 2) * ng * nco
                if L.stride == 1:
                    beats = wp * (hin + 2) * ng
                    cyc = max(beats, 2 * wp * ng + arr) + TAIL_DW
                else:
                    # every output row: one padded row with no output, then
                    # one where the dw produces the row and the array computes it
                    cyc = hout * (wp * ng + max(wp * ng, pairs_row * ng * nco)) + TAIL_DW
                add("dw3x3 s%d %dx%dx%d + 1x1 ->%d%s%s" % (L.stride, h, w, c, L.cout,
                                                         " residual" if L.residual else "",
                                                         " (band %d/%d)" % (b + 1, L.bands) if L.bands > 1 else ""),
                    "dw+pw", cyc, words, hout * wo, ng, nco, hout * wo * c * (9 + L.cout))
            h, w, c = ho, wo, L.cout
        elif isinstance(L, GDConv):
            check_c(i, c, "C")
            ng = c // P
            if not 3 <= ng <= 32:
                err(i, "GDConv needs 48..512 channels (ng 3..32)")
            if h * w > 255:
                err(i, "GDConv over %d positions > 255" % (h * w))
            if ceil(h * w * ng, 16) > HALF_W:
                err(i, "GDConv weights %d words > %d" % (ceil(h * w * ng, 16), HALF_W))
            words = ceil(h * w * ng, 16) * 16 + ng * 5
            param_words += words
            add("GDConv %dx%d %d" % (h, w, c), "gdconv", h * w * ng + 65, words, 1, ng, 0, h * w * c)
            h = w = 1
        else:
            err(i, "unknown layer %r" % L)
    outshape.append((h, w, c))
    if len(passes) > NDESC:
        errors.append("%d passes > %d descriptors" % (len(passes), NDESC))
    return passes, errors, warns, param_words


def stalls(passes):
    """parameter wait: pass p+1's parameters load during pass p."""
    st = [math.ceil(passes[0].ddr / DDR_RATE)]
    for a, b in zip(passes, passes[1:]):
        st.append(max(0, math.ceil(b.ddr / DDR_RATE) - a.cyc))
    return st


def load(arg):
    """-> (layer list, title): an EXAMPLES name or a Python file with NET = [...]"""
    if arg in EXAMPLES:
        build, title = EXAMPLES[arg]
        return build(), title
    import importlib.util
    # the file imports v4_plan: run as a script, make that the same module
    # (else its layer classes are not the ones plan() checks against)
    sys.modules.setdefault("v4_plan", sys.modules[__name__])
    spec = importlib.util.spec_from_file_location("netdef", arg)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m.NET, arg


def report(name):
    net, title = load(name)
    passes, errors, warns, pwords = plan(net)
    print("%s -- %s" % (name, title))
    print("%3s %-44s %8s %7s %8s" % ("#", "pass", "cycles", "DDR w", "wait"))
    st = stalls(passes)
    for k, (p, s) in enumerate(zip(passes, st)):
        print("%3d %-44s %8d %7d %8d" % (k, p.name, p.cyc, p.ddr, s))
    tot, wait = sum(p.cyc for p in passes), sum(st)
    macs = sum(p.macs for p in passes)
    print("passes %d, MAC %.1f M, parameter image %d words = %d KB" % (len(passes), macs / 1e6, pwords, pwords * 16 // 1024))
    print("ESTIMATE: %d compute + %d parameter wait = %d cycles = %.3f ms @199.34 MHz, %.3f ms @189.20 MHz" %
          (tot, wait, tot + wait, (tot + wait) / 199.34e3, (tot + wait) / 189.20e3))
    for e in errors:
        print("ERROR", e)
    print("rules: %s" % ("OK" if not errors else "%d violated" % len(errors)))
    return 0 if not errors else 1


# measured per-pass cycles, docs/mfn_rtl_run.log (tb_v4_core_mfn, 128 embedding)
MEASURED = [12634, 13080, 7040, 13976, 7040, 13976, 7040, 13976, 7040, 12591, 13112, 12591, 13112, 12591,
            13112, 12591, 13112, 25135, 18177, 12599, 13176, 12599, 13176, 12599, 13176, 12599, 13176,
            12599, 13176, 12599, 13176, 25143, 9733, 3254, 3607, 3254, 3607, 6454, 1633, 326]


def calibrate():
    passes, errors, _, pw = plan(mobilefacenet(128))
    # gen_mfn orders the banded pair as A0 B0 A1 B1 ...; the planner lists A0..A3 B0..B3
    order = [0] + [x for k in range(4) for x in (1 + k, 5 + k)] + list(range(9, len(passes)))
    passes = [passes[k] for k in order]
    print("%3s %-44s %8s %8s %7s" % ("#", "pass", "measured", "estimate", "error"))
    worst = 0
    for k, (p, m) in enumerate(zip(passes, MEASURED)):
        e = (p.cyc - m) / m * 100
        worst = max(worst, abs(e))
        print("%3d %-44s %8d %8d %+6.1f%%" % (k, p.name, m, p.cyc, e))
    tm, te = sum(MEASURED), sum(p.cyc for p in passes)
    print("total measured %d, estimate %d (%+.2f%%), worst pass %.1f%%; passes %d (measured 40); "
          "parameter image %d words (gen_mfn: 64080)" % (tm, te, (te - tm) / tm * 100, worst, len(passes), pw))


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--calibrate":
        calibrate()
    elif len(sys.argv) == 2 and (sys.argv[1] in EXAMPLES or sys.argv[1].endswith(".py")):
        sys.exit(report(sys.argv[1]))
    else:
        print(__doc__)
        for k, (_, t) in EXAMPLES.items():
            print("  %-10s %s" % (k, t))
