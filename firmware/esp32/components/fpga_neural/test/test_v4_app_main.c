// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// PC test driver for fpga_neural_v4_app.c (see test_v4_app.py)
#include <stdio.h>
#include <stdlib.h>
#include "fpga_neural_v4_app.h"

// other modes:
//   rgb112.rgb out.int8          fpga_v4_rgb_to_int8
//   --vec a.int8 b.int8 n e_out  prints cosine, argmax, softmax of a, db_best of b (rows of n) vs a
static int8_t *load(const char *p, size_t *n)
{
    FILE *f = fopen(p, "rb");
    if (!f) exit(1);
    fseek(f, 0, SEEK_END); *n = (size_t)ftell(f); fseek(f, 0, SEEK_SET);
    int8_t *b = malloc(*n);
    if (fread(b, 1, *n, f) != *n) exit(1);
    fclose(f);
    return b;
}

int main(int argc, char **argv)
{
    if (argc == 3) {
        size_t n;
        int8_t *in = load(argv[1], &n);
        static int8_t out[112 * 112 * 3];
        if (n != sizeof out) return 1;
        fpga_v4_rgb_to_int8((const uint8_t *)in, out);
        FILE *f = fopen(argv[2], "wb");
        fwrite(out, 1, sizeof out, f);
        fclose(f);
        return 0;
    }
    if (argc == 6) {
        size_t na, nb;
        int8_t *a = load(argv[2], &na), *b = load(argv[3], &nb);
        int n = atoi(argv[4]), e = atoi(argv[5]);
        printf("cosine %.7f\n", fpga_v4_cosine(a, b, n));
        printf("argmax %d\n", fpga_v4_argmax(a, n));
        float *p = malloc(sizeof(float) * n);
        fpga_v4_softmax(a, n, e, p);
        printf("softmax");
        for (int i = 0; i < n; i++) printf(" %.7g", p[i]);
        float sc;
        int k = fpga_v4_db_best(b, (int)(nb / n), n, a, &sc);
        printf("\ndb_best %d %.7f\n", k, sc);
        return 0;
    }
    if (argc != 15) { fprintf(stderr, "usage: frame.rgb w h x1 y1 .. x5 y5 out.int8\n"); return 2; }
    int w = atoi(argv[2]), h = atoi(argv[3]);
    float lm[10];
    for (int k = 0; k < 10; k++) lm[k] = (float)atof(argv[4 + k]);
    uint8_t *rgb = malloc((size_t)w * h * 3);
    FILE *f = fopen(argv[1], "rb");
    if (!f || fread(rgb, 1, (size_t)w * h * 3, f) != (size_t)w * h * 3) return 1;
    fclose(f);
    static int8_t out[112 * 112 * 3];
    fpga_v4_align_face_int8(rgb, w, h, lm, out);
    f = fopen(argv[14], "wb");
    fwrite(out, 1, sizeof out, f);
    fclose(f);
    return 0;
}
