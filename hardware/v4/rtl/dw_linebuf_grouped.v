// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- G-esteso: depthwise 3x3 over ALL channels of a layer, LANES at
// a time (fork of dw_linebuf_stream.v, which handles exactly LANES
// channels). Needed to feed the pointwise array: a 1x1 conv needs the
// whole Cin vector of a position, so the depthwise must produce every
// channel group of position p before moving to p+1.
//
// Input stream order: (row, col, group), group fastest. One beat =
// LANES channels (group g = channels g*LANES .. g*LANES+LANES-1) of one
// padded-frame pixel. cfg_ng = number of groups (Cin / LANES).
//
// Line buffer: ONE SDP BRAM, MAXW*MAXNG words of 2*LANES*8 bits, word
// (c*ng + g) = {row r-1, row r-2} for column c, group g. Addressed by a
// running beat counter that wraps at the end of every row, so no
// runtime multiply. Read at S1, rewritten at S2 with {pixel, row r-1}.
//
// Window columns: in raster-by-group order, column c-1 of group g is
// exactly ng beats older than column c of group g. A small history RAM
// (MAXNG words, distributed) indexed by g holds {col c-1, col c-2} per
// group: read asynchronously at S2 and rewritten at the same S2 edge
// with {col c, col c-1} -- works for any ng >= 1.
//
// Outputs: one beat per (output position, group) with that group's
// LANES depthwise results, out_g, and out_last on the very last beat
// of the frame. Same global stall as dw_linebuf_stream.v.
// ============================================================
module dw_linebuf_grouped #(
    parameter LANES = 16,
    parameter MAXW  = 16,
    parameter MAXNG = 4,
    // line-buffer words actually needed = max over layers of w*ng (the
    // address counter wraps every row); MobileFaceNet: 512
    parameter LBDEPTH = MAXW*MAXNG,
    // HALF = 1: LANES/2 MACs, each used twice per beat (lanes 0..LANES/2-1
    // then LANES/2..LANES-1): one input beat every 2 cycles, same results.
    // The 16 MACs were 12,000 LUTs of the generic board (2026-10-08).
    parameter HALF = 0,
    // DWW_INT = 1: the depthwise weights live HERE (DWDEPTH groups x 9
    // chunks of 128 bit, distributed RAM written through dww_we/waddr/
    // wdata, read at dww_base + group) instead of being looked up by the
    // caller through wd_g/wd_flat. Vivado moved the caller's weight RAM
    // into this module to merge it with wd_q and lost its write enable on
    // the way (every board build until 2026-10-08: the dw weights were
    // never written, netlist_sim/RESULTS.md).
    parameter DWW_INT = 0,
    parameter DWDEPTH = 64
)(
    input  wire clk,
    input  wire rst,
    input  wire start,

    input  wire [7:0] cfg_w,
    input  wire [7:0] cfg_h,
    input  wire [5:0] cfg_ng,          // groups per pixel, 1..MAXNG
    input  wire       cfg_stride2,

    input  wire                      in_valid,
    output wire                      in_ready,
    input  wire signed [8*LANES-1:0] in_pix,

    // depthwise weights for the CURRENT input group (in_g below): the
    // caller supplies weights of group `wd_g` = the group of the beat
    // now in the window stage (see wd_g) -- 9 per lane, kr*3+kc order.
    output wire [5:0]                 wd_g,
    input  wire signed [72*LANES-1:0] wd_flat,
    // DWW_INT write port (registered by the caller) and base group
    input  wire [8:0]                 dww_we,
    input  wire [7:0]                 dww_waddr,
    input  wire [127:0]               dww_wdata,
    input  wire [11:0]                dww_base,

    output reg                        out_valid,
    input  wire                       out_ready,
    output reg  [7:0]                 out_row,
    output reg  [7:0]                 out_col,
    output reg  [5:0]                 out_g,
    output reg                        out_last,
    output wire signed [20*LANES-1:0] dw_flat
);
    localparam PW = 8*LANES;
    localparam DEPTH = LBDEPTH;
    localparam AW = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
    localparam GW = (MAXNG <= 2) ? 1 : $clog2(MAXNG);

    // minus-one copies of the static configuration (registered)
    reg [5:0] cfg_ng_m1;
    reg [7:0] cfg_w_m1, cfg_h_m1;
    always @(posedge clk) begin
        cfg_ng_m1 <= cfg_ng - 6'd1;
        cfg_w_m1  <= cfg_w - 8'd1;
        cfg_h_m1  <= cfg_h - 8'd1;
    end

    // en: global stall (output register free or being read). en_p: the
    // beat pipeline (counters, line buffer, window, output) advances --
    // every en cycle, or every second en cycle with HALF (phase ph = 1).
    wire en = !out_valid || out_ready;
    reg  ph;
    wire en_p = en && (HALF == 0 || ph);
    always @(posedge clk)
        if (rst || start) ph <= 1'b1;
        else if (en && HALF != 0) ph <= ~ph;
    assign in_ready = en_p;
    wire acc_in = in_valid && en_p;

    // ---------------- counters (S1) ----------------
    reg [7:0]    r_cnt, c_cnt;
    reg [5:0]    g_cnt;
    reg [AW-1:0] lb_addr;
    wire g_end = (g_cnt == cfg_ng_m1);
    wire c_end = (c_cnt == cfg_w_m1);
    always @(posedge clk) begin
        if (rst || start) begin
            r_cnt <= 8'd0; c_cnt <= 8'd0; g_cnt <= 6'd0;
            lb_addr <= {AW{1'b0}};
        end else if (acc_in) begin
            if (g_end) begin
                g_cnt <= 6'd0;
                if (c_end) begin
                    c_cnt <= 8'd0;
                    r_cnt <= r_cnt + 8'd1;
                end else begin
                    c_cnt <= c_cnt + 8'd1;
                end
            end else begin
                g_cnt <= g_cnt + 6'd1;
            end
            lb_addr <= (g_end && c_end) ? {AW{1'b0}} : lb_addr + 1'b1;
        end
    end

    // ---------------- line buffer RAM (SDP) ----------------
    (* ram_style = "block" *) reg [2*PW-1:0] lb [0:DEPTH-1];
    reg [2*PW-1:0] lb_dout;
    always @(posedge clk)
        if (en_p) lb_dout <= lb[lb_addr];

    // ---------------- S1 -> S2 ----------------
    reg          v1;
    reg [7:0]    r1, c1;
    reg [5:0]    g1;
    reg [AW-1:0] a1;
    reg [PW-1:0] pix1;
    always @(posedge clk) begin
        if (rst || start) begin
            v1 <= 1'b0;
        end else if (en_p) begin
            v1 <= in_valid;
            r1 <= r_cnt; c1 <= c_cnt; g1 <= g_cnt; a1 <= lb_addr;
            pix1 <= in_pix;
        end
    end

    wire [PW-1:0] row_m1 = lb_dout[2*PW-1:PW];
    wire [PW-1:0] row_m2 = lb_dout[PW-1:0];

    always @(posedge clk)
        if (!rst && en_p && v1) lb[a1] <= {pix1, row_m1};

    // ---------------- S2: history RAM + window ----------------
    // hist word = {col c-1 (3 rows), col c-2 (3 rows)}, each col =
    // {row r, row r-1, row r-2} = 3*PW bits
    (* ram_style = "distributed" *) reg [6*PW-1:0] hist [0:MAXNG-1];
    wire [6*PW-1:0] hist_rd = hist[g1[GW-1:0]];
    wire [3*PW-1:0] col_c   = {pix1, row_m1, row_m2};
    wire [3*PW-1:0] col_m1  = hist_rd[6*PW-1:3*PW];
    wire [3*PW-1:0] col_m2  = hist_rd[3*PW-1:0];

    always @(posedge clk)
        if (!rst && en_p && v1) hist[g1[GW-1:0]] <= {col_c, col_m1};

    // wXY: row X (0 = top, r-2), col Y (0 = left, c-2)
    reg [PW-1:0] w00, w01, w02, w10, w11, w12, w20, w21, w22;
    reg          v2, last2;
    reg [7:0]    orow2, ocol2;
    reg [5:0]    g2;

    wire r_ok = (r1 >= 8'd2) && (!cfg_stride2 || !r1[0]);
    wire c_ok = (c1 >= 8'd2) && (!cfg_stride2 || !c1[0]);
    wire [7:0] last_r = cfg_stride2 ? ((cfg_h_m1) & 8'hFE) : (cfg_h_m1);
    wire [7:0] last_c = cfg_stride2 ? ((cfg_w_m1) & 8'hFE) : (cfg_w_m1);

    always @(posedge clk) begin
        if (rst || start) begin
            v2 <= 1'b0; last2 <= 1'b0;
        end else if (en_p) begin
            v2    <= v1 && r_ok && c_ok;
            last2 <= v1 && (r1 == last_r) && (c1 == last_c) && (g1 == cfg_ng_m1);
            orow2 <= cfg_stride2 ? ((r1 - 8'd2) >> 1) : (r1 - 8'd2);
            ocol2 <= cfg_stride2 ? ((c1 - 8'd2) >> 1) : (c1 - 8'd2);
            g2    <= g1;
            if (v1) begin
                w00 <= col_m2[PW-1:0];      w01 <= col_m1[PW-1:0];      w02 <= row_m2;
                w10 <= col_m2[2*PW-1:PW];   w11 <= col_m1[2*PW-1:PW];   w12 <= row_m1;
                w20 <= col_m2[3*PW-1:2*PW]; w21 <= col_m1[3*PW-1:2*PW]; w22 <= pix1;
            end
        end
    end

    // weights: looked up for the group in S1 (wd_g = g1) and registered
    // at the same en edge that loads the window, so the lookup has a
    // full cycle (the unregistered g2 -> lookup -> multiply path measured
    // -0.43 ns at 5 ns in the core synthesis)
    assign wd_g = g1;
    wire signed [72*LANES-1:0] wd_src;
    genvar gw;
    generate
        if (DWW_INT != 0) begin : G_DWW
            wire [11:0] dww_a = dww_base + {6'd0, g1};
            for (gw = 0; gw < 9; gw = gw + 1) begin : GEN_DWW
                (* ram_style = "distributed" *) reg [127:0] mem [0:DWDEPTH-1];
                always @(posedge clk)
                    if (dww_we[gw]) mem[dww_waddr[$clog2(DWDEPTH)-1:0]] <= dww_wdata;
                assign wd_src[gw*128 +: 128] = mem[dww_a];
            end
        end else begin : G_DWX
            assign wd_src = wd_flat;
        end
    endgenerate
    reg signed [72*LANES-1:0] wd_q;
    always @(posedge clk) if (en_p) wd_q <= wd_src;

    // ---------------- S3..S5: pipelined depthwise MAC ----------------
    // NM MACs; with HALF the window and weights of the beat (held two
    // cycles) go through them, through an operand register, as lanes
    // 0..NM-1 then NM..LANES-1 (G_SEL / G_ASM).
    localparam NM = (HALF != 0) ? LANES/2 : LANES;
    wire [8*NM-1:0]  m00, m01, m02, m10, m11, m12, m20, m21, m22;
    wire [72*NM-1:0] mw;
    wire signed [20*NM-1:0] mac_y;
    generate
        if (HALF != 0) begin : G_SEL
            // the half for the MACs, registered (the mux in front of the
            // 8x8 multipliers was the worst path of the first fixed board
            // P&R, -0.64 ns at 5 ns): low half in the beat's first cycle
            // (ph = 0), high half in the second; alignment in G_ASM
            wire hi = ph;
            reg [8*NM-1:0]  r00, r01, r02, r10, r11, r12, r20, r21, r22;
            reg [72*NM-1:0] rw;
            always @(posedge clk) if (en) begin
                r00 <= hi ? w00[PW-1:PW/2] : w00[PW/2-1:0];
                r01 <= hi ? w01[PW-1:PW/2] : w01[PW/2-1:0];
                r02 <= hi ? w02[PW-1:PW/2] : w02[PW/2-1:0];
                r10 <= hi ? w10[PW-1:PW/2] : w10[PW/2-1:0];
                r11 <= hi ? w11[PW-1:PW/2] : w11[PW/2-1:0];
                r12 <= hi ? w12[PW-1:PW/2] : w12[PW/2-1:0];
                r20 <= hi ? w20[PW-1:PW/2] : w20[PW/2-1:0];
                r21 <= hi ? w21[PW-1:PW/2] : w21[PW/2-1:0];
                r22 <= hi ? w22[PW-1:PW/2] : w22[PW/2-1:0];
                rw  <= hi ? wd_q[72*LANES-1:72*NM] : wd_q[72*NM-1:0];
            end
            assign m00 = r00; assign m01 = r01; assign m02 = r02;
            assign m10 = r10; assign m11 = r11; assign m12 = r12;
            assign m20 = r20; assign m21 = r21; assign m22 = r22;
            assign mw  = rw;
        end else begin : G_ALL
            assign m00 = w00; assign m01 = w01; assign m02 = w02;
            assign m10 = w10; assign m11 = w11; assign m12 = w12;
            assign m20 = w20; assign m21 = w21; assign m22 = w22;
            assign mw  = wd_q;
        end
    endgenerate
    genvar gl;
    generate
        for (gl = 0; gl < NM; gl = gl + 1) begin : GEN_LANE
            depthwise_mac3x3_pipe u_dw (
                .clk(clk), .en(en),
                .d0(m00[gl*8+:8]), .d1(m01[gl*8+:8]), .d2(m02[gl*8+:8]),
                .d3(m10[gl*8+:8]), .d4(m11[gl*8+:8]), .d5(m12[gl*8+:8]),
                .d6(m20[gl*8+:8]), .d7(m21[gl*8+:8]), .d8(m22[gl*8+:8]),
                .w0(mw[gl*72+0*8 +: 8]), .w1(mw[gl*72+1*8 +: 8]), .w2(mw[gl*72+2*8 +: 8]),
                .w3(mw[gl*72+3*8 +: 8]), .w4(mw[gl*72+4*8 +: 8]), .w5(mw[gl*72+5*8 +: 8]),
                .w6(mw[gl*72+6*8 +: 8]), .w7(mw[gl*72+7*8 +: 8]), .w8(mw[gl*72+8*8 +: 8]),
                .y(mac_y[gl*20 +: 20])
            );
        end
        if (HALF != 0) begin : G_ASM
            // operand register + 3 MAC stages: the low half of the beat
            // loaded at en_p edge E is in mac_y after E+4, the high half
            // after E+5; y_lo takes the low half at E+5 (ph = 0), the
            // output register takes {high, low} at E+6 (en_p), the edge
            // that loads out_valid for this beat.
            reg signed [20*NM-1:0] y_lo;
            reg signed [20*LANES-1:0] y_out;
            always @(posedge clk) begin
                if (en && !ph) y_lo <= mac_y;          // low half
                if (en_p)      y_out <= {mac_y, y_lo};  // high half + low half
            end
            assign dw_flat = y_out;
        end else begin : G_DIRECT
            assign dw_flat = mac_y;
        end
    endgenerate

    reg       v3, v4, last3, last4;
    reg [7:0] orow3, ocol3, orow4, ocol4;
    reg [5:0] g3, g4;
    always @(posedge clk) begin
        if (rst || start) begin
            v3 <= 1'b0; v4 <= 1'b0; last3 <= 1'b0; last4 <= 1'b0;
            out_valid <= 1'b0; out_last <= 1'b0;
        end else if (!en_p) begin
            // HALF, first cycle of a beat: a beat read now is gone
            if (out_ready) out_valid <= 1'b0;
        end else begin
            v3 <= v2; last3 <= v2 && last2; orow3 <= orow2; ocol3 <= ocol2; g3 <= g2;
            v4 <= v3; last4 <= last3;       orow4 <= orow3; ocol4 <= ocol3; g4 <= g3;
            out_valid <= v4;
            out_last  <= last4;
            out_row   <= orow4;
            out_col   <= ocol4;
            out_g     <= g4;
        end
    end
endmodule
