// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- A.1 architecture, fourth building
// block: the complete Winograd F(2x2,3x3) "neuron" -- CIN-channel
// tile convolution + bias + activation + saturation, composing the
// two already-verified pieces (winograd_f23_multichan.v,
// winograd_f23_output_stage.v) unmodified. Still combinational,
// still no pipelining, still no G/mover integration -- this is the
// complete PER-TILE math, nothing about how tiles arrive yet.
// ============================================================
module winograd_f23_neuron #(
    parameter CIN        = 4,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 48
)(
    input  wire signed [8*16*CIN-1:0]  d_flat,
    input  wire signed [16*16*CIN-1:0] u_flat,
    input  wire signed [DATA_WIDTH-1:0] bias,
    input  wire [1:0]                   activation,

    output wire signed [DATA_WIDTH-1:0] y0, y1, y2, y3
);
    wire signed [ACC_WIDTH-1:0] acc0, acc1, acc2, acc3;

    winograd_f23_multichan #(.CIN(CIN)) u_multichan (
        .d_flat(d_flat), .u_flat(u_flat),
        .y0(acc0), .y1(acc1), .y2(acc2), .y3(acc3)
    );

    winograd_f23_output_stage #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) u_output (
        .acc0(acc0), .acc1(acc1), .acc2(acc2), .acc3(acc3),
        .bias(bias), .activation(activation),
        .y0(y0), .y1(y1), .y2(y2), .y3(y3)
    );
endmodule
