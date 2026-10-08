// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- pipelined fork of depthwise_mac3x3.v (same math, same 20-bit
// result, same accumulator width fix), split into 3 register stages so
// it no longer sets the clock: the combinational original measured
// WNS=-7.2ns against a 5ns clock inside dw_linebuf_stream (LANES=16,
// OOC synthesis, 2026-09-28) -- 9 LUT multiplies + a 9-input add in
// one cycle.
//
//   stage 1: 9 products (16-bit each), registered
//   stage 2: 3 partial sums of 3 products (18-bit), registered
//   stage 3: final sum (20-bit), registered  -> y
//
// Latency 3 cycles, one result per cycle; every register is gated by
// `en` so a caller's global stall freezes it bit-exactly.
// ============================================================
module depthwise_mac3x3_pipe (
    input  wire clk,
    input  wire en,
    input  wire signed [7:0] d0, d1, d2,
    input  wire signed [7:0] d3, d4, d5,
    input  wire signed [7:0] d6, d7, d8,

    input  wire signed [7:0] w0, w1, w2,
    input  wire signed [7:0] w3, w4, w5,
    input  wire signed [7:0] w6, w7, w8,

    output reg  signed [19:0] y
);
    reg signed [15:0] p0, p1, p2, p3, p4, p5, p6, p7, p8;
    reg signed [17:0] s0, s1, s2;

    always @(posedge clk) begin
        if (en) begin
            p0 <= d0*w0; p1 <= d1*w1; p2 <= d2*w2;
            p3 <= d3*w3; p4 <= d4*w4; p5 <= d5*w5;
            p6 <= d6*w6; p7 <= d7*w7; p8 <= d8*w8;

            s0 <= p0 + p1 + p2;
            s1 <= p3 + p4 + p5;
            s2 <= p6 + p7 + p8;

            y  <= s0 + s1 + s2;
        end
    end
endmodule
