// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- parameter loader: streams one pass's parameters from DDR3 into
// one half of the core's on-chip double buffers, while the previous
// pass computes out of the other half.
//
// Load descriptor (128 bits, see gen_mfn.c):
//   [24:0] w_ddr   [33:25] w_cnt (2048-bit weight words)
//   [58:34] dww_ddr [64:59] dw_groups
//   [89:65] dwq_ddr [114:90] pwq_ddr [120:115] pw_tiles
// DDR addresses/lengths are in 128-bit words. Four segments, each one
// read request, in order; every returned word is written to the right
// 128-bit chunk of the right on-chip memory (sel as v4_core's host port:
// 1 pw weights [16 chunks/word], 2 dw weights [9], 3 dw requant [5],
// 4 pw requant [5]), half 0 or 1 selecting the buffer half.
//
// DDR side: generic request/stream port (req_valid/ready + addr/len,
// then rvalid words in order) -- the MIG adapter sits behind it.
// ============================================================
module param_loader (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire [127:0] ldesc,
    input  wire         half,
    output wire         busy,

    output reg          req_valid,
    input  wire         req_ready,
    output reg  [24:0]  req_addr,
    output reg  [15:0]  req_len,
    input  wire         rvalid,
    input  wire [127:0] rdata,

    output reg          wr_en,
    output reg  [2:0]   wr_sel,
    output reg  [15:0]  wr_addr,
    output reg  [3:0]   wr_chunk,
    output reg  [127:0] wr_data
);
    localparam S_IDLE = 2'd0, S_REQ = 2'd1, S_DATA = 2'd2, S_LEN = 2'd3;
    reg [1:0]   st;
    reg [1:0]   seg;          // 0 w, 1 dww, 2 dwq, 3 pwq
    reg [127:0] ld;
    reg         hf;
    reg [15:0]  left;         // words still to receive in this segment
    reg [15:0]  row;
    reg [3:0]   chunk;
    reg [15:0]  cur_len;      // registered segment length (the unregistered
                              // groups*9 feeding the request logic was the
                              // worst path of the streaming core's synthesis)
    reg [24:0]  cur_addr;
    assign busy = (st != S_IDLE) || start || wr_en;

    wire [8:0]  w_cnt  = ld[33:25];
    wire [5:0]  groups = ld[64:59];
    wire [5:0]  tiles  = ld[120:115];

    function [15:0] seg_len(input [1:0] s);
        case (s)
            2'd0: seg_len = {3'd0, w_cnt, 4'd0};           // x16
            2'd1: seg_len = groups * 9;
            2'd2: seg_len = groups * 5;
            default: seg_len = tiles * 5;
        endcase
    endfunction
    function [24:0] seg_addr(input [1:0] s);
        case (s)
            2'd0: seg_addr = ld[24:0];
            2'd1: seg_addr = ld[58:34];
            2'd2: seg_addr = ld[89:65];
            default: seg_addr = ld[114:90];
        endcase
    endfunction
    wire [3:0] last_chunk = (seg == 2'd0) ? 4'd15 : ((seg == 2'd1) ? 4'd8 : 4'd4);
    wire [15:0] row_base  = (seg == 2'd0) ? {7'd0, hf, 8'd0} : {10'd0, hf, 5'd0};

    always @(posedge clk) begin
        wr_en <= 1'b0;
        if (rst) begin
            st <= S_IDLE; req_valid <= 1'b0;
        end else case (st)
            S_IDLE: if (start) begin
                ld <= ldesc; hf <= half; seg <= 2'd0; st <= S_LEN;
            end
            S_LEN: begin
                cur_len  <= seg_len(seg);
                cur_addr <= seg_addr(seg);
                st <= S_REQ;
            end
            S_REQ: begin
                if (cur_len == 16'd0) begin
                    if (seg == 2'd3) st <= S_IDLE; else begin seg <= seg + 2'd1; st <= S_LEN; end
                end else if (!req_valid) begin
                    req_valid <= 1'b1;
                    req_addr  <= cur_addr;
                    req_len   <= cur_len;
                    left  <= cur_len;
                    row   <= 16'd0;
                    chunk <= 4'd0;
                end else if (req_ready) begin
                    req_valid <= 1'b0;
                    st <= S_DATA;
                end
            end
            S_DATA: if (rvalid) begin
                wr_en    <= 1'b1;
                wr_sel   <= {1'b0, seg} + 3'd1;
                wr_addr  <= row_base + row;
                wr_chunk <= chunk;
                wr_data  <= rdata;
                if (chunk == last_chunk) begin chunk <= 4'd0; row <= row + 16'd1; end
                else chunk <= chunk + 4'd1;
                left <= left - 16'd1;
                if (left == 16'd1) begin
                    if (seg == 2'd3) st <= S_IDLE;
                    else begin seg <= seg + 2'd1; st <= S_LEN; end
                end
            end
            default: st <= S_IDLE;
        endcase
    end
endmodule
