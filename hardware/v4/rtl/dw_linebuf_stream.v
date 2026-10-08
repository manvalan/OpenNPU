// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- G-esteso, step 1: depthwise 3x3 with the
// row buffer in BLOCK RAM (fork of g_window_mover_depthwise.v, which
// stays untouched as the verified reference).
//
// Why a fork and not a (* ram_style *) on the old rowbuf: the old
// module reads 9 window taps per channel per cycle straight out of the
// 3-row array at runtime-computed column offsets. No BRAM has 9 read
// ports, so Vivado mapped it to 24,576 flip-flops (W=64/CIN=16 OOC).
// Here the classic line-buffer form is used instead:
//
//   * input is a STREAM of pixels, raster order (row-major), one pixel
//     = all LANES channels (LANES*8 bits) per accepted beat;
//   * ONE simple-dual-port RAM, MAXW words deep, 2*LANES*8 bits wide:
//     word[c] = {row r-1, row r-2} at column c. At pixel (r,c) the RAM
//     is read at c (one read port) and, one cycle later, rewritten at c
//     with {pixel(r,c), row r-1} (one write port) -- exactly the
//     1R+1W a 7-series RAMB18/36 SDP offers;
//   * the 3x3 window is a 3x3 x LANES shift register (per channel),
//     shifted one column per accepted pixel -- the only place taps are
//     read, all at fixed indices (no runtime-indexed part-selects).
//
// Padding is NOT done here: the feeder streams an already-padded frame
// (cfg_w x cfg_h include the pad), so this block stays a plain "valid"
// 3x3 conv. out_row/out_col are the output coordinates (already divided
// by the stride).
//
// Flow control: one global advance enable, en = !out_valid | out_ready.
// Every pipeline register, the RAM read (re) and the RAM write are all
// gated by en, so a stall freezes the whole block bit-exactly.
//
// Pipeline (all gated by en):
//   S1: accept pixel, RAM read at col c; register pixel, r, c
//   S2: RAM dout = {r-1, r-2} at c; write back {pix, r-1}; shift window
//   S3-S5: 3-stage pipelined depthwise MAC (depthwise_mac3x3_pipe)
// ============================================================
module dw_linebuf_stream #(
    parameter LANES = 4,     // channels processed in parallel
    parameter MAXW  = 16     // max frame width (padded), RAM depth
)(
    input  wire clk,
    input  wire rst,
    input  wire start,                 // pulse: reset row/col counters

    input  wire [7:0] cfg_w,           // padded frame width  (>= 3)
    input  wire [7:0] cfg_h,           // padded frame height (>= 3)
    input  wire       cfg_stride2,     // 0: stride 1, 1: stride 2

    input  wire                      in_valid,
    output wire                      in_ready,
    input  wire signed [8*LANES-1:0] in_pix,

    // 9 weights per lane, kr*3+kc order: lane l at [l*72 + (kr*3+kc)*8 +: 8]
    input  wire signed [72*LANES-1:0] wd_flat,

    output reg                       out_valid,
    input  wire                      out_ready,
    output reg  [7:0]                out_row,
    output reg  [7:0]                out_col,
    output reg                       out_last,
    output wire signed [20*LANES-1:0] dw_flat
);
    localparam PW = 8*LANES;
    localparam AW = (MAXW <= 2) ? 1 : $clog2(MAXW);

    wire en = !out_valid || out_ready;
    assign in_ready = en;
    wire acc_in = in_valid && en;

    // ---------------- position counters (S1) ----------------
    reg [7:0] r_cnt, c_cnt;
    always @(posedge clk) begin
        if (rst || start) begin
            r_cnt <= 8'd0;
            c_cnt <= 8'd0;
        end else if (acc_in) begin
            if (c_cnt == cfg_w - 8'd1) begin
                c_cnt <= 8'd0;
                r_cnt <= r_cnt + 8'd1;
            end else begin
                c_cnt <= c_cnt + 8'd1;
            end
        end
    end

    // ---------------- line buffer RAM (SDP, 1R + 1W) ----------------
    (* ram_style = "block" *) reg [2*PW-1:0] lb [0:MAXW-1];
    reg  [2*PW-1:0] lb_dout;
    reg             lb_we;
    reg  [AW-1:0]   lb_waddr;
    reg  [2*PW-1:0] lb_wdata;

    always @(posedge clk) begin
        if (en) lb_dout <= lb[c_cnt[AW-1:0]];
        if (lb_we) lb[lb_waddr] <= lb_wdata;
    end

    // ---------------- S1 -> S2 registers ----------------
    reg          v1;
    reg [7:0]    r1, c1;
    reg [PW-1:0] pix1;
    always @(posedge clk) begin
        if (rst || start) begin
            v1 <= 1'b0;
        end else if (en) begin
            v1   <= in_valid;
            r1   <= r_cnt;
            c1   <= c_cnt;
            pix1 <= in_pix;
        end
    end

    // ---------------- S2: write back + window shift ----------------
    // row_m1 = row r-1, row_m2 = row r-2 at column c1 (RAM contents are
    // only meaningful once r1 >= 2; outputs before that are masked).
    wire [PW-1:0] row_m1 = lb_dout[2*PW-1:PW];
    wire [PW-1:0] row_m2 = lb_dout[PW-1:0];

    always @(posedge clk) begin
        lb_we    <= 1'b0;
        if (!rst && en && v1) begin
            lb_we    <= 1'b1;
            lb_waddr <= c1[AW-1:0];
            lb_wdata <= {pix1, row_m1};
        end
    end

    // window: wN_k = row k (0 = top = r-2, 2 = bottom = r), col N (0 = left)
    reg [PW-1:0] w00, w01, w02, w10, w11, w12, w20, w21, w22;
    reg          v2, last2;
    reg [7:0]    orow2, ocol2;

    wire r_ok  = (r1 >= 8'd2) && (!cfg_stride2 || !r1[0]);
    wire c_ok  = (c1 >= 8'd2) && (!cfg_stride2 || !c1[0]);
    // last output of the frame: bottom-right-most valid window position.
    // For stride 2 with even padded size the last row/col index is odd
    // and is not a valid centre -- handled by comparing against the
    // last position that actually emits.
    wire [7:0] last_r = cfg_stride2 ? ((cfg_h - 8'd1) & 8'hFE) : (cfg_h - 8'd1);
    wire [7:0] last_c = cfg_stride2 ? ((cfg_w - 8'd1) & 8'hFE) : (cfg_w - 8'd1);

    always @(posedge clk) begin
        if (rst || start) begin
            v2 <= 1'b0;
            last2 <= 1'b0;
        end else if (en) begin
            v2    <= v1 && r_ok && c_ok;
            last2 <= v1 && (r1 == last_r) && (c1 == last_c);
            orow2 <= cfg_stride2 ? ((r1 - 8'd2) >> 1) : (r1 - 8'd2);
            ocol2 <= cfg_stride2 ? ((c1 - 8'd2) >> 1) : (c1 - 8'd2);
            if (v1) begin
                w00 <= w01; w01 <= w02; w02 <= row_m2;
                w10 <= w11; w11 <= w12; w12 <= row_m1;
                w20 <= w21; w21 <= w22; w22 <= pix1;
            end
        end
    end

    // ---------------- S3..S5: pipelined depthwise MAC per lane ----------------
    // depthwise_mac3x3_pipe has 3 register stages; valid/last/coords
    // travel alongside through 2 matching registers + the output regs.
    genvar gl;
    generate
        for (gl = 0; gl < LANES; gl = gl + 1) begin : GEN_LANE
            depthwise_mac3x3_pipe u_dw (
                .clk(clk), .en(en),
                .d0(w00[gl*8+:8]), .d1(w01[gl*8+:8]), .d2(w02[gl*8+:8]),
                .d3(w10[gl*8+:8]), .d4(w11[gl*8+:8]), .d5(w12[gl*8+:8]),
                .d6(w20[gl*8+:8]), .d7(w21[gl*8+:8]), .d8(w22[gl*8+:8]),
                .w0(wd_flat[gl*72+0*8 +: 8]), .w1(wd_flat[gl*72+1*8 +: 8]), .w2(wd_flat[gl*72+2*8 +: 8]),
                .w3(wd_flat[gl*72+3*8 +: 8]), .w4(wd_flat[gl*72+4*8 +: 8]), .w5(wd_flat[gl*72+5*8 +: 8]),
                .w6(wd_flat[gl*72+6*8 +: 8]), .w7(wd_flat[gl*72+7*8 +: 8]), .w8(wd_flat[gl*72+8*8 +: 8]),
                .y(dw_flat[gl*20 +: 20])
            );
        end
    endgenerate

    reg       v3, v4, last3, last4;
    reg [7:0] orow3, ocol3, orow4, ocol4;
    always @(posedge clk) begin
        if (rst || start) begin
            v3 <= 1'b0; v4 <= 1'b0; last3 <= 1'b0; last4 <= 1'b0;
            out_valid <= 1'b0;
            out_last  <= 1'b0;
        end else if (en) begin
            v3 <= v2;  last3 <= v2 && last2;  orow3 <= orow2; ocol3 <= ocol2;
            v4 <= v3;  last4 <= last3;        orow4 <= orow3; ocol4 <= ocol3;
            out_valid <= v4;
            out_last  <= last4;
            out_row   <= orow4;
            out_col   <= ocol4;
        end
    end
endmodule
