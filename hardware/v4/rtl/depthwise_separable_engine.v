// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- the full "G-esteso" pipeline:
// g_window_mover_depthwise.v (mover + real per-channel depthwise
// MAC) feeding pointwise_engine.v DIRECTLY, same cycle, no DDR3/
// BRAM round-trip between the two real stages -- the concrete
// realization of this session's own converged design (see
// hardware/v4/docs/DEPTHWISE_SEPARABLE_PIPELINE.md §3).
//
// dw_flat is REGISTERED inside g_window_mover_depthwise.v (in
// lockstep with out_row/out_col -- the real bug already found and
// fixed there); pointwise_engine.v is purely combinational off of
// its dw_flat input, so its own y_flat output tracks the SAME
// registered position automatically, with no separate alignment
// register needed here (unlike winograd_conv_engine.v's own first,
// buggy attempt at this exact same kind of hookup).
// ============================================================
module depthwise_separable_engine #(
    parameter W        = 8,
    parameter H        = 8,
    parameter CIN      = 4,
    parameter COUT     = 4,
    parameter ACC_WIDTH = 40
)(
    input  wire clk,
    input  wire rst,
    input  wire start,

    output wire [$clog2(W*H*CIN)-1:0] mem_addr,
    input  wire signed [7:0]          mem_rdata,

    input  wire signed [72*CIN-1:0]      wd_flat,   // depthwise weights, per channel
    input  wire signed [8*CIN*COUT-1:0]  wp_flat,   // pointwise weights, per (cin,cout)
    input  wire signed [8*COUT-1:0]      bias_flat,
    input  wire [1:0]                    activation,

    output wire                out_valid,
    output wire [7:0]          out_row,
    output wire [7:0]          out_col,
    output wire signed [8*COUT-1:0] y_flat,

    output wire busy,
    output wire done
);
    wire signed [20*CIN-1:0] dw_flat;

    g_window_mover_depthwise #(.W(W), .H(H), .CIN(CIN)) u_mover (
        .clk(clk), .rst(rst), .start(start),
        .mem_addr(mem_addr), .mem_rdata(mem_rdata),
        .wd_flat(wd_flat),
        .out_valid(out_valid), .out_row(out_row), .out_col(out_col), .dw_flat(dw_flat),
        .busy(busy), .done(done)
    );

    pointwise_engine #(.CIN(CIN), .COUT(COUT), .DW_WIDTH(20), .ACC_WIDTH(ACC_WIDTH)) u_pointwise (
        .dw_flat(dw_flat), .wp_flat(wp_flat), .bias_flat(bias_flat), .activation(activation),
        .y_flat(y_flat)
    );
endmodule
