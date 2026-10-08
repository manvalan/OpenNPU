// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// FPGA-Neural v4 -- network runner with the FPGA integer arithmetic.
// See v4net.hpp. Every function mirrors hardware/v4/model/v4_ref.py.
#include "v4net.hpp"

#include <cstdlib>
#include <cstring>
#ifdef _OPENMP
#include <omp.h>
#define V4_OMP(x) _Pragma(#x)
#else
#define V4_OMP(x)   // MCU builds: no OpenMP, serial loops
#endif

namespace v4net {

void *(*Net::alloc)(size_t) = std::malloc;
void (*Net::release)(void *) = std::free;

static inline int8_t sat8(int64_t v) { return v > 127 ? 127 : (v < -128 ? -128 : (int8_t)v); }

// requant_act.v: (acc + bias + round) >> sh, saturate, ReLU / PReLU
static inline int8_t requant(int32_t acc, const Rec &r, int co)
{
    int64_t s = (int64_t)acc + r.bias[co];
    if (r.sh > 0) s += (int64_t)1 << (r.sh - 1);
    int8_t q = sat8(s >> r.sh);
    if (r.act == 1) {
        if (q < 0) q = 0;
    } else if (r.act == 2 && q < 0) {
        int64_t p = (int64_t)q * r.a[co];
        if (r.ash > 0) p += (int64_t)1 << (r.ash - 1);
        q = sat8(p >> r.ash);
    }
    return q;
}

static inline int32_t dot(const int8_t *x, const int8_t *w, int n)
{
    int32_t acc = 0;
    for (int i = 0; i < n; i++) acc += (int32_t)x[i] * w[i];
    return acc;
}

static inline uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static inline uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

static bool read_rec(const uint8_t *&p, const uint8_t *end, int kind, int cin, int cout, int npos, Rec &r,
                     std::string &err)
{
    if (p + 8 > end) { err = "pack truncated"; return false; }
    r.kind = p[0]; r.act = p[1]; r.sh = p[2]; r.ash = p[3]; r.cin = rd16(p + 4); r.cout = rd16(p + 6);
    if (r.kind != kind || r.cin != cin || r.cout != cout) {
        err = "pack record does not match the network (kind " + std::to_string(r.kind) + " " +
              std::to_string(r.cin) + "x" + std::to_string(r.cout) + ", expected kind " + std::to_string(kind) +
              " " + std::to_string(cin) + "x" + std::to_string(cout) + ")";
        return false;
    }
    p += 8;
    size_t nw = kind == 0 ? (size_t)cin * cout : kind == 1 ? (size_t)cin * 9 : kind == 2 ? (size_t)npos * cin
                                                                                     : (size_t)9 * cin * cout;
    if (p + nw + 5 * (size_t)cout > end) { err = "pack truncated"; return false; }
    r.w = (const int8_t *)p; p += nw;
    r.bias.resize(cout);
    for (int i = 0; i < cout; i++) r.bias[i] = (int32_t)rd32(p + 4 * i);
    p += 4 * (size_t)cout;
    r.a = (const int8_t *)p; p += cout;
    return true;
}

static int conv1_ng(int c) { int n = (9 * c + 15) / 16; return n < 2 ? 2 : n; }

bool Net::load(const uint8_t *blob, size_t len, std::string &err)
{
    if (len < 32 || std::memcmp(blob, "V4S3", 4) != 0 || rd32(blob + 4) != 1) { err = "not a V4S3 v1 file"; return false; }
    uint32_t n = rd32(blob + 8);
    ih_ = rd16(blob + 12); iw_ = rd16(blob + 14); ic_ = rd16(blob + 16);
    uint32_t pack_len = rd32(blob + 20), img_len = rd32(blob + 24), out_len = rd32(blob + 28);
    const uint8_t *p = blob + 32;
    const uint8_t *pack = p + 12 * (size_t)n;
    if (pack + pack_len + img_len + out_len != blob + len) { err = "V4S3 sizes do not add up"; return false; }
    if (img_len != (size_t)ih_ * iw_ * ic_) { err = "input size"; return false; }
    in_ = (const int8_t *)(pack + pack_len);
    exp_ = in_ + img_len;
    exp_len_ = out_len;
    if (pack_len < 16 || std::memcmp(pack, "MFNP", 4) != 0) { err = "not a parameter pack"; return false; }
    const uint8_t *q = pack + 16, *qend = pack + pack_len;
    L_.assign(n, Layer());
    int h = ih_, w = iw_, c = ic_;
    std::vector<int> oc(n);                 // output channels of every layer
    for (uint32_t i = 0; i < n; i++, p += 12) {
        Layer &l = L_[i];
        l.type = p[0]; l.stride = p[1]; l.residual = p[2]; l.pad = p[3]; l.cout = rd16(p + 4);
        l.kind = p[6]; l.k = p[7]; l.mul = p[8]; l.sh = p[9];
        int s = l.stride ? l.stride : 1;
        switch (l.type) {
        case CONV1:
            if (!read_rec(q, qend, 0, 16 * conv1_ng(c), l.cout, 0, l.r0, err)) return false;
            h = (h + s - 1) / s; w = (w + s - 1) / s; c = l.cout;
            break;
        case CONV3:
            if (!read_rec(q, qend, 3, c, l.cout, 0, l.r0, err)) return false;
            h = (h + s - 1) / s; w = (w + s - 1) / s; c = l.cout;
            break;
        case PW: case LINEAR:
            if (!read_rec(q, qend, 0, c, l.cout, 0, l.r0, err)) return false;
            c = l.cout;
            break;
        case DWPW:
            if (!read_rec(q, qend, 1, c, c, 0, l.r0, err)) return false;
            if (!read_rec(q, qend, 0, c, l.cout, 0, l.r1, err)) return false;
            h = (h + s - 1) / s; w = (w + s - 1) / s; c = l.cout;
            break;
        case GDCONV:
            if (!read_rec(q, qend, 2, c, c, h * w, l.r0, err)) return false;
            h = w = 1;
            break;
        case POOL:
            h = (h + 2 * l.pad - l.k) / s + 1; w = (w + 2 * l.pad - l.k) / s + 1;
            break;
        case UPSAMPLE:
            h *= 2; w *= 2;
            break;
        case CONCAT:
            if (l.cout < 0 || l.cout >= (int)i) { err = "Concat source"; return false; }
            c += oc[l.cout];
            if (L_[l.cout].last_use < (int)i) L_[l.cout].last_use = i;
            break;
        default:
            err = "unknown layer type " + std::to_string(l.type);
            return false;
        }
        oc[i] = c;
        // the output of layer i is the input of i+1 and the residual of i+2
        if (l.last_use < (int)i + 2) l.last_use = i + 2;
    }
    if (q != qend) { err = "pack has more records than the network"; return false; }
    if ((size_t)h * w * c != out_len) { err = "expected output size"; return false; }
    return true;
}

// ---------------------------------------------------------------- layers
static void win9(const Tensor &x, int r0, int c0, int8_t *v)
{   // 3x3 window at (r0, c0) (top-left, may be -1), k = (kr*3+kc)*C+ch
    for (int kr = 0; kr < 3; kr++)
        for (int kc = 0; kc < 3; kc++) {
            int r = r0 + kr, cc = c0 + kc;
            int8_t *o = v + (kr * 3 + kc) * x.c;
            if (r < 0 || cc < 0 || r >= x.h || cc >= x.w) std::memset(o, 0, x.c);
            else std::memcpy(o, x.d + ((size_t)r * x.w + cc) * x.c, x.c);
        }
}

// conv1 (weights row stride = 16*ng, first 9C used) and dense 3x3
// With -fopenmp (Linux build) the output rows are split across threads;
// every output value is computed exactly as in the serial loop, so the
// result is identical. Without OpenMP (MCU builds) the pragmas do nothing.
static void conv3x3(const Tensor &x, const Rec &r, int s, int wstride, Tensor &y, int8_t *tmp)
{
    int n = 9 * x.c;
V4_OMP(omp parallel)
    {
        int8_t *t = tmp;
#ifdef _OPENMP
        std::vector<int8_t> own(omp_get_thread_num() ? n : 0);   // thread 0 uses tmp
        if (omp_get_thread_num()) t = own.data();
#endif
V4_OMP(omp for schedule(static))
        for (int i = 0; i < y.h; i++)
            for (int j = 0; j < y.w; j++) {
                win9(x, s * i - 1, s * j - 1, t);
                int8_t *o = y.d + ((size_t)i * y.w + j) * y.c;
                for (int co = 0; co < y.c; co++) o[co] = requant(dot(t, r.w + (size_t)co * wstride, n), r, co);
            }
    }
}

static void pw(const Tensor &x, const Rec &r, Tensor &y)
{
    long np = (long)x.h * x.w;
V4_OMP(omp parallel for schedule(static))
    for (long p = 0; p < np; p++) {
        const int8_t *v = x.d + p * x.c;
        int8_t *o = y.d + p * y.c;
        for (int co = 0; co < y.c; co++) o[co] = requant(dot(v, r.w + (size_t)co * x.c, x.c), r, co);
    }
}

static void dw(const Tensor &x, const Rec &r, int s, Tensor &y)
{
V4_OMP(omp parallel for schedule(static))
    for (int i = 0; i < y.h; i++)
        for (int j = 0; j < y.w; j++) {
            int8_t *o = y.d + ((size_t)i * y.w + j) * y.c;
            for (int ch = 0; ch < x.c; ch++) {
                int32_t acc = 0;
                for (int kr = 0; kr < 3; kr++) {
                    int rr = s * i - 1 + kr;
                    if (rr < 0 || rr >= x.h) continue;
                    for (int kc = 0; kc < 3; kc++) {
                        int cc = s * j - 1 + kc;
                        if (cc < 0 || cc >= x.w) continue;
                        acc += (int32_t)x.d[((size_t)rr * x.w + cc) * x.c + ch] * r.w[ch * 9 + kr * 3 + kc];
                    }
                }
                o[ch] = requant(acc, r, ch);
            }
        }
}

static void gdconv(const Tensor &x, const Rec &r, Tensor &y)
{
    size_t np = (size_t)x.h * x.w;
V4_OMP(omp parallel for schedule(static))
    for (int ch = 0; ch < x.c; ch++) {
        int32_t acc = 0;
        for (size_t p = 0; p < np; p++) acc += (int32_t)x.d[p * x.c + ch] * r.w[p * x.c + ch];
        y.d[ch] = requant(acc, r, ch);
    }
}

static void pool(const Tensor &x, const Layer &l, Tensor &y)
{
    int s = l.stride;
V4_OMP(omp parallel for schedule(static))
    for (int i = 0; i < y.h; i++)
        for (int j = 0; j < y.w; j++) {
            int8_t *o = y.d + ((size_t)i * y.w + j) * y.c;
            for (int ch = 0; ch < x.c; ch++) {
                int32_t acc = l.kind ? -128 : 0;
                for (int kr = 0; kr < l.k; kr++) {
                    int rr = s * i - l.pad + kr;
                    if (rr < 0 || rr >= x.h) continue;
                    for (int kc = 0; kc < l.k; kc++) {
                        int cc = s * j - l.pad + kc;
                        if (cc < 0 || cc >= x.w) continue;
                        int32_t v = x.d[((size_t)rr * x.w + cc) * x.c + ch];
                        if (l.kind) { if (v > acc) acc = v; }
                        else acc += v;
                    }
                }
                int64_t v = (int64_t)acc * l.mul;
                if (l.sh > 0) v += (int64_t)1 << (l.sh - 1);
                o[ch] = sat8(v >> l.sh);
            }
        }
}

static void res_add(Tensor &y, const Tensor &x)
{
    for (size_t k = 0; k < y.size(); k++) y.d[k] = sat8((int)y.d[k] + x.d[k]);
}

const Tensor &Net::run()
{
    for (int8_t *b : owned_) release(b);
    owned_.clear();
    peak_ = 0;
    size_t live = 0;
    auto make = [&](int h, int w, int c) {
        Tensor t; t.h = h; t.w = w; t.c = c;
        t.d = (int8_t *)alloc(t.size() ? t.size() : 1);
        owned_.push_back(t.d);
        live += t.size();
        if (live > peak_) peak_ = live;
        return t;
    };
    Tensor x; x.h = ih_; x.w = iw_; x.c = ic_; x.d = (int8_t *)in_;
    std::vector<Tensor> ins;            // input of every layer (residual = input of the previous layer)
    std::vector<Tensor> outs;           // output of every layer (Concat sources)
    int8_t *tmp = (int8_t *)alloc(9 * 4096);
    for (size_t i = 0; i < L_.size(); i++) {
        const Layer &l = L_[i];
        ins.push_back(x);
        int s = l.stride ? l.stride : 1;
        Tensor y;
        switch (l.type) {
        case CONV1:
            y = make((x.h + s - 1) / s, (x.w + s - 1) / s, l.cout);
            conv3x3(x, l.r0, s, l.r0.cin, y, tmp);
            break;
        case CONV3:
            y = make((x.h + s - 1) / s, (x.w + s - 1) / s, l.cout);
            conv3x3(x, l.r0, s, 9 * x.c, y, tmp);
            if (l.residual) res_add(y, ins[i - 1]);
            break;
        case PW: case LINEAR:
            y = make(x.h, x.w, l.cout);
            pw(x, l.r0, y);
            if (l.residual) res_add(y, x);
            break;
        case DWPW: {
            Tensor d = make((x.h + s - 1) / s, (x.w + s - 1) / s, x.c);
            dw(x, l.r0, s, d);
            y = make(d.h, d.w, l.cout);
            pw(d, l.r1, y);
            if (l.residual) res_add(y, ins[i - 1]);
            for (auto it = owned_.begin(); it != owned_.end(); ++it)
                if (*it == d.d) { release(*it); owned_.erase(it); live -= d.size(); break; }
            break;
        }
        case GDCONV:
            y = make(1, 1, x.c);
            gdconv(x, l.r0, y);
            break;
        case POOL:
            y = make((x.h + 2 * l.pad - l.k) / s + 1, (x.w + 2 * l.pad - l.k) / s + 1, x.c);
            pool(x, l, y);
            break;
        case UPSAMPLE:
            y = make(2 * x.h, 2 * x.w, x.c);
            for (int r = 0; r < y.h; r++)
                for (int cc = 0; cc < y.w; cc++)
                    std::memcpy(y.d + ((size_t)r * y.w + cc) * y.c, x.d + ((size_t)(r / 2) * x.w + cc / 2) * x.c, x.c);
            break;
        case CONCAT: {
            const Tensor &b = outs[l.cout];
            y = make(x.h, x.w, x.c + b.c);
            for (size_t p = 0; p < (size_t)x.h * x.w; p++) {
                std::memcpy(y.d + p * y.c, x.d + p * x.c, x.c);
                std::memcpy(y.d + p * y.c + x.c, b.d + p * b.c, b.c);
            }
            break;
        }
        }
        x = y;
        outs.push_back(y);
        // free every output no later layer reads
        for (size_t j = 0; j + 1 < outs.size(); j++)
            if (outs[j].d && L_[j].last_use <= (int)i) {
                for (auto it = owned_.begin(); it != owned_.end(); ++it)
                    if (*it == outs[j].d) { release(*it); owned_.erase(it); live -= outs[j].size(); break; }
                outs[j].d = nullptr;
            }
    }
    release(tmp);
    out_ = x;
    return out_;
}

}  // namespace v4net
