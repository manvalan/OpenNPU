// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// FPGA-Neural v4 -- the same network on a CPU (ESP32-S3 or a PC), with
// the exact integer arithmetic of the FPGA (requant_act.v, pool_unit.v,
// tile_writer.v; C++ twin of hardware/v4/model/v4_ref.py), so the output
// is bit-identical to the FPGA's and the time is a fair CPU reference.
//
// Input: net.bin written by hardware/v4/model/s3_export.py:
//   "V4S3" u32 version=1, u32 n_layers, u16 h, u16 w, u16 c, u16 0,
//   u32 pack_len, u32 img_len, u32 out_len
//   n_layers x 12-byte layer records (type, stride, residual, pad, cout,
//   pool kind, k, mul, sh, 0, 0); Concat: cout = source layer index
//   parameter pack (MFNP, same file the FPGA compiler takes)
//   input (INT8, HWC), expected output (INT8, true channel count)
// Plain portable C++ (no SIMD, no ESP-DL): the reference of what the
// network costs on the CPU with straightforward integer loops.
#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace v4net {

enum LayerType : uint8_t { CONV1 = 0, CONV3 = 1, PW = 2, LINEAR = 3, DWPW = 4, GDCONV = 5, POOL = 6,
                          UPSAMPLE = 7, CONCAT = 8 };

struct Rec {                    // one parameter-pack record
    uint8_t kind, act, sh, ash;
    int cin, cout;
    const int8_t *w;
    const int32_t *b;           // may be unaligned in the file: copied
    const int8_t *a;
    std::vector<int32_t> bias;
};

struct Layer {
    uint8_t type, stride, residual, pad, kind, k, mul, sh;
    int cout;                   // CONCAT: source layer index
    int last_use = 0;           // last layer that reads this layer's output
    Rec r0, r1;                 // DWPW: r0 = depthwise, r1 = pointwise
};

struct Tensor {
    int h = 0, w = 0, c = 0;
    int8_t *d = nullptr;
    size_t size() const { return (size_t)h * w * c; }
};

class Net {
public:
    // blob must stay valid while the Net is used (it is not copied)
    bool load(const uint8_t *blob, size_t len, std::string &err);
    // runs the whole network on the embedded input; out = final tensor
    // (owned by the Net, valid until the next run)
    const Tensor &run();
    const int8_t *input() const { return in_; }
    const int8_t *expected() const { return exp_; }
    size_t expected_len() const { return exp_len_; }
    size_t layers() const { return L_.size(); }
    size_t peak_bytes() const { return peak_; }
    // allocator hooks (ESP32-S3: PSRAM); default malloc/free
    static void *(*alloc)(size_t);
    static void (*release)(void *);

private:
    std::vector<Layer> L_;
    int ih_ = 0, iw_ = 0, ic_ = 0;
    const int8_t *in_ = nullptr, *exp_ = nullptr;
    size_t exp_len_ = 0, peak_ = 0;
    Tensor out_;
    std::vector<int8_t *> owned_;
};

}  // namespace v4net
