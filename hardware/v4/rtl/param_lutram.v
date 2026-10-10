// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps
// ============================================================
// v4 -- one 128-bit chunk of a parameter memory (dw weights, dw / pw
// requant parameters): distributed RAM, synchronous write, asynchronous
// read. Its own kept hierarchy, so that synthesis can neither merge
// chunks that share the write address and data (Vivado fused the 5 dw
// requant chunks into one memory written only by chunk 4's enable,
// 2026-10-08 netlist simulation) nor move a chunk into another module.
// ============================================================
(* keep_hierarchy = "yes" *)
module param_lutram #(
    parameter DEPTH = 64,
    parameter AW    = 6
)(
    input  wire         clk,
    input  wire         we,
    input  wire [AW-1:0] waddr,
    input  wire [127:0] wdata,
    input  wire [11:0]  raddr,
    output wire [127:0] rdata
);
    (* ram_style = "distributed" *) reg [127:0] mem [0:DEPTH-1];
    always @(posedge clk)
        if (we) mem[waddr] <= wdata;
    assign rdata = mem[raddr];
endmodule
