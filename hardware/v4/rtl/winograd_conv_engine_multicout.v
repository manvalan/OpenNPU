// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- A.1 architecture, Cout extension:
// ONE shared G mover feeding COUT parallel winograd_f23_neuron
// instances (spatial parallelism, per this session's own real
// rationale: the expensive "moving" part -- reading/row-buffering
// -- is shared across all output channels since they all consume
// the SAME input tile; only the cheap per-channel math replicates).
// Real, deliberate choice over time-multiplexing a single neuron
// COUT times -- that alternative trades this module's extra area
// for lower throughput, a real, separate sizing decision (matches
// "M" from this session's own earlier brainstorm) not made here.
//
// Output feature map layout: row-major, channel-interleaved (see
// winograd_writeback_addr_multicout.v's own header) -- deliberately
// matching the INPUT layout g_window_mover.v already uses, so a
// future multi-layer chain needs no reshuffle between layers.
// ============================================================
module winograd_conv_engine_multicout #(
    parameter W        = 8,
    parameter H        = 8,
    parameter CIN      = 2,
    parameter COUT     = 3,
    parameter ACC_WIDTH = 48
)(
    input  wire clk,
    input  wire rst,
    input  wire start,

    output wire [$clog2(W*H*CIN)-1:0] mem_addr,
    input  wire signed [7:0]          mem_rdata,

    input  wire signed [COUT*16*16*CIN-1:0] u_flat_mc,
    input  wire signed [8*COUT-1:0]         bias_flat,
    input  wire [1:0]                       activation,

    output wire                out_valid,
    output wire [7:0]          out_row,
    output wire [7:0]          out_col,
    output wire signed [8*4*COUT-1:0] y_flat,

    output wire [4*COUT-1:0]                                  we_flat,
    output wire [4*COUT*$clog2((W-2)*(H-2)*COUT)-1:0]         waddr_flat,
    output wire signed [8*4*COUT-1:0]                         wdata_flat,

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

    genvar oc;
    generate
        for (oc = 0; oc < COUT; oc = oc + 1) begin : GEN_COUT
            wire signed [7:0] ny0, ny1, ny2, ny3;
            winograd_f23_neuron #(.CIN(CIN), .DATA_WIDTH(8), .ACC_WIDTH(ACC_WIDTH)) u_neuron (
                .d_flat(d_flat),
                .u_flat(u_flat_mc[oc*16*16*CIN +: 16*16*CIN]),
                .bias(bias_flat[oc*8 +: 8]),
                .activation(activation),
                .y0(ny0), .y1(ny1), .y2(ny2), .y3(ny3)
            );
            assign y_flat[oc*32 + 0*8 +: 8] = ny0;
            assign y_flat[oc*32 + 1*8 +: 8] = ny1;
            assign y_flat[oc*32 + 2*8 +: 8] = ny2;
            assign y_flat[oc*32 + 3*8 +: 8] = ny3;
        end
    endgenerate

    assign out_valid = tile_valid;
    assign out_row   = mover_row;
    assign out_col   = mover_col;

    winograd_writeback_addr_multicout #(.W(W), .H(H), .COUT(COUT)) u_wbaddr (
        .in_valid(tile_valid), .in_row(mover_row), .in_col(mover_col), .y_flat(y_flat),
        .we_flat(we_flat), .addr_flat(waddr_flat), .wdata_flat(wdata_flat)
    );
endmodule
