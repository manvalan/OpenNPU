// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- REAL synthesis probe, not a
// correctness testbench: checks whether Vivado actually folds the
// element-wise multiply into a cheap constant-coefficient LUT/
// carry-chain structure (as this session's brainstorm hypothesized)
// when the transformed kernel is a TRUE, hardwired Verilog constant
// -- not a module port (which the first real synthesis run just
// proved does NOT get this benefit: 272 DSP48E1, 113% of the whole
// chip, for a single CIN=4/COUT=4 engine instance with the kernel
// left as a port). Single channel, deliberately minimal, to isolate
// the ONE variable this probe exists to test.
// ============================================================
module synth_probe_const_kernel (
    input  wire signed [7:0] d0,  d1,  d2,  d3,
    input  wire signed [7:0] d4,  d5,  d6,  d7,
    input  wire signed [7:0] d8,  d9,  d10, d11,
    input  wire signed [7:0] d12, d13, d14, d15,
    output wire signed [39:0] y0, y1, y2, y3
);
    // arbitrary but FIXED kernel-transform constants (representative
    // magnitudes, not a real trained kernel -- this probe checks
    // synthesis behavior, not numerical correctness, already proven
    // separately by tb_winograd_f23_core.v).
    winograd_f23_core u_core (
        .d0(d0), .d1(d1), .d2(d2), .d3(d3),
        .d4(d4), .d5(d5), .d6(d6), .d7(d7),
        .d8(d8), .d9(d9), .d10(d10), .d11(d11),
        .d12(d12), .d13(d13), .d14(d14), .d15(d15),

        .u0(16'sd214),  .u1(16'sd57),   .u2(-16'sd128), .u3(16'sd6),
        .u4(-16'sd310), .u5(16'sd12),   .u6(16'sd89),   .u7(-16'sd44),
        .u8(16'sd7),    .u9(-16'sd256), .u10(16'sd171), .u11(16'sd0),
        .u12(16'sd33),  .u13(-16'sd91), .u14(16'sd512), .u15(-16'sd18),

        .y0(y0), .y1(y1), .y2(y2), .y3(y3)
    );
endmodule
