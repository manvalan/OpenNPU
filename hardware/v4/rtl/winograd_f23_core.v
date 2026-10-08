// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- A.1 architecture, first isolated
// building block: the Winograd F(2x2,3x3) 2D core arithmetic,
// single input channel, no accumulation across channels yet (that
// is layered on top later -- one variable at a time).
//
// Real, deliberate scope for THIS module: pure combinational
// arithmetic, no clock, no saturation/clamping -- correctness of
// the raw transform math is verified bit-exact against a golden
// direct-convolution model in tb_winograd_f23_core.v BEFORE any
// pipelining, saturation, or multi-channel accumulation is added.
//
// REAL, KNOWN HAZARD in standard Winograd F(2,3): the kernel
// transform matrix G has fractional (+-1/2) coefficients -- not
// representable in pure integer hardware. Since the kernel
// transform happens OFFLINE (the "compiler" tool, per this
// project's A/5 design: weights are synthesis-time constants), we
// scale G by 2 (all coefficients become integers: {2,1,-1,0}),
// which scales the transformed kernel U' = (2G) g (2G)^T = 4*U.
// Because the whole pipeline (elementwise multiply, inverse
// transform) is LINEAR, the final result comes out exactly 4x too
// large -- corrected by a single, EXACT arithmetic right-shift by
// 2 (>>>2) at the very end, no rounding error, PROVIDED the scale
// derivation is actually correct -- which is exactly what this
// module's own testbench cross-checks against a golden direct-conv
// reference, rather than trusting the algebra alone.
//
// Inputs:
//   d[16]  -- the 4x4 input tile, INT8 signed, row-major (d[4*r+c])
//   u[16]  -- the ALREADY-TRANSFORMED kernel U' = (2G) g (2G)^T,
//             row-major, computed OFFLINE (by the testbench here,
//             standing in for the future real compiler tool) --
//             wide enough (16-bit signed) to hold the transform's
//             own real, bounded growth (see header math below).
// Output:
//   y[4]   -- the 2x2 real convolution result, row-major (y[2*r+c]),
//             exact (no saturation) -- clamping to a target output
//             width is a SEPARATE, later concern, not this module's.
// ============================================================
module winograd_f23_core (
    input  wire signed [7:0]  d0,  d1,  d2,  d3,
    input  wire signed [7:0]  d4,  d5,  d6,  d7,
    input  wire signed [7:0]  d8,  d9,  d10, d11,
    input  wire signed [7:0]  d12, d13, d14, d15,

    input  wire signed [15:0] u0,  u1,  u2,  u3,
    input  wire signed [15:0] u4,  u5,  u6,  u7,
    input  wire signed [15:0] u8,  u9,  u10, u11,
    input  wire signed [15:0] u12, u13, u14, u15,

    output wire signed [39:0] y0, y1, y2, y3
);
    // ---- input transform: T = B^T * d (down the columns) ----
    // B^T row pattern: [1 0 -1 0; 0 1 1 0; 0 -1 1 0; 0 1 0 -1]
    wire signed [8:0] t0_0 = d0  - d8;   // col 0
    wire signed [8:0] t1_0 = d4  + d8;
    wire signed [8:0] t2_0 = d8  - d4;
    wire signed [8:0] t3_0 = d4  - d12;

    wire signed [8:0] t0_1 = d1  - d9;   // col 1
    wire signed [8:0] t1_1 = d5  + d9;
    wire signed [8:0] t2_1 = d9  - d5;
    wire signed [8:0] t3_1 = d5  - d13;

    wire signed [8:0] t0_2 = d2  - d10;  // col 2
    wire signed [8:0] t1_2 = d6  + d10;
    wire signed [8:0] t2_2 = d10 - d6;
    wire signed [8:0] t3_2 = d6  - d14;

    wire signed [8:0] t0_3 = d3  - d11;  // col 3
    wire signed [8:0] t1_3 = d7  + d11;
    wire signed [8:0] t2_3 = d11 - d7;
    wire signed [8:0] t3_3 = d7  - d15;

    // ---- input transform: V = T * B (across the rows) ----
    // same [1 0 -1 0; 0 1 1 0; 0 -1 1 0; 0 1 0 -1] pattern, applied
    // to each row of T this time.
    wire signed [10:0] v0_0 = t0_0 - t0_2;
    wire signed [10:0] v0_1 = t0_1 + t0_2;
    wire signed [10:0] v0_2 = t0_2 - t0_1;
    wire signed [10:0] v0_3 = t0_1 - t0_3;

    wire signed [10:0] v1_0 = t1_0 - t1_2;
    wire signed [10:0] v1_1 = t1_1 + t1_2;
    wire signed [10:0] v1_2 = t1_2 - t1_1;
    wire signed [10:0] v1_3 = t1_1 - t1_3;

    wire signed [10:0] v2_0 = t2_0 - t2_2;
    wire signed [10:0] v2_1 = t2_1 + t2_2;
    wire signed [10:0] v2_2 = t2_2 - t2_1;
    wire signed [10:0] v2_3 = t2_1 - t2_3;

    wire signed [10:0] v3_0 = t3_0 - t3_2;
    wire signed [10:0] v3_1 = t3_1 + t3_2;
    wire signed [10:0] v3_2 = t3_2 - t3_1;
    wire signed [10:0] v3_3 = t3_1 - t3_3;

    // ---- elementwise multiply: M' = U' .* V ----
    wire signed [27:0] m0  = u0  * v0_0;
    wire signed [27:0] m1  = u1  * v0_1;
    wire signed [27:0] m2  = u2  * v0_2;
    wire signed [27:0] m3  = u3  * v0_3;

    wire signed [27:0] m4  = u4  * v1_0;
    wire signed [27:0] m5  = u5  * v1_1;
    wire signed [27:0] m6  = u6  * v1_2;
    wire signed [27:0] m7  = u7  * v1_3;

    wire signed [27:0] m8  = u8  * v2_0;
    wire signed [27:0] m9  = u9  * v2_1;
    wire signed [27:0] m10 = u10 * v2_2;
    wire signed [27:0] m11 = u11 * v2_3;

    wire signed [27:0] m12 = u12 * v3_0;
    wire signed [27:0] m13 = u13 * v3_1;
    wire signed [27:0] m14 = u14 * v3_2;
    wire signed [27:0] m15 = u15 * v3_3;

    // ---- output inverse transform: S = A^T * M' (down the columns) ----
    // A^T row pattern: [1 1 1 0; 0 1 -1 -1]
    wire signed [29:0] s0_0 = m0 + m4 + m8;
    wire signed [29:0] s1_0 = m4 - m8 - m12;

    wire signed [29:0] s0_1 = m1 + m5 + m9;
    wire signed [29:0] s1_1 = m5 - m9 - m13;

    wire signed [29:0] s0_2 = m2 + m6 + m10;
    wire signed [29:0] s1_2 = m6 - m10 - m14;

    wire signed [29:0] s0_3 = m3 + m7 + m11;
    wire signed [29:0] s1_3 = m7 - m11 - m15;

    // ---- output inverse transform: Z = S * A (across the rows) ----
    // same [1 1 1 0; 0 1 -1 -1] pattern, applied to each row of S.
    wire signed [31:0] z0_0 = s0_0 + s0_1 + s0_2;
    wire signed [31:0] z0_1 = s0_1 - s0_2 - s0_3;

    wire signed [31:0] z1_0 = s1_0 + s1_1 + s1_2;
    wire signed [31:0] z1_1 = s1_1 - s1_2 - s1_3;

    // ---- final exact rescale: divide by 4 (the (2G) scale factor
    // squared) via an exact arithmetic right shift -- no rounding,
    // PROVIDED the derivation above is correct (cross-checked by
    // this module's own testbench against a golden direct-conv
    // reference, not trusted blind). ----
    assign y0 = z0_0 >>> 2;
    assign y1 = z0_1 >>> 2;
    assign y2 = z1_0 >>> 2;
    assign y3 = z1_1 >>> 2;
endmodule
