// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- A.1 architecture, seventh building
// block: output write-back ADDRESSING for winograd_conv_engine.v's
// own (out_row,out_col,y0..y3) stream.
//
// Real, deliberate scope for THIS module: address computation ONLY
// -- Cout=1 (a single output channel; a full multi-Cout layer is P
// parallel copies of this whole engine, or one engine re-run P
// times with a different transformed kernel/bias -- a real, later
// decision, not made here). The actual output memory/BRAM/DDR3
// instantiation is deliberately left to the caller -- this module
// only turns (out_row,out_col) into the 4 real flat addresses in a
// row-major (H-2)x(W-2) output feature map, plus the matching data.
// ============================================================
module winograd_writeback_addr #(
    parameter W = 8,
    parameter H = 8
)(
    input  wire                in_valid,
    input  wire [7:0]          in_row,
    input  wire [7:0]          in_col,
    input  wire signed [7:0]   y0, y1, y2, y3,

    output wire                we0, we1, we2, we3,
    output wire [$clog2((W-2)*(H-2))-1:0] addr0, addr1, addr2, addr3,
    output wire signed [7:0]   wdata0, wdata1, wdata2, wdata3
);
    localparam OUT_W = W-2;

    assign we0 = in_valid;
    assign we1 = in_valid;
    assign we2 = in_valid;
    assign we3 = in_valid;

    assign addr0 = (in_row)   * OUT_W + (in_col);
    assign addr1 = (in_row)   * OUT_W + (in_col+1);
    assign addr2 = (in_row+1) * OUT_W + (in_col);
    assign addr3 = (in_row+1) * OUT_W + (in_col+1);

    assign wdata0 = y0;
    assign wdata1 = y1;
    assign wdata2 = y2;
    assign wdata3 = y3;
endmodule
