// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// ============================================================
// v4 -- MobileFaceNet INT8 golden model + v4_core memory images.
//
// Builds MobileFaceNet (Chen et al. 2018, table 1) with deterministic
// pseudo-random INT8 weights, runs it in plain integer C with EXACTLY
// the arithmetic of the RTL (depthwise_mac3x3, pw_array_packed,
// requant_act, tile_writer's saturating residual add), and writes:
//   desc.hex    one 192-bit descriptor per engine pass (v4_core.v)
//   wmem.hex    pointwise weights, 2048-bit words (cot*ng + g)
//   dwwmem.hex  depthwise weights, 1152-bit words (one per 16-ch group)
//   dwqmem.hex  depthwise requant {alpha, bias}, 640-bit words
//   pwqmem.hex  pointwise requant {alpha, bias}, 640-bit words
//   fmap_init.hex  "@addr data" initial feature-map memory (conv1 input,
//                  im2col'd: 27 values + 5 zeros = 2 words per position)
//   expect.txt  per pass: "pass n out_base words" + the expected words
//   golden_ref.txt the final embedding (128 values, or the pack's size)
//
// Weights are random (timing does not depend on values); requant shifts
// are chosen per layer from the real accumulator statistics so that the
// activations stay in range instead of saturating everywhere.
//
// Parameter packs (V4-F2): with --params <pack> the layers are read from a
// pack written by model/espdl_to_v4.py (a real ESP-DL model) instead of
// being drawn at random, --image <file> gives the 112x112x3 INT8 input,
// --dump-params <pack> writes the layers used (random or loaded) in the
// same format. Pack (little endian): "MFNP", u32 version 1, u32 embedding
// size (128 or 512), u32 record count; per layer, in network order:
//   u8 kind (0 pointwise, 1 depthwise 3x3, 2 GDConv 7x7), u8 act, u8 sh,
//   u8 ash, u16 cin, u16 cout, then the weights (pw: cout*cin, [co][ci];
//   dw: c*9, [ch][kr*3+kc]; GDConv: 49*512, [kr*7+kc][ch]), cout int32
//   biases, cout int8 PReLU slopes.
//
// Build: gcc -O2 -o gen_mfn gen_mfn.c && ./gen_mfn <outdir> [--params p] [--image i] [--dump-params p]
// ============================================================
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

static uint32_t rs = 0x12345678u;
static FILE *pin, *pout;     // parameter pack in / out (NULL = random / none)
static int EMB = 128;        // embedding size (linear layer outputs)
static uint32_t xr(void) { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; }
static int rnd(int lo, int hi) { return lo + (int)(xr() % (uint32_t)(hi - lo + 1)); }

static int sat8(int64_t v) { return v > 127 ? 127 : (v < -128 ? -128 : (int)v); }

enum { ACT_NONE = 0, ACT_RELU = 1, ACT_PRELU = 2 };

static int requant(int64_t acc, int64_t bias, int alpha, int sh, int ash, int act) {
    int64_t s = acc + bias;
    if (sh > 0) s += (int64_t)1 << (sh - 1);
    int q = sat8(s >> sh);
    if (act == ACT_RELU) return q < 0 ? 0 : q;
    if (act == ACT_PRELU && q < 0) {
        int64_t p = (int64_t)q * alpha;
        if (ash > 0) p += (int64_t)1 << (ash - 1);
        return sat8(p >> ash);
    }
    return q;
}

typedef struct { int h, w, c; int8_t *d; } T;   // c = multiple of 16
static T tnew(int h, int w, int c) { T t = {h, w, c, calloc((size_t)h * w * c, 1)}; return t; }
#define AT(t, r, cc, ch) ((t).d[((size_t)(r) * (t).w + (cc)) * (t).c + (ch)])

// ---------------- memory images ----------------
#define WDEPTH 8192
#define DWDEPTH 256
#define PWDEPTH 512
static uint8_t wmem[WDEPTH][256];
static uint8_t dwwmem[DWDEPTH][144];
static uint8_t dwqmem[DWDEPTH][80];
static uint8_t pwqmem[PWDEPTH][80];
static int wtop = 0, dwtop = 0, pwtop = 0;

static void put32(uint8_t *b, int off, int32_t v) { for (int i = 0; i < 4; i++) b[off + i] = (uint8_t)(v >> (8 * i)); }

// ---------------- parameter packs ----------------
static int n_rec_out = 0;
static void rd(void *p, size_t n) { if (fread(p, 1, n, pin) != n) { fprintf(stderr, "parameter pack truncated\n"); exit(1); } }
// reads one record header and checks it against the layer the model expects
static void rec_in(int kind, int cin, int cout, int *act, int *sh, int *ash) {
    uint8_t h[8]; rd(h, 8);
    int k = h[0], ci = h[4] | h[5] << 8, co = h[6] | h[7] << 8;
    if (k != kind || ci != cin || co != cout) {
        fprintf(stderr, "parameter pack: got layer kind %d %dx%d, model expects kind %d %dx%d\n", k, ci, co, kind, cin, cout);
        exit(1);
    }
    *act = h[1]; *sh = h[2]; *ash = h[3];
    if (*sh > 31 || *ash > 7) { fprintf(stderr, "parameter pack: shift %d / slope shift %d out of range\n", *sh, *ash); exit(1); }
}
static void rec_out(int kind, int cin, int cout, int act, int sh, int ash,
                    const int8_t *w, size_t nw, const int32_t *b, const int8_t *a) {
    uint8_t h[8] = {(uint8_t)kind, (uint8_t)act, (uint8_t)sh, (uint8_t)ash,
                    (uint8_t)cin, (uint8_t)(cin >> 8), (uint8_t)cout, (uint8_t)(cout >> 8)};
    fwrite(h, 1, 8, pout); fwrite(w, 1, nw, pout);
    for (int i = 0; i < cout; i++) { uint8_t v[4]; put32(v, 0, b[i]); fwrite(v, 1, 4, pout); }
    fwrite(a, 1, cout, pout);
    n_rec_out++;
}

// ---------------- parameter sets ----------------
typedef struct { int cin, cout; int8_t *w; int32_t *b; int8_t *a; int sh, ash, act, base, qbase; } PW;
typedef struct { int c; int8_t *w; int32_t *b; int8_t *a; int sh, ash, act, base; } DW;

static int choose_shift(int64_t *acc, size_t n) {
    // smallest shift that maps the 99.9th percentile of |acc| to <= 96
    int hist[64] = {0};
    for (size_t i = 0; i < n; i++) {
        int64_t v = acc[i] < 0 ? -acc[i] : acc[i];
        int b = 0; while (b < 63 && (v >> b) > 96) b++;
        hist[b]++;
    }
    size_t need = n - n / 1000, cum = 0;
    for (int b = 0; b < 64; b++) { cum += hist[b]; if (cum >= need) return b > 31 ? 31 : b; }
    return 31;
}

// pointwise over every pixel of `in`, into `out` (all rows)
static void pw_run(PW *p, T in, T out, int64_t *acc_buf, int choose) {
    size_t n = (size_t)in.h * in.w;
    for (size_t pix = 0; pix < n; pix++)
        for (int co = 0; co < p->cout; co++) {
            int64_t a = 0;
            for (int ci = 0; ci < p->cin; ci++) a += (int64_t)p->w[co * p->cin + ci] * in.d[pix * in.c + ci];
            acc_buf[pix * p->cout + co] = a;
        }
    if (choose && !pin) {
        p->sh = choose_shift(acc_buf, n * p->cout);
        for (int co = 0; co < p->cout; co++) p->b[co] = rnd(-(8 << p->sh), 8 << p->sh) / 1;
    }
    for (size_t pix = 0; pix < n; pix++)
        for (int co = 0; co < p->cout; co++)
            out.d[pix * out.c + co] = (int8_t)requant(acc_buf[pix * p->cout + co], p->b[co], p->a[co], p->sh, p->ash, p->act);
}

// 3x3 depthwise, pad 1, stride s
static void dw_run(DW *p, T in, T out, int s, int64_t *acc_buf, int choose) {
    for (int r = 0; r < out.h; r++)
        for (int cc = 0; cc < out.w; cc++)
            for (int ch = 0; ch < p->c; ch++) {
                int64_t a = 0;
                for (int kr = 0; kr < 3; kr++)
                    for (int kc = 0; kc < 3; kc++) {
                        int ir = r * s + kr - 1, ic = cc * s + kc - 1;
                        if (ir < 0 || ic < 0 || ir >= in.h || ic >= in.w) continue;
                        a += (int64_t)AT(in, ir, ic, ch) * p->w[ch * 9 + kr * 3 + kc];
                    }
                acc_buf[((size_t)r * out.w + cc) * p->c + ch] = a;
            }
    size_t n = (size_t)out.h * out.w * p->c;
    if (choose && !pin) {
        p->sh = choose_shift(acc_buf, n);
        for (int ch = 0; ch < p->c; ch++) p->b[ch] = rnd(-(8 << p->sh), 8 << p->sh);
    }
    for (size_t i = 0; i < n; i++) {
        int ch = (int)(i % p->c);
        out.d[(i / p->c) * out.c + ch] = (int8_t)requant(acc_buf[i], p->b[ch], p->a[ch], p->sh, p->ash, p->act);
    }
}

static PW *pw_new(int cin, int cout, int act) {
    PW *p = calloc(1, sizeof(PW));
    p->cin = cin; p->cout = cout; p->act = act; p->ash = 6;
    p->w = malloc((size_t)cin * cout); p->b = calloc(cout, 4); p->a = malloc(cout);
    if (pin) {
        rec_in(0, cin, cout, &p->act, &p->sh, &p->ash);
        rd(p->w, (size_t)cin * cout);
        for (int i = 0; i < cout; i++) { uint8_t v[4]; rd(v, 4); p->b[i] = (int32_t)(v[0] | v[1] << 8 | v[2] << 16 | (uint32_t)v[3] << 24); }
        rd(p->a, cout);
        return p;
    }
    for (int i = 0; i < cin * cout; i++) p->w[i] = (int8_t)rnd(-128, 127);
    for (int i = 0; i < cout; i++) p->a[i] = (int8_t)rnd(4, 40);     // slope ~0.06..0.6 (ash 6)
    return p;
}
static DW *dw_new(int c, int act) {
    DW *p = calloc(1, sizeof(DW));
    p->c = c; p->act = act; p->ash = 6;
    p->w = malloc((size_t)c * 9); p->b = calloc(c, 4); p->a = malloc(c);
    if (pin) {
        rec_in(1, c, c, &p->act, &p->sh, &p->ash);
        rd(p->w, (size_t)c * 9);
        for (int i = 0; i < c; i++) { uint8_t v[4]; rd(v, 4); p->b[i] = (int32_t)(v[0] | v[1] << 8 | v[2] << 16 | (uint32_t)v[3] << 24); }
        rd(p->a, c);
        return p;
    }
    for (int i = 0; i < c * 9; i++) p->w[i] = (int8_t)rnd(-128, 127);
    for (int i = 0; i < c; i++) p->a[i] = (int8_t)rnd(4, 40);
    return p;
}

static void pw_store(PW *p) {           // after shift/bias chosen
    if (pout) rec_out(0, p->cin, p->cout, p->act, p->sh, p->ash, p->w, (size_t)p->cin * p->cout, p->b, p->a);
    int ng = p->cin / 16, nco = p->cout / 16;
    p->base = wtop; p->qbase = pwtop;
    for (int cot = 0; cot < nco; cot++)
        for (int g = 0; g < ng; g++) {
            uint8_t *wd = wmem[wtop++];
            for (int col = 0; col < 16; col++)
                for (int ci = 0; ci < 16; ci++)
                    wd[col * 16 + ci] = (uint8_t)p->w[(cot * 16 + col) * p->cin + g * 16 + ci];
        }
    for (int cot = 0; cot < nco; cot++) {
        uint8_t *q = pwqmem[pwtop++];
        for (int l = 0; l < 16; l++) { put32(q, l * 4, p->b[cot * 16 + l]); q[64 + l] = (uint8_t)p->a[cot * 16 + l]; }
    }
    if (wtop > WDEPTH || pwtop > PWDEPTH) { fprintf(stderr, "weight memory overflow\n"); exit(1); }
}
static void dw_store(DW *p) {
    if (pout) rec_out(1, p->c, p->c, p->act, p->sh, p->ash, p->w, (size_t)p->c * 9, p->b, p->a);
    p->base = dwtop;
    for (int g = 0; g < p->c / 16; g++) {
        uint8_t *wd = dwwmem[dwtop], *q = dwqmem[dwtop];
        dwtop++;
        for (int l = 0; l < 16; l++) {
            for (int k = 0; k < 9; k++) wd[l * 9 + k] = (uint8_t)p->w[(g * 16 + l) * 9 + k];
            put32(q, l * 4, p->b[g * 16 + l]); q[64 + l] = (uint8_t)p->a[g * 16 + l];
        }
    }
    if (dwtop > DWDEPTH) { fprintf(stderr, "dw memory overflow\n"); exit(1); }
}

// ---------------- descriptors ----------------
typedef struct { uint8_t b[24]; } D;
static D descs[64]; static int nd = 0;
static void setb(D *d, int lo, int width, uint64_t v) {
    for (int i = 0; i < width; i++) if ((v >> i) & 1) d->b[(lo + i) / 8] |= (uint8_t)(1u << ((lo + i) % 8));
}
static uint64_t getb(D *d, int lo, int width) {
    uint64_t v = 0;
    for (int i = 0; i < width; i++) if (d->b[(lo + i) / 8] & (1u << ((lo + i) % 8))) v |= (uint64_t)1 << i;
    return v;
}
static void clrb(D *d, int lo, int width) {
    for (int i = 0; i < width; i++) d->b[(lo + i) / 8] &= (uint8_t)~(1u << ((lo + i) % 8));
}
static int ilog2(int v) { int l = 0; while ((1 << l) < v) l++; return l; }

// expected output words per pass
static FILE *fexp;
static void expect_region(int pass, int base, T t, int row0, int nrows) {
    int ngo = t.c / 16;
    fprintf(fexp, "pass %d %d %d\n", pass, base, nrows * t.w * ngo);
    for (int r = row0; r < row0 + nrows; r++)
        for (int c = 0; c < t.w; c++)
            for (int g = 0; g < ngo; g++) {
                for (int k = 15; k >= 0; k--) fprintf(fexp, "%02x", (uint8_t)AT(t, r, c, g * 16 + k));
                fputc('\n', fexp);
            }
}

// one engine pass
static int add_pass(int pw_only, int s2, int res, int w, int h, int ng, int nco,
                    DW *dwp, PW *pwp, int in_base, int out_base, int res_base,
                    int rf, int rl, int pos_off) {
    D *d = &descs[nd];
    memset(d, 0, sizeof(*d));
    setb(d, 0, 1, pw_only); setb(d, 1, 1, s2); setb(d, 2, 1, res);
    setb(d, 4, 8, w); setb(d, 12, 8, h); setb(d, 20, 6, ng); setb(d, 26, 6, nco);
    if (dwp) { setb(d, 32, 5, dwp->sh); setb(d, 37, 3, dwp->ash); setb(d, 40, 2, dwp->act); setb(d, 148, 12, dwp->base); }
    setb(d, 42, 5, pwp->sh); setb(d, 47, 3, pwp->ash); setb(d, 50, 2, pwp->act);
    setb(d, 52, 15, in_base); setb(d, 67, 15, out_base); setb(d, 82, 15, res_base);
    {   // feeder start word: first real pixel of padded row rf
        int pad = pw_only ? 0 : 1;
        int r0 = rf > pad ? rf - pad : 0;
        setb(d, 173, 15, in_base + r0 * w * ng);
    }
    setb(d, 97, 3, ilog2(nco));
    setb(d, 100, 8, rf); setb(d, 108, 8, rl); setb(d, 116, 16, pos_off);
    setb(d, 132, 16, pwp->base); setb(d, 160, 12, pwp->qbase);
    return nd++;
}

static void write_hex(const char *dir, const char *name, uint8_t *base, int words, int bytes) {
    char path[512]; snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "w");
    for (int i = 0; i < words; i++) {
        for (int k = bytes - 1; k >= 0; k--) fprintf(f, "%02x", base[(size_t)i * bytes + k]);
        fputc('\n', f);
    }
    fclose(f);
}

int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : ".";
    const char *img_path = NULL;
    char path[512];
    for (int i = 2; i + 1 < argc; i += 2) {
        if (!strcmp(argv[i], "--params")) {
            pin = fopen(argv[i + 1], "rb");
            uint8_t h[16];
            if (!pin || fread(h, 1, 16, pin) != 16 || memcmp(h, "MFNP", 4) || h[4] != 1) { fprintf(stderr, "bad parameter pack %s\n", argv[i + 1]); return 1; }
            EMB = h[8] | h[9] << 8;
            if (EMB % 128 || EMB < 128 || EMB > 512) { fprintf(stderr, "embedding size %d not supported\n", EMB); return 1; }
        } else if (!strcmp(argv[i], "--image")) img_path = argv[i + 1];
        else if (!strcmp(argv[i], "--dump-params")) {
            pout = fopen(argv[i + 1], "wb");
            if (!pout) { perror(argv[i + 1]); return 1; }
            uint8_t h[16] = {'M', 'F', 'N', 'P', 1};
            fwrite(h, 1, 16, pout);           // embedding size and count patched at the end
        } else { fprintf(stderr, "unknown option %s\n", argv[i]); return 1; }
    }
    snprintf(path, sizeof path, "%s/expect.txt", dir); fexp = fopen(path, "w");
    int64_t *acc = malloc(sizeof(int64_t) * 112 * 112 * 512);

    // bank bases
    const int B0 = 0, B1 = 8192, B2 = 16384;

    // ---- input image 112x112x3 and conv1 im2col (27 -> 32) ----
    T img = tnew(112, 112, 16);
    for (int r = 0; r < 112; r++) for (int c = 0; c < 112; c++) for (int ch = 0; ch < 3; ch++)
        AT(img, r, c, ch) = (int8_t)rnd(-128, 127);
    if (img_path) {         // 112x112x3 INT8, HWC
        FILE *f = fopen(img_path, "rb");
        if (!f) { perror(img_path); return 1; }
        for (int r = 0; r < 112; r++) for (int c = 0; c < 112; c++)
            if (fread(&AT(img, r, c, 0), 1, 3, f) != 3) { fprintf(stderr, "image file too short\n"); return 1; }
        fclose(f);
    }
    T col = tnew(56, 56, 32);
    for (int r = 0; r < 56; r++) for (int c = 0; c < 56; c++) {
        int k = 0;
        for (int kr = 0; kr < 3; kr++) for (int kc = 0; kc < 3; kc++) for (int ch = 0; ch < 3; ch++) {
            int ir = 2 * r + kr - 1, ic = 2 * c + kc - 1;
            AT(col, r, c, k++) = (ir < 0 || ic < 0 || ir >= 112 || ic >= 112) ? 0 : AT(img, ir, ic, ch);
        }
    }
    // raw image in the feature-map memory (im2col is done on the FPGA,
    // rtl/im2col_feeder.v): row r at B2 + r*21 words, 336 bytes per row
    snprintf(path, sizeof path, "%s/fmap_init.hex", dir);
    FILE *fi = fopen(path, "w");
    fprintf(fi, "@%x\n", B2);
    for (int r = 0; r < 112; r++) for (int w = 0; w < 21; w++) {
        for (int k = 15; k >= 0; k--) {
            int b = w * 16 + k;
            fprintf(fi, "%02x", (uint8_t)AT(img, r, b / 3, b % 3));
        }
        fputc('\n', fi);
    }
    fclose(fi);

    // ---- conv1 (as pw-only on im2col, 32 -> 64, PReLU) ----
    PW *c1 = pw_new(32, 64, ACT_PRELU);
    for (int co = 0; co < 64; co++) for (int ci = 27; ci < 32; ci++) c1->w[co * 32 + ci] = 0;
    T t1 = tnew(56, 56, 64);
    pw_run(c1, col, t1, acc, 1); pw_store(c1);
    int p = add_pass(1, 0, 0, 56, 56, 2, 4, NULL, c1, B2, B0, 0, 0, 55, 0);
    setb(&descs[p], 188, 1, 1);           // input through im2col_feeder
    setb(&descs[p], 1, 1, 1);             // 3x3 stride 2
    clrb(&descs[p], 173, 15);             // im2col pass: image size and channels
    setb(&descs[p], 173, 8, 112); setb(&descs[p], 181, 3, 3); setb(&descs[p], 82, 8, 112);
    expect_region(p, B0, t1, 0, 56);

    // ---- dw1 (64) + b1.expand (64->128), then b1.dw s2 + project -> 64, banded ----
    DW *dw1 = dw_new(64, ACT_PRELU);
    T t2 = tnew(56, 56, 64);
    dw_run(dw1, t1, t2, 1, acc, 1); dw_store(dw1);
    PW *e1 = pw_new(64, 128, ACT_PRELU);
    T e1t = tnew(56, 56, 128);
    pw_run(e1, t2, e1t, acc, 1); pw_store(e1);
    DW *d1 = dw_new(128, ACT_PRELU);
    T d1t = tnew(28, 28, 128);
    dw_run(d1, e1t, d1t, 2, acc, 1); dw_store(d1);
    PW *p1 = pw_new(128, 64, ACT_NONE);
    T y = tnew(28, 28, 64);
    pw_run(p1, d1t, y, acc, 1); pw_store(p1);
    // bands: b1 output rows [7k, 7k+7) need e1 rows [14k-1, 14k+13] clipped
    int yq = B1 + 4352, yp = B2;          // Q (bank1) and P (bank2) regions for X/Y
    for (int k = 0; k < 4; k++) {
        int a = 14 * k - 1; if (a < 0) a = 0;
        int b = 14 * k + 13;              // <= 55
        int nr = b - a + 1;
        // dw1 + expand over t1 padded rows a .. b+2 -> e1 rows a..b into band buffer (bank2)
        p = add_pass(0, 0, 0, 56, 56, 4, 8, dw1, e1, B0, B2, 0, a, b + 2, 0);
        expect_region(p, B2, e1t, a, nr);
        // b1.dw s2 + project over the band (w=56, h=nr): padded rows rf..rf+14
        int rf = (k == 0) ? 0 : 1;
        p = add_pass(0, 1, 0, 56, nr, 8, 4, d1, p1, B2, yq, 0, rf, rf + 14, 7 * k * 28);
        if (k == 3) expect_region(p, yq, y, 0, 28);
    }

    // ---- bottleneck helper ----
    int cur = yq;               // where the block input X lives
    int hw = 28, cin = 64;
    struct { int t, c, n, s; } cfg[] = {{2, 64, 4, 1}, {4, 128, 1, 2}, {2, 128, 6, 1}, {4, 128, 1, 2}, {2, 128, 2, 1}};
    T x = y;
    for (int ci = 0; ci < 5; ci++) {
        for (int i = 0; i < cfg[ci].n; i++) {
            int s = (i == 0) ? cfg[ci].s : 1;
            int cexp = cin * cfg[ci].t, cout = cfg[ci].c;
            int hwo = hw / s;
            int res = (s == 1 && cin == cout);
            // expand -> E at bank0 base 0
            PW *pe = pw_new(cin, cexp, ACT_PRELU);
            T et = tnew(hw, hw, cexp);
            pw_run(pe, x, et, acc, 1); pw_store(pe);
            p = add_pass(1, 0, 0, hw, hw, cin / 16, cexp / 16, NULL, pe, cur, B0, 0, 0, hw - 1, 0);
            expect_region(p, B0, et, 0, hw);
            // dw + project (+ residual)
            DW *pd = dw_new(cexp, ACT_PRELU);
            T dt = tnew(hwo, hwo, cexp);
            dw_run(pd, et, dt, s, acc, 1); dw_store(pd);
            PW *pp = pw_new(cexp, cout, ACT_NONE);
            T yt = tnew(hwo, hwo, cout);
            pw_run(pp, dt, yt, acc, 1); pw_store(pp);
            if (res)
                for (size_t k = 0; k < (size_t)hwo * hwo * cout; k++) yt.d[k] = (int8_t)sat8((int)yt.d[k] + x.d[k]);
            int out;
            if (cexp * hw * hw / 16 > 8192) {
                // E spans bank0 + bank1: E at 0 must end before `cur`
                if (cexp * hw * hw / 16 > cur) { fprintf(stderr, "E overlaps X\n"); return 1; }
            }
            // output goes to the X/Y region not holding X (and not overlapping E)
            if (s == 2) out = (cur >= B2) ? (B1 + 4352) : B2;
            else        out = (cur >= B2) ? (B1 + 4352) : B2;
            if (hw * hw * cexp / 16 > B1 + 4352 && out == B1 + 4352) out = B2;
            p = add_pass(0, s == 2, res, hw, hw, cexp / 16, cout / 16, pd, pp, B0, out, cur, 0, hw + 1, 0);
            expect_region(p, out, yt, 0, hwo);
            cur = out; x = yt; hw = hwo; cin = cout;
        }
    }

    // ---- conv1x1 128 -> 512 (PReLU), pw-only ----
    PW *c5 = pw_new(128, 512, ACT_PRELU);
    T z = tnew(7, 7, 512);
    pw_run(c5, x, z, acc, 1); pw_store(c5);
    int zout = (cur >= B2) ? B1 : B2;
    p = add_pass(1, 0, 0, 7, 7, 8, 32, NULL, c5, cur, zout, 0, 0, 6, 0);
    expect_region(p, zout, z, 0, 7);
    setb(&descs[nd - 1], 3, 1, 1);        // last

    descs[nd - 1].b[0] &= (uint8_t)~(1u << 3);   // conv1x1 is not the last pass any more

    // ---- GDConv 7x7 over z (7x7x512) -> 1x1x512, linear, on gdconv_unit ----
    {
        int8_t *gw = malloc(49 * 512);
        int32_t *gb = calloc(512, 4); int8_t *ga = malloc(512);
        int gsh = 0, gash = 6, gact = ACT_NONE;
        if (pin) {
            rec_in(2, 512, 512, &gact, &gsh, &gash);
            rd(gw, 49 * 512);
            for (int c = 0; c < 512; c++) { uint8_t v[4]; rd(v, 4); gb[c] = (int32_t)(v[0] | v[1] << 8 | v[2] << 16 | (uint32_t)v[3] << 24); }
            rd(ga, 512);
        } else {
            for (int i = 0; i < 49 * 512; i++) gw[i] = (int8_t)rnd(-128, 127);
            for (int c = 0; c < 512; c++) ga[c] = (int8_t)rnd(4, 40);
        }
        for (int c = 0; c < 512; c++) {
            int64_t a = 0;
            for (int p2 = 0; p2 < 49; p2++) a += (int64_t)gw[p2 * 512 + c] * z.d[(size_t)p2 * 512 + c];
            acc[c] = a;
        }
        if (!pin) {
            gsh = choose_shift(acc, 512);
            for (int c = 0; c < 512; c++) gb[c] = rnd(-(8 << gsh), 8 << gsh);
        }
        if (pout) rec_out(2, 512, 512, gact, gsh, gash, gw, 49 * 512, gb, ga);
        T gt = tnew(1, 1, 512);
        for (int c = 0; c < 512; c++) gt.d[c] = (int8_t)requant(acc[c], gb[c], ga[c], gsh, gash, gact);
        // weights: beat k = p*32 + g -> word k/16, chunk k%16, lane l
        int gwbase = wtop;
        for (int k = 0; k < 49 * 32; k++) {
            int p2 = k / 32, g = k % 32;
            for (int l = 0; l < 16; l++) wmem[gwbase + k / 16][(k % 16) * 16 + l] = (uint8_t)gw[p2 * 512 + g * 16 + l];
        }
        wtop += 49 * 32 / 16;
        int gqbase = pwtop;
        for (int g = 0; g < 32; g++) {
            uint8_t *q = pwqmem[pwtop++];
            for (int l = 0; l < 16; l++) { put32(q, l * 4, gb[g * 16 + l]); q[64 + l] = (uint8_t)ga[g * 16 + l]; }
        }
        PW gdp = {0}; gdp.sh = gsh; gdp.ash = gash; gdp.act = gact; gdp.base = gwbase; gdp.qbase = gqbase;
        p = add_pass(1, 0, 0, 7, 7, 32, 0, NULL, &gdp, zout, B0, 0, 0, 6, 0);
        setb(&descs[p], 172, 1, 1);
        setb(&descs[p], 97, 3, 5);
        expect_region(p, B0, gt, 0, 1);

        // ---- linear 512 -> EMB (pw-only on the 1x1 map), one pass per
        // 128 outputs (half-buffer limit: 256 weight words per pass) ----
        PW *lin = pw_new(512, EMB, ACT_NONE);
        T lt = tnew(1, 1, EMB);
        pw_run(lin, gt, lt, acc, 1); pw_store(lin);
        for (int k = 0; k < EMB / 128; k++) {
            PW part = *lin;
            part.base = lin->base + k * 8 * 32; part.qbase = lin->qbase + k * 8;
            p = add_pass(1, 0, 0, 1, 1, 32, 8, NULL, &part, B0, B1 + 8 * k, 0, 0, 0, 0);
        }
        expect_region(p, B1, lt, 0, 1);   // whole embedding, checked after the last part
        setb(&descs[nd - 1], 3, 1, 1);    // last

        snprintf(path, sizeof path, "%s/golden_ref.txt", dir);
        FILE *fg = fopen(path, "w");
        fprintf(fg, "embedding (%d INT8):", EMB);
        for (int c = 0; c < EMB; c++) fprintf(fg, " %d", lt.d[c]);
        fprintf(fg, "\n");
        fclose(fg);
    }

    // ---- weight streaming (V4-S4): every pass's parameters come from the
    // DDR3 image into one half of the on-chip double buffers (pass p uses
    // half p%2: pw weights 256 words each, dw/pw param rows 32 each).
    // Load descriptor (128 bits, desc chunk 2):
    //   [24:0] w_ddr   [33:25] w_cnt (2048-bit words)
    //   [58:34] dww_ddr [64:59] dw_groups
    //   [89:65] dwq_ddr [114:90] pwq_ddr [120:115] pw_tiles
    // DDR image (128-bit words): wmem (16 per word) | dwwmem (9 per row) |
    // dwqmem (5) | pwqmem (5).
    static D ldesc[64];
    {
        int DWW_OFF = wtop * 16, DWQ_OFF = DWW_OFF + dwtop * 9, PWQ_OFF = DWQ_OFF + dwtop * 5;
        int total = PWQ_OFF + pwtop * 5;
        for (int i = 0; i < nd; i++) {
            D *d = &descs[i];
            int gd = (int)getb(d, 172, 1), pwo = (int)getb(d, 0, 1);
            int ng = (int)getb(d, 20, 6), nco = (int)getb(d, 26, 6);
            int wb = (int)getb(d, 132, 16), dwb = (int)getb(d, 148, 12), pwb = (int)getb(d, 160, 12);
            int wcnt = gd ? 98 : ng * nco, groups = (gd || pwo) ? 0 : ng, tiles = gd ? 32 : nco;
            if (wcnt > 256 || groups > 32 || tiles > 32) { fprintf(stderr, "pass %d too big for half buffers\n", i); return 1; }
            D *l = &ldesc[i]; memset(l, 0, sizeof(*l));
            setb(l, 0, 25, wb * 16);            setb(l, 25, 9, wcnt);
            setb(l, 34, 25, DWW_OFF + dwb * 9); setb(l, 59, 6, groups);
            setb(l, 65, 25, DWQ_OFF + dwb * 5);
            setb(l, 90, 25, PWQ_OFF + pwb * 5); setb(l, 115, 6, tiles);
            clrb(d, 132, 16); setb(d, 132, 16, (i % 2) * 256);
            clrb(d, 148, 12); setb(d, 148, 12, (i % 2) * 32);
            clrb(d, 160, 12); setb(d, 160, 12, (i % 2) * 32);
        }
        uint8_t *ddr = calloc((size_t)total, 16);
        memcpy(ddr, wmem, (size_t)wtop * 256);
        memcpy(ddr + (size_t)DWW_OFF * 16, dwwmem, (size_t)dwtop * 144);
        memcpy(ddr + (size_t)DWQ_OFF * 16, dwqmem, (size_t)dwtop * 80);
        memcpy(ddr + (size_t)PWQ_OFF * 16, pwqmem, (size_t)pwtop * 80);
        write_hex(dir, "ddr.hex", ddr, total, 16);
        printf("DDR image: %d x 128-bit words (%d KB)\n", total, total * 16 / 1024);
    }
    {   // load descriptors as 128-bit words (D is 24 bytes; use the first 16)
        uint8_t tmp[64][16];
        for (int i = 0; i < nd; i++) memcpy(tmp[i], ldesc[i].b, 16);
        write_hex(dir, "ldesc.hex", (uint8_t *)tmp, nd, 16);
    }

    // ---- board image (V4-B): one DDR3 image with the boot header,
    // descriptor table, raw input image and parameter image, as the
    // ESP32 would write it (addresses in 128-bit words) ----
    {
        const int HDR_W = 16, DESC_W = 64, IMG_W = 256, PARAM_W = 4096;
        int DWW_OFF = wtop * 16, DWQ_OFF = DWW_OFF + dwtop * 9, PWQ_OFF = DWQ_OFF + dwtop * 5;
        int ptotal = PWQ_OFF + pwtop * 5;
        // result at word 80000 (the firmware default) unless the parameters
        // reach it (512-value embedding): then the next 4096-word boundary
        int RESULT_W = PARAM_W + ptotal <= 80000 ? 80000 : (PARAM_W + ptotal + 4095) / 4096 * 4096;
        snprintf(path, sizeof path, "%s/ddr_full.hex", dir);
        FILE *fb = fopen(path, "w");
        uint8_t w[16];
        // header word 0
        memset(w, 0, 16);
        w[0] = nd & 255; w[1] = nd >> 8;
        for (int i = 0; i < 4; i++) { w[2 + i] = (DESC_W >> (8 * i)) & 255; w[6 + i] = (IMG_W >> (8 * i)) & 255; }
        w[10] = 2352 & 255; w[11] = 2352 >> 8;           // image words
        w[12] = 16384 & 255; w[13] = 16384 >> 8;         // image feature-map address (bank 2)
        fprintf(fb, "@%x\n", HDR_W);
        for (int k = 15; k >= 0; k--) fprintf(fb, "%02x", w[k]); fputc('\n', fb);
        // header word 1
        memset(w, 0, 16);
        for (int i = 0; i < 4; i++) { w[i] = (RESULT_W >> (8 * i)) & 255; w[8 + i] = (PARAM_W >> (8 * i)) & 255; }
        w[4] = 8192 & 255; w[5] = 8192 >> 8;             // output feature-map address (linear output, bank 1)
        w[6] = (uint8_t)(EMB / 16); w[7] = 0;            // output words, 16 values each
        w[12] = 0x56; w[13] = 0x4E; w[14] = 0x4E; w[15] = 0x34;   // magic 0x344E4E56
        for (int k = 15; k >= 0; k--) fprintf(fb, "%02x", w[k]); fputc('\n', fb);
        // descriptor table: lo, hi, load per pass
        fprintf(fb, "@%x\n", DESC_W);
        for (int i = 0; i < nd; i++) {
            uint8_t lo[16], hi[16];
            memcpy(lo, descs[i].b, 16); memset(hi, 0, 16); memcpy(hi, descs[i].b + 16, 8);
            for (int k = 15; k >= 0; k--) fprintf(fb, "%02x", lo[k]); fputc('\n', fb);
            for (int k = 15; k >= 0; k--) fprintf(fb, "%02x", hi[k]); fputc('\n', fb);
            for (int k = 15; k >= 0; k--) fprintf(fb, "%02x", ldesc[i].b[k]); fputc('\n', fb);
        }
        // raw image rows (same words as fmap_init.hex)
        fprintf(fb, "@%x\n", IMG_W);
        for (int r = 0; r < 112; r++) for (int ww = 0; ww < 21; ww++) {
            for (int k = 15; k >= 0; k--) { int b = ww * 16 + k; fprintf(fb, "%02x", (uint8_t)AT(img, r, b / 3, b % 3)); }
            fputc('\n', fb);
        }
        // parameter image
        uint8_t *ddr = calloc((size_t)ptotal, 16);
        memcpy(ddr, wmem, (size_t)wtop * 256);
        memcpy(ddr + (size_t)DWW_OFF * 16, dwwmem, (size_t)dwtop * 144);
        memcpy(ddr + (size_t)DWQ_OFF * 16, dwqmem, (size_t)dwtop * 80);
        memcpy(ddr + (size_t)PWQ_OFF * 16, pwqmem, (size_t)pwtop * 80);
        fprintf(fb, "@%x\n", PARAM_W);
        for (int i = 0; i < ptotal; i++) { for (int k = 15; k >= 0; k--) fprintf(fb, "%02x", ddr[(size_t)i * 16 + k]); fputc('\n', fb); }
        fclose(fb);
        printf("board DDR image: header @%d, %d descriptors @%d, image @%d, params @%d (%d words), result @%d\n",
               HDR_W, nd, DESC_W, IMG_W, PARAM_W, ptotal, RESULT_W);
    }

    // ---- files ----
    write_hex(dir, "desc.hex", (uint8_t *)descs, nd, 24);
    write_hex(dir, "wmem.hex", (uint8_t *)wmem, wtop, 256);
    write_hex(dir, "dwwmem.hex", (uint8_t *)dwwmem, dwtop, 144);
    write_hex(dir, "dwqmem.hex", (uint8_t *)dwqmem, dwtop, 80);
    write_hex(dir, "pwqmem.hex", (uint8_t *)pwqmem, pwtop, 80);
    fclose(fexp);
    if (pin) {
        uint8_t extra;
        if (fread(&extra, 1, 1, pin) == 1) { fprintf(stderr, "parameter pack has more layers than the model\n"); return 1; }
        fclose(pin);
    }
    if (pout) {         // patch embedding size and record count
        uint8_t h[8]; put32(h, 0, EMB); put32(h, 4, n_rec_out);
        fseek(pout, 8, SEEK_SET); fwrite(h, 1, 8, pout); fclose(pout);
    }
    printf("passes %d, pw weight words %d, dw groups %d, pw tiles %d\n", nd, wtop, dwtop, pwtop);
    return 0;
}
