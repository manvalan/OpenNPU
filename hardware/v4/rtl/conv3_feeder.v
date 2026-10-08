// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- window feeder: dense 3x3 convolution and pooling anywhere in
// the network.
//
// Convolution (cfg_pool = 0): a 3x3 convolution (pad 1, stride 1 or 2)
// on a feature map with ng 16-channel groups is run by dwpw_engine.v as
// a pointwise-only pass with 9*ng input groups: for every output
// position (oi, oj), in raster order, this block streams the 9
// neighbours of the window, each as its ng words, in the order
// (kr, kc, g):
//
//   beat (kr, kc, g) = map(s*oi-pad+kr, s*oj-pad+kc, g), zero outside
//
// so the pointwise weights of the pass are W'[co][(kr*3+kc)*16*ng + ci]
// (v4_compile.py). The whole Cin x 9 dot product accumulates in the
// array's 32-bit accumulators, no partial sums leave the chip.
//
// Pooling (cfg_pool = 1, for pool_unit.v): same windows, order
// (g, kr, kc) -- the K*K taps of one group are consecutive, so the
// pooling unit reduces them in one register. out_pad marks the taps
// outside the map (a max pool ignores them).
//
// Window: K = 3, 2 (cfg_k2) or 1 (cfg_k1), padding 1 (cfg_pad) or 0;
// output size given by the descriptor (floor((in+2pad-K)/s)+1).
// cfg_up2 (with K = 1, stride 1): nearest-neighbour 2x upsampling, output
// (oi, oj) reads input (oi/2, oj/2).
// cfg_nge: groups emitted per tap (pooling order); groups >= cfg_ng (the
// map's own groups) are zero beats -- a copy into a wider tensor (concat)
// fills its extra groups with zeros. Convolution: cfg_nge = cfg_ng.
//
// Memory layout (fmap_feeder.v convention): word(r, c, g) =
// base + (r*w + c)*ng + g. Addresses are incremental, no multiplier:
// the next window row starts cfg_rs = w*ng words further (given by the
// descriptor); the next output position s*ng words further; the next
// output row s*cfg_rs. Out-of-map taps are zero beats (no read); their
// address is still stepped so the arithmetic stays the same (modulo
// 2^AW, never read).
//
// Memory read port and output FIFO: same as fmap_feeder.v (latency 4,
// credit-based, one beat per cycle).
// ============================================================
module conv3_feeder #(
    parameter AW = 15,
    parameter DW = 128
)(
    input  wire clk,
    input  wire rst,
    input  wire start,
    output reg  busy,

    // stable >= 2 cycles before start (v4_core: S_LOAD, S_PREP, S_GO)
    input  wire [AW-1:0] cfg_base,     // word address of map(0, 0, 0)
    input  wire [7:0]    cfg_iw,       // input map width
    input  wire [7:0]    cfg_ih,       // input map height
    input  wire [5:0]    cfg_ng,       // input groups (16 channels each)
    input  wire [AW-1:0] cfg_rs,       // row stride = iw*ng words
    input  wire          cfg_s2,
    input  wire [7:0]    cfg_ow,       // output size = ceil(in / stride)
    input  wire [7:0]    cfg_oh,
    input  wire          cfg_pool,     // order (g, kr, kc) for pool_unit.v
    input  wire          cfg_k2,       // 2x2 window (else 3x3)
    input  wire          cfg_k1,       // 1x1 window (copy / upsampling)
    input  wire          cfg_up2,      // 2x nearest upsampling (K = 1, s = 1)
    input  wire [5:0]    cfg_nge,      // groups emitted per position (>= cfg_ng)
    input  wire          cfg_pad,      // 1-pixel zero padding (else none)

    output reg           rd_en,
    output reg  [AW-1:0] rd_addr,
    input  wire [DW-1:0] rd_data,

    output wire          out_valid,
    input  wire          out_ready,
    output wire [DW-1:0] out_data,
    output wire          out_pad       // this beat is outside the map
);
    // ---------------- derived configuration (free-running registers) ----------------
    reg [AW-1:0] a0;          // address of map(-pad, -pad, 0)
    reg [AW-1:0] sng, srs;    // s*ng, s*rs
    reg signed [9:0] p0;      // -pad
    always @(posedge clk) begin
        a0  <= cfg_pad ? cfg_base - cfg_rs - {{(AW-6){1'b0}}, cfg_ng} : cfg_base;
        sng <= cfg_s2 ? {{(AW-7){1'b0}}, cfg_ng, 1'b0} : {{(AW-6){1'b0}}, cfg_ng};
        srs <= cfg_s2 ? {cfg_rs[AW-2:0], 1'b0} : cfg_rs;
        p0  <= cfg_pad ? -10'sd1 : 10'sd0;    // used at start: free-running like a0
    end

    // configuration latched at start
    reg [7:0]    ow_m1, oh_m1;
    reg [5:0]    ng_m1;       // emitted groups - 1
    reg [5:0]    ngs;         // groups of the map
    reg signed [9:0] ih_s, iw_s;
    reg [AW-1:0] rs, sng_l, srs_l, ng_a;
    reg          s2, pool, up2;
    reg [1:0]    km1;         // K - 1
    always @(posedge clk)
        if (start) begin
            ow_m1 <= cfg_ow - 8'd1; oh_m1 <= cfg_oh - 8'd1; ng_m1 <= cfg_nge - 6'd1; ngs <= cfg_ng;
            up2 <= cfg_up2;
            ih_s <= {2'b00, cfg_ih}; iw_s <= {2'b00, cfg_iw};
            rs <= cfg_rs; sng_l <= sng; srs_l <= srs; s2 <= cfg_s2;
            ng_a <= {{(AW-6){1'b0}}, cfg_ng};
            pool <= cfg_pool; km1 <= cfg_k1 ? 2'd0 : cfg_k2 ? 2'd1 : 2'd2;
        end

    // ---------------- beat generator ----------------
    reg [7:0]  oi, oj;
    reg [1:0]  kr, kc;
    reg [5:0]  g;
    reg signed [9:0] r0, c0;   // window top-left (map coordinates)
    reg signed [9:0] rr, cc;   // current tap
    reg [AW-1:0] a;            // current tap address
    reg [AW-1:0] rowp;         // address of (rr, c0, 0)
    reg [AW-1:0] tl;           // address of (r0, c0, 0)
    reg [AW-1:0] tlg;          // address of (r0, c0, g)   (pooling order)
    reg [AW-1:0] tlrow;        // address of (r0, -pad, 0)
    reg          gen;

    localparam DEPTH = 8;
    reg [DW-1:0] fifo [0:DEPTH-1];
    reg          fifo_z [0:DEPTH-1];
    reg [3:0]    f_cnt;
    reg [2:0]    f_wr, f_rd;
    reg          p1_v, p1_z, p2_v, p2_z;
    reg          p3_v, p3_z, p4_v, p4_z;
    reg          p5_v;
    (* max_fanout = 16 *) reg p5_z;

    // room registered, conservatively: the count can only drop between
    // cycles (pops), and at most one beat is issued per cycle (count ->
    // room -> issue -> tap counters was 9 levels, -0.77 ns, in the first
    // generic-board P&R)
    reg  room;
    wire issue = gen && room;
    always @(posedge clk)
        room <= (rst || start) ? 1'b1
              : ((f_cnt + p1_v + p2_v + p3_v + p4_v + p5_v + issue) < DEPTH);
    wire is_pad = rr[9] || (rr >= ih_s) || cc[9] || (cc >= iw_s) || (g >= ngs);
    wire g_last  = (g == ng_m1);
    wire kc_last = (kc == km1);
    wire kr_last = (kr == km1);
    // convolution: g innermost, then kc, kr ; pooling: kc, kr, g
    wire e1 = pool ? kc_last : g_last;
    wire e2 = e1 && (pool ? kr_last : kc_last);
    wire pos_end = e2 && (pool ? g_last : kr_last);
    wire row_end = pos_end && (oj == ow_m1);
    wire last_beat = row_end && (oi == oh_m1);
    wire signed [9:0] sstep = s2 ? 10'sd2 : 10'sd1;

    always @(posedge clk) begin
        if (rst) begin
            gen <= 1'b0; busy <= 1'b0; rd_en <= 1'b0;
        end else if (start) begin
            gen <= 1'b1; busy <= 1'b1; rd_en <= 1'b0;
            oi <= 8'd0; oj <= 8'd0; kr <= 2'd0; kc <= 2'd0; g <= 6'd0;
            r0 <= p0; c0 <= p0; rr <= p0; cc <= p0;
            a <= a0; rowp <= a0; tl <= a0; tlg <= a0; tlrow <= a0;
        end else begin
            rd_en <= 1'b0;
            if (issue) begin
                rd_en   <= !is_pad;
                rd_addr <= a;
                if (last_beat) gen <= 1'b0;
                if (!e1) begin
                    if (pool) begin                         // next tap in the window row
                        kc <= kc + 2'd1; cc <= cc + 10'sd1; a <= a + ng_a;
                    end else begin                          // next group of the tap
                        g <= g + 6'd1; a <= a + 1'b1;
                    end
                end else if (!e2) begin
                    if (pool) begin                         // next window row
                        kc <= 2'd0; kr <= kr + 2'd1; cc <= c0; rr <= rr + 10'sd1;
                        a <= rowp + rs; rowp <= rowp + rs;
                    end else begin                          // next tap in the window row
                        g <= 6'd0; kc <= kc + 2'd1; cc <= cc + 10'sd1; a <= a + 1'b1;
                    end
                end else if (!pos_end) begin
                    kc <= 2'd0; cc <= c0;
                    if (pool) begin                         // next group, window from the top
                        kr <= 2'd0; rr <= r0; g <= g + 6'd1;
                        a <= tlg + 1'b1; rowp <= tlg + 1'b1; tlg <= tlg + 1'b1;
                    end else begin                          // next window row
                        g <= 6'd0; kr <= kr + 2'd1; rr <= rr + 10'sd1;
                        a <= rowp + rs; rowp <= rowp + rs;
                    end
                end else if (!row_end) begin                // next output position
                    g <= 6'd0; kc <= 2'd0; kr <= 2'd0; oj <= oj + 8'd1; rr <= r0;
                    if (up2 && !oj[0]) begin                // upsampling: same input column again
                        cc <= c0; a <= tl; rowp <= tl; tlg <= tl;
                    end else begin
                        c0 <= c0 + sstep; cc <= c0 + sstep;
                        a <= tl + sng_l; rowp <= tl + sng_l; tl <= tl + sng_l; tlg <= tl + sng_l;
                    end
                end else begin                              // next output row
                    g <= 6'd0; kc <= 2'd0; kr <= 2'd0; oj <= 8'd0; oi <= oi + 8'd1;
                    c0 <= p0; cc <= p0;
                    if (up2 && !oi[0]) begin                // upsampling: same input row again
                        rr <= r0; a <= tlrow; rowp <= tlrow; tl <= tlrow; tlg <= tlrow;
                    end else begin
                        r0 <= r0 + sstep; rr <= r0 + sstep;
                        a <= tlrow + srs_l; rowp <= tlrow + srs_l; tl <= tlrow + srs_l; tlg <= tlrow + srs_l;
                        tlrow <= tlrow + srs_l;
                    end
                end
            end
            if (!gen && f_cnt == 4'd0 && !p1_v && !p2_v && !p3_v && !p4_v && !p5_v) busy <= 1'b0;
        end
    end

    // latency pipe (fmap_feeder.v): issue -> rd_en -> memory (4) -> FIFO
    always @(posedge clk) begin
        if (rst || start) begin
            p1_v <= 1'b0; p2_v <= 1'b0; p3_v <= 1'b0; p4_v <= 1'b0; p5_v <= 1'b0;
        end else begin
            p1_v <= issue; p1_z <= is_pad;
            p2_v <= p1_v;  p2_z <= p1_z;
            p3_v <= p2_v;  p3_z <= p2_z;
            p4_v <= p3_v;  p4_z <= p3_z;
            p5_v <= p4_v;  p5_z <= p4_z;
        end
    end

    wire pop = out_valid && out_ready;
    always @(posedge clk) begin
        if (rst || start) begin
            f_cnt <= 4'd0; f_wr <= 3'd0; f_rd <= 3'd0;
        end else begin
            if (p5_v) begin
                fifo[f_wr] <= p5_z ? {DW{1'b0}} : rd_data;
                fifo_z[f_wr] <= p5_z;
                f_wr <= f_wr + 3'd1;
            end
            if (pop) f_rd <= f_rd + 3'd1;
            f_cnt <= f_cnt + p5_v - pop;
        end
    end
    assign out_valid = (f_cnt != 4'd0);
    assign out_data  = fifo[f_rd];
    assign out_pad   = fifo_z[f_rd];
endmodule
