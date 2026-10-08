// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// ================================================================
// FPGA-Neural v4 -- application helpers around an inference: preparing
// the input image and using the output. Pure C, no ESP-IDF calls, so
// the same file is compiled on the PC and checked against the Python
// tools used for training (hardware/v4/model/align_face.py,
// espdl_to_v4.py image_to_int8).
// ================================================================
#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FPGA_V4_IN_SIZE 112

// Input image of the networks (MobileFaceNet / v4_qat.py): 112x112x3
// INT8, HWC, channels B, G, R, q = round((p - 127.5) / 127.5 * 64)
// (exponent -6), round half up, as espdl_to_v4.image_to_int8().
void fpga_v4_rgb_to_int8(const uint8_t *rgb112, int8_t *out);

// Face alignment + conversion in one pass: `rgb` is the camera frame
// (w x h, RGB888, row stride w*3), `lm` the 5 landmarks of the face
// detector in frame pixels {x,y} x {left eye, right eye, nose tip, left
// mouth corner, right mouth corner}. Least-squares similarity transform
// onto the ArcFace template, bilinear sampling (pixels outside the frame
// are black), then the INT8 conversion above. Same geometry as
// align_face.py (Pillow AFFINE, BILINEAR).
void fpga_v4_align_face_int8(const uint8_t *rgb, int w, int h, const float lm[10], int8_t *out);

// Cosine similarity of two INT8 vectors (embeddings): the output
// exponent cancels, so it works on the raw integers.
float fpga_v4_cosine(const int8_t *a, const int8_t *b, int n);

// Index of the largest value (a classifier's class), first one on ties.
int fpga_v4_argmax(const int8_t *v, int n);

// Probabilities from INT8 logits at exponent e_out (value = q * 2^e_out).
void fpga_v4_softmax(const int8_t *q, int n, int e_out, float *p);

// Closest enrolled embedding: db = n_db embeddings of emb_len values,
// one after the other. Returns its index (-1 if n_db == 0), *score = cosine.
int fpga_v4_db_best(const int8_t *db, int n_db, int emb_len, const int8_t *query, float *score);

#ifdef __cplusplus
}
#endif
