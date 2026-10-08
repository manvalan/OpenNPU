// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- feature-map feeder for dwpw_engine.v.
//
// Streams a layer's input map out of the on-chip feature-map memory in
// the engine's beat order (row, col, group), one 128-bit word (16 INT8
// channels) per beat, inserting the zero padding on the fly (pad = 1:
// a 1-pixel zero border, for the 3x3 depthwise layers; pad = 0 for the
// pointwise-only layers).
//
// Memory layout (same convention as the engine's output writer):
// word(row, col, g) = base + (row*w + col)*ng + g -- the whole map is
// contiguous, so the read address is just a counter that advances on
// every non-padding beat.
//
// Row window (for banded processing): only padded rows r_first..r_last
// are emitted; cfg_base is the address of the first real pixel of row
// window (= map base + max(r_first-pad,0)*w*ng, computed offline).
//
// Memory read port: fixed latency 4 (input reg -> BRAM -> output reg
// -> bank-mux reg),
// no stall. Credit-based: a beat (read or zero) is issued only when the
// output FIFO is guaranteed to have room when it lands.
// ============================================================
module fmap_feeder #(
    parameter AW = 15,     // unified feature-map word address
    parameter DW = 128
)(
    input  wire clk,
    input  wire rst,
    input  wire start,
    output reg  busy,

    input  wire [AW-1:0] cfg_base,     // word address of padded row r_first's first real pixel
    input  wire [7:0]    cfg_w,        // unpadded map width
    input  wire [7:0]    cfg_h,        // unpadded map height
    input  wire [8:0]    cfg_ng,
    input  wire          cfg_pad,
    input  wire [7:0]    cfg_r_first,  // padded row range, inclusive
    input  wire [7:0]    cfg_r_last,

    output reg           rd_en,
    output reg  [AW-1:0] rd_addr,
    input  wire [DW-1:0] rd_data,      // valid 2 cycles after rd_en

    output wire          out_valid,
    input  wire          out_ready,
    output wire [DW-1:0] out_data
);
    // ---------------- configuration latched at start ----------------
    reg [7:0]  wp, hp;        // padded dims
    reg [8:0]  ng;
    reg        pad;
    reg [7:0]  r_last;
    always @(posedge clk) begin
        if (start) begin
            wp     <= cfg_w + (cfg_pad ? 8'd2 : 8'd0);
            hp     <= cfg_h + (cfg_pad ? 8'd2 : 8'd0);
            ng     <= cfg_ng;
            pad    <= cfg_pad;
            r_last <= cfg_r_last;
        end
    end
    // start address of the row window, precomputed by the descriptor
    // generator (base + max(r_first-pad,0)*w*ng): no multiplier here --
    // in the first in-context P&R the registered multiply still missed
    // by -1.6 ns on routing alone
    wire [AW-1:0] start_addr = cfg_base;

    // ---------------- beat generator ----------------
    reg [7:0] r, c;
    reg [8:0] g;
    reg       gen;            // still beats to issue

    // FIFO + in-flight credit
    // 3 beats can be in flight (issue -> rd_en -> BRAM -> output reg),
    // so 8 entries sustain one beat per cycle
    localparam DEPTH = 8;
    reg [DW-1:0] fifo [0:DEPTH-1];
    reg [3:0]    f_cnt;
    reg [2:0]    f_wr, f_rd;
    reg          p1_v, p1_z, p2_v, p2_z;
    reg          p3_v, p3_z, p4_v, p4_z;
    reg          p5_v;
    (* max_fanout = 16 *) reg p5_z;

    wire room  = (f_cnt + p1_v + p2_v + p3_v + p4_v + p5_v) < DEPTH;
    wire issue = gen && room;
    wire is_pad = pad && ((r == 8'd0) || (r == hp - 8'd1) || (c == 8'd0) || (c == wp - 8'd1));
    wire last_beat = (g == ng - 9'd1) && (c == wp - 8'd1) && (r == r_last);

    always @(posedge clk) begin
        if (rst) begin
            gen <= 1'b0; busy <= 1'b0; rd_en <= 1'b0;
        end else if (start) begin
            gen <= 1'b1; busy <= 1'b1; rd_en <= 1'b0;
            r <= cfg_r_first; c <= 8'd0; g <= 9'd0;
            rd_addr <= start_addr;
        end else begin
            rd_en <= 1'b0;
            if (issue) begin
                if (!is_pad) rd_en <= 1'b1;
                // rd_addr presented this cycle is the one registered last
                // time; advance after a real read is issued
                if (last_beat) gen <= 1'b0;
                if (g == ng - 9'd1) begin
                    g <= 9'd0;
                    if (c == wp - 8'd1) begin c <= 8'd0; r <= r + 8'd1; end
                    else c <= c + 8'd1;
                end else g <= g + 9'd1;
            end
            if (rd_en) rd_addr <= rd_addr + 1'b1;
            if (!gen && f_cnt == 4'd0 && !p1_v && !p2_v && !p3_v && !p4_v && !p5_v) busy <= 1'b0;
        end
    end

    // latency pipe: p1 = cycle rd_en is presented to memory, p2 = data out
    always @(posedge clk) begin
        if (rst || start) begin
            p1_v <= 1'b0; p2_v <= 1'b0;
        end else begin
            p1_v <= issue;           p1_z <= is_pad;
            p2_v <= p1_v;            p2_z <= p1_z;
        end
    end

    // p2 data lands one cycle after p2_v (memory latency 2 from rd_en,
    // rd_en is registered one cycle after issue) -> push at p3
    always @(posedge clk) begin
        if (rst || start) begin p3_v <= 1'b0; p4_v <= 1'b0; p5_v <= 1'b0; end
        else begin p3_v <= p2_v; p3_z <= p2_z; p4_v <= p3_v; p4_z <= p3_z; p5_v <= p4_v; p5_z <= p4_z; end
    end

    wire pop  = out_valid && out_ready;
    always @(posedge clk) begin
        if (rst || start) begin
            f_cnt <= 4'd0; f_wr <= 3'd0; f_rd <= 3'd0;
        end else begin
            if (p5_v) begin
                fifo[f_wr] <= p5_z ? {DW{1'b0}} : rd_data;
                f_wr <= f_wr + 3'd1;
            end
            if (pop) f_rd <= f_rd + 3'd1;
            f_cnt <= f_cnt + p5_v - pop;
        end
    end
    assign out_valid = (f_cnt != 4'd0);
    assign out_data  = fifo[f_rd];
endmodule
