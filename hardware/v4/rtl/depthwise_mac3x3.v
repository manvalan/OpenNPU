// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- real cost probe for the "G-esteso"
// depthwise-separable direction: ONE channel's direct 3x3 depthwise
// MAC (no Winograd, no transform -- depthwise's own MAC count is
// already tiny, 9 multiplies, so there is little for a transform to
// optimize away, per this session's own real finding). Weight is a
// genuine runtime PORT here (the realistic, flexible case) --
// learned from the Winograd probe not to assume "constant = free"
// without a real, separate synthesis check of that case too.
// ============================================================
module depthwise_mac3x3 (
    input  wire signed [7:0] d0, d1, d2,
    input  wire signed [7:0] d3, d4, d5,
    input  wire signed [7:0] d6, d7, d8,

    input  wire signed [7:0] w0, w1, w2,
    input  wire signed [7:0] w3, w4, w5,
    input  wire signed [7:0] w6, w7, w8,

    output wire signed [19:0] y
);
    // REAL BUG found and fixed via this module's own testbench: the
    // intermediate accumulator was declared only 17 bits wide,
    // silently truncating the real worst case (9 terms x +-16384 max
    // magnitude each = +-147456, needs 19 bits signed, not 17) --
    // caught immediately by the deliberately adversarial max/min
    // edge cases, not by the 2000 random trials (which never
    // happened to hit the extreme corner).
    wire signed [19:0] acc;
    assign acc = d0*w0 + d1*w1 + d2*w2 +
                 d3*w3 + d4*w4 + d5*w5 +
                 d6*w6 + d7*w7 + d8*w8;
    assign y = acc;
endmodule
