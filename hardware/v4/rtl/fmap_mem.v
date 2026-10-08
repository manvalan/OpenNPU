// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- on-chip feature-map memory: NB banks of BANK_WORDS x 128-bit
// (one word = 16 INT8 channels of one pixel). Unified word address
// {bank, local}. Each bank is a simple-dual-port BRAM (1 read, 1 write)
// with an input register (per-bank enable/address: rd_en fanned out to
// 32 BRAMs at -0.66 ns in the third P&R), an output register, and a
// register after the bank multiplexer (the unregistered mux measured
// ~-1.0 ns in the second P&R): read latency 4 after rd_en.
//
// Two read clients (the feeder and the residual reader) share the
// banks' read ports: the layer descriptors place the tensors a layer
// reads at the same time in DIFFERENT banks, so each bank's read port
// is used by at most one client per cycle. `conflict` is a sticky flag
// that catches a descriptor violating this (must stay 0).
//
// Sizing for MobileFaceNet (hardware/v4/docs/PROGRESS_LOG.md, V4-S3):
// 3 banks x 8192 words = 384 KB = 96 RAMB36 (each 8K x 4 bits, no
// parity waste).
// ============================================================
module fmap_mem #(
    parameter NB         = 3,
    parameter BANK_WORDS = 8192,
    parameter AW         = 15
)(
    input  wire clk,
    input  wire rst,

    input  wire          rd0_en,
    input  wire [AW-1:0] rd0_addr,
    output wire [127:0]  rd0_data,

    input  wire          rd1_en,
    input  wire [AW-1:0] rd1_addr,
    output wire [127:0]  rd1_data,

    input  wire          wr_en,
    input  wire [AW-1:0] wr_addr,
    input  wire [127:0]  wr_data,

    output reg           conflict,
    output wire          wr_busy     // a write is still on its way into a bank
);
    localparam LW = $clog2(BANK_WORDS);
    localparam BW = AW - LW;

    // input registers (reads AND the write, so ordering is unchanged)
    // r0e/r1e enable the 90 BRAMs of the three banks (first fixed board
    // P&R: r1e -> ENBWREN -0.083 ns, one level, all route): replicated
    (* max_fanout = 16 *) reg r0e, r1e;
    reg          we;
    (* max_fanout = 16 *) reg [AW-1:0] r0a, r1a, wa;
    reg [127:0]  wd;
    always @(posedge clk) begin
        r0e <= rd0_en; r0a <= rd0_addr;
        r1e <= rd1_en; r1a <= rd1_addr;
        we  <= wr_en && !rst; wa <= wr_addr; wd <= wr_data;
    end
    wire [BW-1:0] b0 = r0a[AW-1:LW];
    wire [BW-1:0] b1 = r1a[AW-1:LW];
    wire [BW-1:0] bw = wa[AW-1:LW];

    // each bank is two half-depth arrays (low / high half of the bank's
    // words): 4K x 128 maps to 15 RAMB36 in 4K x 9, against 32 for one
    // 8K x 128 array in 8K x 4 (2026-10-08 area cut, -6 RAMB36 for 3
    // banks). Both halves are read at the same address; the delayed
    // {bank, half} selects the output.
    localparam HW = LW - 1;
    (* max_fanout = 32 *) reg [BW:0] b0_d2, b1_d2;
    reg [BW:0] b0_d1, b1_d1;
    always @(posedge clk) begin
        b0_d1 <= r0a[AW-1:HW]; b0_d2 <= b0_d1;
        b1_d1 <= r1a[AW-1:HW]; b1_d2 <= b1_d1;
    end

    wire [127:0] q [0:2*NB-1];
    wire [NB-1:0] wk_any;
    genvar k;
    generate
        for (k = 0; k < NB; k = k + 1) begin : GEN_BANK
            (* ram_style = "block" *) reg [127:0] mem_l [0:BANK_WORDS/2-1];
            (* ram_style = "block" *) reg [127:0] mem_h [0:BANK_WORDS/2-1];
            reg [127:0] q1l, q1h, q2l, q2h;
            wire sel0 = r0e && (b0 == k);
            wire sel1 = r1e && (b1 == k);
            wire [HW-1:0] ra = sel0 ? r0a[HW-1:0] : r1a[HW-1:0];
            // local copy of the write port next to each bank (the first
            // generic-board P&R had wd/wa -> the 32 BRAMs of each bank at
            // -0.77 / -0.69 ns, all route). One more cycle of write
            // latency; a pass ends only when wr_busy is low.
            (* keep = "true" *)                  reg          wk_en, wk_h;
            (* keep = "true", max_fanout = 16 *) reg [HW-1:0] wk_a;
            (* keep = "true" *)                  reg [127:0]  wk_d;
            always @(posedge clk) begin
                if (sel0 || sel1) begin q1l <= mem_l[ra]; q1h <= mem_h[ra]; end
                q2l <= q1l; q2h <= q1h;
                wk_en <= we && bw == k; wk_h <= wa[HW]; wk_a <= wa[HW-1:0]; wk_d <= wd;
                if (wk_en && !wk_h) mem_l[wk_a] <= wk_d;
                if (wk_en &&  wk_h) mem_h[wk_a] <= wk_d;
            end
            assign q[2*k]   = q2l;
            assign q[2*k+1] = q2h;
            assign wk_any[k] = wk_en;
        end
    endgenerate

    reg [127:0] rd0_q, rd1_q;
    always @(posedge clk) begin
        rd0_q <= q[b0_d2];
        rd1_q <= q[b1_d2];
    end
    assign wr_busy  = we | (|wk_any);
    assign rd0_data = rd0_q;
    assign rd1_data = rd1_q;

    always @(posedge clk) begin
        if (rst) conflict <= 1'b0;
        else if (r0e && r1e && b0 == b1) conflict <= 1'b1;
    end
endmodule
