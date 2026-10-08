// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- A.1 architecture, second isolated
// building block: multi-input-channel accumulation on top of the
// already-verified single-channel winograd_f23_core.v (2005/2005
// bit-exact vs golden direct conv). One variable at a time: this
// module ONLY adds the Cin summation -- still no saturation, no
// pipelining, no G/mover integration.
//
// Real, deliberate design choice for THIS step: CIN parallel core
// instances (spatial, not time-multiplexed) summed combinationally
// -- proves the accumulation math is correct cheaply, without yet
// committing to the parallel-vs-serial hardware tradeoff (that is
// a real, separate decision once M/throughput sizing is done later,
// not guessed now).
//
// Bit widths are DELIBERATELY generous (correctness-first
// prototype, not yet synthesis-size-optimized) -- tightening them
// is real, disclosed future work, not done here.
//
// Bus layout convention (matches this project's established flat-
// bus style, e.g. sdram_arbiter_n.v's own req_wdata[...] packing):
//   d_flat[8*16*CIN-1:0]  -- CIN groups of 16 INT8 tile values,
//                            group ci occupies bits [ci*128 +: 128],
//                            value index v within a group at
//                            [ci*128 + v*8 +: 8].
//   u_flat[16*16*CIN-1:0] -- CIN groups of 16 INT16 transformed-
//                            kernel constants, same per-group
//                            layout at 16 bits/value.
// ============================================================
module winograd_f23_multichan #(
    parameter CIN = 4
) (
    input  wire signed [8*16*CIN-1:0]  d_flat,
    input  wire signed [16*16*CIN-1:0] u_flat,
    output wire signed [47:0] y0, y1, y2, y3
);
    wire signed [39:0] c_y0 [0:CIN-1];
    wire signed [39:0] c_y1 [0:CIN-1];
    wire signed [39:0] c_y2 [0:CIN-1];
    wire signed [39:0] c_y3 [0:CIN-1];

    genvar gi;
    generate
        for (gi = 0; gi < CIN; gi = gi + 1) begin : GEN_CHAN
            winograd_f23_core u_core (
                .d0 (d_flat[gi*128 + 0*8  +: 8]),  .d1 (d_flat[gi*128 + 1*8  +: 8]),
                .d2 (d_flat[gi*128 + 2*8  +: 8]),  .d3 (d_flat[gi*128 + 3*8  +: 8]),
                .d4 (d_flat[gi*128 + 4*8  +: 8]),  .d5 (d_flat[gi*128 + 5*8  +: 8]),
                .d6 (d_flat[gi*128 + 6*8  +: 8]),  .d7 (d_flat[gi*128 + 7*8  +: 8]),
                .d8 (d_flat[gi*128 + 8*8  +: 8]),  .d9 (d_flat[gi*128 + 9*8  +: 8]),
                .d10(d_flat[gi*128 + 10*8 +: 8]),  .d11(d_flat[gi*128 + 11*8 +: 8]),
                .d12(d_flat[gi*128 + 12*8 +: 8]),  .d13(d_flat[gi*128 + 13*8 +: 8]),
                .d14(d_flat[gi*128 + 14*8 +: 8]),  .d15(d_flat[gi*128 + 15*8 +: 8]),

                .u0 (u_flat[gi*256 + 0*16  +: 16]), .u1 (u_flat[gi*256 + 1*16  +: 16]),
                .u2 (u_flat[gi*256 + 2*16  +: 16]), .u3 (u_flat[gi*256 + 3*16  +: 16]),
                .u4 (u_flat[gi*256 + 4*16  +: 16]), .u5 (u_flat[gi*256 + 5*16  +: 16]),
                .u6 (u_flat[gi*256 + 6*16  +: 16]), .u7 (u_flat[gi*256 + 7*16  +: 16]),
                .u8 (u_flat[gi*256 + 8*16  +: 16]), .u9 (u_flat[gi*256 + 9*16  +: 16]),
                .u10(u_flat[gi*256 + 10*16 +: 16]), .u11(u_flat[gi*256 + 11*16 +: 16]),
                .u12(u_flat[gi*256 + 12*16 +: 16]), .u13(u_flat[gi*256 + 13*16 +: 16]),
                .u14(u_flat[gi*256 + 14*16 +: 16]), .u15(u_flat[gi*256 + 15*16 +: 16]),

                .y0(c_y0[gi]), .y1(c_y1[gi]), .y2(c_y2[gi]), .y3(c_y3[gi])
            );
        end
    endgenerate

    reg signed [47:0] sum0, sum1, sum2, sum3;
    integer si;
    always @(*) begin
        sum0 = {48{1'b0}};
        sum1 = {48{1'b0}};
        sum2 = {48{1'b0}};
        sum3 = {48{1'b0}};
        for (si = 0; si < CIN; si = si + 1) begin
            sum0 = sum0 + c_y0[si];
            sum1 = sum1 + c_y1[si];
            sum2 = sum2 + c_y2[si];
            sum3 = sum3 + c_y3[si];
        end
    end

    assign y0 = sum0;
    assign y1 = sum1;
    assign y2 = sum2;
    assign y3 = sum3;
endmodule
