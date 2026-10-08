#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Checks fpga_neural_v4_app.c on the PC against the Python preprocessing
used for training (align_face.py + espdl_to_v4.image_to_int8) on 20
synthetic frames with faces of random position, size and roll (some
partly outside the frame).
  python3 test_v4_app.py        (needs gcc, numpy, Pillow)
"""
import os
import random
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
V4 = os.path.join(HERE, "../../../../../hardware/v4/model")
sys.path.insert(0, V4)
import align_face  # noqa: E402
import espdl_to_v4  # noqa: E402


def frame(w, h, rnd):
    """smooth synthetic frame with texture and noise (RGB)"""
    y, x = np.mgrid[0:h, 0:w]
    img = np.zeros((h, w, 3))
    for ch in range(3):
        img[:, :, ch] = 128 + 60 * np.sin(x / rnd.uniform(5, 30) + ch) * np.cos(y / rnd.uniform(5, 30))
    img += np.array([rnd.gauss(0, 12) for _ in range(w * h * 3)]).reshape(h, w, 3)
    return np.clip(img, 0, 255).astype(np.uint8)


def main():
    rnd = random.Random(5)
    d = tempfile.mkdtemp()
    exe = os.path.join(d, "t")
    subprocess.run(["gcc", "-O2", "-I", os.path.join(HERE, "../include"), "-o", exe,
                    os.path.join(HERE, "test_v4_app_main.c"), os.path.join(HERE, "../fpga_neural_v4_app.c"), "-lm"],
                   check=True)
    worst, tot_diff, n = 0, 0, 0
    for case in range(20):
        w, h = rnd.choice([(320, 240), (640, 480), (240, 240)])
        rgb = frame(w, h, rnd)
        # a face somewhere, random size and roll, some partly outside the frame
        cx, cy, sc, ang = rnd.uniform(0, w), rnd.uniform(0, h), rnd.uniform(0.6, 3.0), rnd.uniform(-0.4, 0.4)
        T = align_face.TEMPLATE - 56
        R = np.array([[np.cos(ang), -np.sin(ang)], [np.sin(ang), np.cos(ang)]])
        lm = (T @ R.T) * sc + [cx, cy] + np.array([rnd.gauss(0, 1.5) for _ in range(10)]).reshape(5, 2)
        Image.fromarray(rgb).save(os.path.join(d, "f.png"))
        al = align_face.align(Image.open(os.path.join(d, "f.png")).convert("RGB"), [tuple(p) for p in lm])
        al.save(os.path.join(d, "a.png"))
        ref = np.frombuffer(espdl_to_v4.image_to_int8(os.path.join(d, "a.png")), np.int8)
        open(os.path.join(d, "f.rgb"), "wb").write(rgb.tobytes())
        subprocess.run([exe, os.path.join(d, "f.rgb"), str(w), str(h)] + ["%.6f" % v for v in lm.reshape(-1)] +
                       [os.path.join(d, "o.bin")], check=True)
        got = np.frombuffer(open(os.path.join(d, "o.bin"), "rb").read(), np.int8)
        diff = np.abs(got.astype(int) - ref.astype(int))
        worst = max(worst, int(diff.max()))
        tot_diff += int((diff > 0).sum())
        n += diff.size
    print("alignment + INT8: 20 frames, %d of %d values differ from align_face.py + image_to_int8, max difference %d"
          % (tot_diff, n, worst))
    bad = 0
    # rgb_to_int8 on a frame already 112x112
    for case in range(5):
        rgb = frame(112, 112, rnd)
        Image.fromarray(rgb).save(os.path.join(d, "r.png"))
        ref = np.frombuffer(espdl_to_v4.image_to_int8(os.path.join(d, "r.png")), np.int8)
        open(os.path.join(d, "r.rgb"), "wb").write(rgb.tobytes())
        subprocess.run([exe, os.path.join(d, "r.rgb"), os.path.join(d, "r.bin")], check=True)
        got = np.frombuffer(open(os.path.join(d, "r.bin"), "rb").read(), np.int8)
        bad += int((got != ref).sum())
    print("rgb_to_int8: 5 frames, %d values differ from image_to_int8" % bad)
    # cosine / argmax / softmax / db_best against numpy
    vbad = 0
    for case in range(20):
        n = rnd.choice([16, 48, 128, 512])
        e = rnd.randint(-6, -1)
        a = np.array([rnd.randint(-128, 127) for _ in range(n)], np.int8)
        db = np.array([rnd.randint(-128, 127) for _ in range(n * 7)], np.int8).reshape(7, n)
        a.tofile(os.path.join(d, "a.bin"))
        db.tofile(os.path.join(d, "b.bin"))
        out = subprocess.run([exe, "--vec", os.path.join(d, "a.bin"), os.path.join(d, "b.bin"), str(n), str(e)],
                             check=True, capture_output=True, text=True).stdout.split("\n")
        A, B = a.astype(np.float64), db.astype(np.float64)
        cos = A @ B[0] / (np.linalg.norm(A) * np.linalg.norm(B[0]))
        z = np.exp((A - A.max()) * 2.0 ** e)
        sm = z / z.sum()
        cs = B @ A / (np.linalg.norm(B, axis=1) * np.linalg.norm(A))
        ok = (abs(float(out[0].split()[1]) - cos) < 1e-5 and int(out[1].split()[1]) == int(np.argmax(a))
              and np.allclose([float(v) for v in out[2].split()[1:]], sm, rtol=1e-5, atol=1e-7)
              and int(out[3].split()[1]) == int(np.argmax(cs)) and abs(float(out[3].split()[2]) - cs.max()) < 1e-5)
        vbad += not ok
    print("cosine / argmax / softmax / db_best: 20 cases, %d different from numpy" % vbad)
    return 1 if bad or vbad else 0


if __name__ == "__main__":
    sys.exit(main())
