// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// FPGA-Neural v4 application helpers -- see include/fpga_neural_v4_app.h.
#include <math.h>
#include "fpga_neural_v4_app.h"

// ArcFace 112x112 template (align_face.py TEMPLATE, ESP-DL FeatImagePreprocessor)
static const float TEMPLATE[10] = {
    38.2946f, 51.6963f, 73.5318f, 51.5014f, 56.0252f, 71.7366f, 41.5493f, 92.3655f, 70.7299f, 92.2041f,
};

static int8_t q_pixel(double p)
{
    // round((p - 127.5) / 127.5 * 64), half up; |value| <= 64 so no saturation
    return (int8_t)floor((p - 127.5) / 127.5 * 64.0 + 0.5);
}

void fpga_v4_rgb_to_int8(const uint8_t *rgb112, int8_t *out)
{
    for (int i = 0; i < FPGA_V4_IN_SIZE * FPGA_V4_IN_SIZE; i++) {
        out[3 * i + 0] = q_pixel(rgb112[3 * i + 2]);   // B
        out[3 * i + 1] = q_pixel(rgb112[3 * i + 1]);   // G
        out[3 * i + 2] = q_pixel(rgb112[3 * i + 0]);   // R
    }
}

// Pillow's bilinear sample for 8-bit images (libImaging/Geometry.c):
// a point outside the frame gives 0 (black), inside the 4 neighbours are
// clamped to the border, coordinates refer to pixel centers and the
// result is truncated to an integer (checked against Pillow 12, test/).
static int sample(const uint8_t *rgb, int w, int h, double x, double y, int ch)
{
    if (x < 0 || y < 0 || x >= w || y >= h) return 0;
    x -= 0.5; y -= 0.5;
    int x0 = (int)floor(x), y0 = (int)floor(y);
    double dx = x - x0, dy = y - y0;
    double v[2][2];
    for (int j = 0; j < 2; j++)
        for (int i = 0; i < 2; i++) {
            int xx = x0 + i, yy = y0 + j;
            xx = xx < 0 ? 0 : (xx >= w ? w - 1 : xx);
            yy = yy < 0 ? 0 : (yy >= h ? h - 1 : yy);
            v[j][i] = rgb[((size_t)yy * w + xx) * 3 + ch];
        }
    double top = v[0][0] + (v[0][1] - v[0][0]) * dx;
    double bot = v[1][0] + (v[1][1] - v[1][0]) * dx;
    return (int)floor(top + (bot - top) * dy);
}

void fpga_v4_align_face_int8(const uint8_t *rgb, int w, int h, const float lm[10], int8_t *out)
{
    // least squares: source = [a -s; s a] * template + t
    double mx = 0, my = 0, mu = 0, mv = 0;
    for (int k = 0; k < 5; k++) { mx += TEMPLATE[2 * k]; my += TEMPLATE[2 * k + 1]; mu += lm[2 * k]; mv += lm[2 * k + 1]; }
    mx /= 5; my /= 5; mu /= 5; mv /= 5;
    double sxx = 0, sa = 0, ss = 0;
    for (int k = 0; k < 5; k++) {
        double x = TEMPLATE[2 * k] - mx, y = TEMPLATE[2 * k + 1] - my;
        double u = lm[2 * k] - mu, v = lm[2 * k + 1] - mv;
        sxx += x * x + y * y; sa += x * u + y * v; ss += x * v - y * u;
    }
    double a = sa / sxx, s = ss / sxx;
    double tx = mu - a * mx + s * my, ty = mv - s * mx - a * my;
    for (int r = 0; r < FPGA_V4_IN_SIZE; r++)
        for (int c = 0; c < FPGA_V4_IN_SIZE; c++) {
            double xc = c + 0.5, yc = r + 0.5;            // output pixel center
            double xs = a * xc - s * yc + tx, ys = s * xc + a * yc + ty;
            int8_t *o = out + ((size_t)r * FPGA_V4_IN_SIZE + c) * 3;
            for (int ch = 0; ch < 3; ch++) {
                o[2 - ch] = q_pixel(sample(rgb, w, h, xs, ys, ch));   // RGB -> BGR
            }
        }
}

float fpga_v4_cosine(const int8_t *a, const int8_t *b, int n)
{
    int32_t ab = 0, aa = 0, bb = 0;
    for (int i = 0; i < n; i++) { ab += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i]; }
    return (float)(ab / (sqrt((double)aa) * sqrt((double)bb) + 1e-9));
}

int fpga_v4_argmax(const int8_t *v, int n)
{
    int best = 0;
    for (int i = 1; i < n; i++)
        if (v[i] > v[best]) best = i;
    return best;
}

void fpga_v4_softmax(const int8_t *q, int n, int e_out, float *p)
{
    int m = q[fpga_v4_argmax(q, n)];
    double scale = ldexp(1.0, e_out), sum = 0;
    for (int i = 0; i < n; i++) { p[i] = (float)exp((q[i] - m) * scale); sum += p[i]; }
    for (int i = 0; i < n; i++) p[i] = (float)(p[i] / sum);
}

int fpga_v4_db_best(const int8_t *db, int n_db, int emb_len, const int8_t *query, float *score)
{
    int best = -1;
    float bs = -2.0f;
    for (int k = 0; k < n_db; k++) {
        float c = fpga_v4_cosine(db + (size_t)k * emb_len, query, emb_len);
        if (c > bs) { bs = c; best = k; }
    }
    if (score) *score = bs;
    return best;
}
