// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- A.1 architecture, sixth building
// block: the full per-layer conv engine -- G (g_window_mover.v)
// feeding winograd_f23_neuron.v directly, tile by tile, for an
// entire feature map. First real end-to-end integration of the
// mover and the math core (previously verified only separately).
//
// Real, deliberate scope for THIS module: single conv layer, one
// (row,col) output position stream, NO output-memory-write logic
// yet (the caller captures d_out/out_row/out_col/out_valid itself)
// -- writing results back to a memory/DDR3-like sink is a real,
// separate, later concern.
//
// Kernel is supplied ALREADY TRANSFORMED (u_flat, per-channel,
// standing in for the offline "compiler" tool -- per this
// project's own A/5 design, this transform never runs in real
// hardware).
// ============================================================
module winograd_conv_engine #(
    parameter W        = 8,
    parameter H        = 8,
    parameter CIN      = 2,
    parameter ACC_WIDTH = 48
)(
    input  wire clk,
    input  wire rst,
    input  wire start,

    output wire [$clog2(W*H*CIN)-1:0] mem_addr,
    input  wire signed [7:0]          mem_rdata,

    input  wire signed [16*16*CIN-1:0] u_flat,
    input  wire signed [7:0]           bias,
    input  wire [1:0]                  activation,

    output wire                out_valid,
    output wire [7:0]           out_row,
    output wire [7:0]           out_col,
    output wire signed [7:0]    y0, y1, y2, y3,   // the 2x2 output tile

    // ---- ready-to-write output addressing (winograd_writeback_addr.v),
    // Cout=1, row-major (H-2)x(W-2) output feature map ----
    output wire                 we0, we1, we2, we3,
    output wire [$clog2((W-2)*(H-2))-1:0] waddr0, waddr1, waddr2, waddr3,
    output wire signed [7:0]    wdata0, wdata1, wdata2, wdata3,

    output wire busy,
    output wire done
);
    wire tile_valid;
    wire [7:0] mover_row, mover_col;
    wire signed [8*16*CIN-1:0] d_flat;

    g_window_mover #(.W(W), .H(H), .CIN(CIN)) u_mover (
        .clk(clk), .rst(rst), .start(start),
        .mem_addr(mem_addr), .mem_rdata(mem_rdata),
        .tile_valid(tile_valid), .out_row(mover_row), .out_col(mover_col), .d_flat(d_flat),
        .busy(busy), .done(done)
    );

    winograd_f23_neuron #(.CIN(CIN), .DATA_WIDTH(8), .ACC_WIDTH(ACC_WIDTH)) u_neuron (
        .d_flat(d_flat), .u_flat(u_flat),
        .bias(bias), .activation(activation),
        .y0(y0), .y1(y1), .y2(y2), .y3(y3)
    );

    // ---- the neuron is purely combinational off of d_flat, which
    // g_window_mover updates on the SAME edge as tile_valid -- so
    // tile_valid/mover_row/mover_col and y0..y3 are already aligned
    // in the same cycle. A REGISTERED version of this interface
    // (real, deliberate future work once this is proven correct
    // combinationally first) would need to register y0..y3 too, in
    // lockstep -- not done here, to avoid a one-cycle misalignment
    // bug (caught before testing, not after).
    assign out_valid = tile_valid;
    assign out_row   = mover_row;
    assign out_col   = mover_col;

    winograd_writeback_addr #(.W(W), .H(H)) u_wbaddr (
        .in_valid(tile_valid), .in_row(mover_row), .in_col(mover_col),
        .y0(y0), .y1(y1), .y2(y2), .y3(y3),
        .we0(we0), .we1(we1), .we2(we2), .we3(we3),
        .addr0(waddr0), .addr1(waddr1), .addr2(waddr2), .addr3(waddr3),
        .wdata0(wdata0), .wdata1(wdata1), .wdata2(wdata2), .wdata3(wdata3)
    );
endmodule
