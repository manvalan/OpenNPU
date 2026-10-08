#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""
v4 G-esteso -- MobileFaceNet cycle model, calibrated on RTL measurements.

Every per-layer cycle count comes from the rules below, which reproduce
the cycle counts measured in RTL simulation (tb_dwpw_engine.v, 16x16
array, bit-exact runs):
    14x14 dw256 s1 -> 128 : measured 13,144  model 13,144
    56->28 dw128 s2 -> 64 : measured 26,914  model 26,914 (+-2)
    28x28 pw-only 64->128 : measured 12,568  model 12,568
    7x7 pw-only 128->512  : measured  6,432  model  6,432
Rules (dwpw_engine.v):
    array cycles  = ceil(npos/2) * ceil(Cout/16) * ceil(Cin/16)
    input beats   = Hp * Wp * ceil(Cin/16)      (padded input, 16 ch/beat)
    fused dw->pw  = max(input beats, 2*Wp*ng (line-buffer fill) + array) + TAIL
    pw only       = array + 2*ng + 16
Layers the RTL does not implement yet are marked PROJECTED (conv1 via
im2col on the same array, GDConv 7x7, the final linear layer).

Two schedules:
    A  layer by layer, exactly the engine that exists today: every layer
       runs alone; depthwise fused only with the 1x1 that follows it.
    B  bottleneck fused (expand 1x1 -> dw -> project 1x1 sharing the array
       row by row): the array is the only bottleneck, the input-bound
       stride-2 case disappears. NOT built yet -> projection.
Time = cycles / Fmax. Fmax is NOT measured in context yet (step 3), so
several clocks are shown.
"""
import math

P, PCO = 16, 16
TAIL = 88        # measured (14x14 case: 13,144 - 512 fill - 12,544 array)
# pw-only overhead = first pair's vectors (2*ng beats) + 16 pipeline cycles,
# measured: 28x28 64->128: 12,568 = 12,544 + 24 (ng=4); 7x7 128->512:
# 6,432 = 6,400 + 32 (ng=8)
def tail_pw(ng):
    return 2 * ng + 16
ESP32_MS = 248.8 # Espressif ESP-DL MFN_S8_V1 on ESP32-S3

def ceil(a, b):
    return -(-a // b)

layers = []   # dicts: name, kind, macs, cycles_A, array_cycles, note

def pw(name, hw, cin, cout, note=""):
    npos = hw * hw
    arr = ceil(npos, 2) * ceil(cout, PCO) * ceil(cin, P)
    layers.append(dict(name=name, kind="pw", macs=npos * cin * cout,
                       A=arr + tail_pw(ceil(cin, P)), arr=arr, note=note))

def dwpw(name, hw_in, c, stride, cout):
    """3x3 depthwise (pad 1) on hw_in x hw_in x c, then 1x1 to cout."""
    hw_out = hw_in // stride
    wp = hw_in + 2
    ng = ceil(c, P)
    npos = hw_out * hw_out
    arr = ceil(npos, 2) * ceil(cout, PCO) * ng
    beats = wp * wp * ng
    cyc = max(beats, 2 * wp * ng + arr) + TAIL
    layers.append(dict(name=name, kind="dw+pw", dwmacs=npos * c * 9,
                       macs=npos * c * 9 + npos * c * cout,
                       A=cyc, arr=arr, note="input-bound" if beats > 2 * wp * ng + arr else ""))

# ---- conv1: 3x3 s2, 3 -> 64 on 112x112 (im2col: 27 inputs -> 2 groups of 16) ----
npos = 56 * 56
arr = ceil(npos, 2) * ceil(64, PCO) * ceil(27, P)
layers.append(dict(name="conv1 3x3 s2 3->64", kind="conv", macs=npos * 27 * 64,
                   A=arr + tail_pw(2), arr=arr, note="pw-only rule; im2col feeder PROJECTED"))

# ---- dw1 (56x56x64 s1) fused with the first bottleneck's expand 64->128 ----
dwpw("dw1 56 s1 64 + b1.expand ->128", 56, 64, 1, 128)

# ---- bottlenecks: (t, c, n, s) ----
cfg = [(2, 64, 5, 2), (4, 128, 1, 2), (2, 128, 6, 1), (4, 128, 1, 2), (2, 128, 2, 1)]
hw, cin = 56, 64
first = True
for t, c, n, s in cfg:
    for i in range(n):
        stride = s if i == 0 else 1
        cexp = cin * t
        tag = f"b{len([l for l in layers if 'project' in l['name']]) + 1}"
        if not first:
            pw(f"{tag}.expand {hw} {cin}->{cexp}", hw, cin, cexp)
        first = False
        dwpw(f"{tag}.dw s{stride} + project {cexp}->{c}", hw, cexp, stride, c)
        hw //= stride
        cin = c

# ---- tail ----
pw("conv1x1 7 128->512", 7, 128, 512)
layers.append(dict(name="GDConv 7x7 512", kind="gdconv", macs=7 * 7 * 512, dwmacs=7 * 7 * 512,
                   A=ceil(7 * 7 * 512, P) + 30, arr=ceil(7 * 7 * 512, P),
                   note="PROJECTED (16 lanes, 1 MAC each per cycle)"))
layers.append(dict(name="linear 512->128", kind="fc", macs=512 * 128,
                   A=ceil(128, PCO) * ceil(512, P) + tail_pw(32),
                   arr=ceil(128, PCO) * ceil(512, P), note="PROJECTED (1 position, half the array idle)"))

tot_macs = sum(l["macs"] for l in layers)
# array MACs (1x1, conv1, linear) vs depthwise-lane MACs (3x3 dw, GDConv)
dw_macs = sum(l.get("dwmacs", 0) for l in layers)
arr_macs = tot_macs - dw_macs
tot_A = sum(l["A"] for l in layers)
tot_B = sum(l["arr"] for l in layers) + TAIL * len(layers)

print(f"{'layer':44s} {'MACs':>11s} {'array cyc':>10s} {'sched A cyc':>11s}  note")
for l in layers:
    print(f"{l['name']:44s} {l['macs']:11,d} {l['arr']:10,d} {l['A']:11,d}  {l['note']}")
print(f"{'TOTAL':44s} {tot_macs:11,d} {sum(l['arr'] for l in layers):10,d} {tot_A:11,d}")
print()
print(f"MACs total: {tot_macs/1e6:.1f} M (paper: ~221M): array {arr_macs/1e6:.1f} M, depthwise lanes {dw_macs/1e6:.1f} M")
print(f"Schedule A (layer by layer, today's engine): {tot_A:,} cycles, "
      f"array utilization {arr_macs/(tot_A*2*P*PCO)*100:.1f}%")
print(f"Schedule B (bottleneck fused, projection):   {tot_B:,} cycles, "
      f"array utilization {arr_macs/(tot_B*2*P*PCO)*100:.1f}%")
print()
print(f"{'Fmax':>8s} {'A ms':>8s} {'A x':>7s} {'B ms':>8s} {'B x':>7s}")
for f in (125, 150, 155, 175, 200, 225):
    ta = tot_A / (f * 1e6) * 1e3
    tb = tot_B / (f * 1e6) * 1e3
    print(f"{f:5d}MHz {ta:8.3f} {ESP32_MS/ta:7.1f} {tb:8.3f} {ESP32_MS/tb:7.1f}")
