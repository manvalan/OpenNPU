#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Aligns a face to the 112x112 input of MobileFaceNet from 5 landmarks
(left eye, right eye, nose tip, left and right mouth corner, in pixels of
the source image): least-squares similarity transform onto the standard
ArcFace template, the same template ESP-DL's FeatImagePreprocessor uses.

  align_face.py photo.jpg x1 y1 x2 y2 x3 y3 x4 y4 x5 y5 out.png

On the ESP32 the landmarks come from the face detector; here they are
typed by hand, e.g. for esp-dl examples/human_face_recognition/faces/bill1.jpg:
  130 110  183 109  157 138  138 160  177 159
Needs numpy and Pillow.
"""
import sys

import numpy as np
from PIL import Image

TEMPLATE = np.array([[38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366],
                     [41.5493, 92.3655], [70.7299, 92.2041]])


def align(img, landmarks):
    a_rows, b = [], []
    for (x, y), (u, v) in zip(TEMPLATE, landmarks):
        a_rows += [[x, -y, 1, 0], [y, x, 0, 1]]
        b += [u, v]
    a, s, tx, ty = np.linalg.lstsq(np.array(a_rows), np.array(b, float), rcond=None)[0]
    # output pixel (x, y) samples source (a x - s y + tx, s x + a y + ty)
    return img.transform((112, 112), Image.AFFINE, (a, -s, tx, s, a, ty), resample=Image.BILINEAR)


if __name__ == "__main__":
    if len(sys.argv) != 13:
        print(__doc__)
        sys.exit(2)
    pts = list(map(float, sys.argv[2:12]))
    align(Image.open(sys.argv[1]).convert("RGB"), list(zip(pts[0::2], pts[1::2]))).save(sys.argv[12])
