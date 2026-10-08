// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- G-esteso, step 2c: the fused depthwise -> pointwise engine.
//
//   pixel beats (row,col,group) --> dw_linebuf_grouped (3x3 depthwise,
//   P channels per beat) --> requant_act (INT8 + act) --> pair vector
//   buffer --> sequencer --> pw_array_packed (P x P_CO, 2 positions per
//   DSP) --> requant_act --> output tiles
//
// No memory round trip between depthwise and pointwise: the depthwise
// output of a position only ever lives in the pair vector buffer (2
// slots, double-buffered) until the pointwise has consumed it.
//
// Pair vector buffer: positions are paired in raster order (0,1),
// (2,3), ...; a slot holds the whole Cin vector (ng words of P INT8) of
// position A and of position B, in two separate RAMs so the sequencer
// reads A[g] and B[g] in the same cycle. An odd last position runs with
// B = don't care (o_b_valid = 0).
//
// Sequencer: for a full slot, for cot in 0..nco-1, for g in 0..ng-1,
// one array beat (first = g==0, last = g==ng-1) -- ng*nco cycles per
// pair, back to back across slots, no drain between output tiles.
//
// External memories (kept outside so the memory architecture can be
// chosen separately, step 3):
//   * pw weights: w_addr = w_base + cot*ng + g, SYNCHRONOUS read, w_data valid the
//     cycle after w_addr (P*P_CO*8 bits, word layout of pw_array_packed)
//   * dw weights / dw requant params / pw requant params: combinational
//     lookups keyed by wd_g / rq_g / pwq_cot (small register files).
// MAXNG (depthwise groups) and MAXNGV (pointwise input groups held by the
// pair vector buffer, >= MAXNG) must be powers of two (vector RAM address
// = {slot, g}). A pointwise-only pass takes up to MAXNGV*P inputs per
// output channel (Cin), accumulated in the array's 32-bit accumulators.
// ============================================================
module dwpw_engine #(
    parameter P          = 16,    // channels per beat = P_CI of the array
    parameter P_CO       = 16,
    parameter N_DSP_COLS = 14,
    parameter MAXW       = 16,
    parameter MAXNG      = 4,
    parameter MAXNGV     = MAXNG,
    parameter MAXNCO     = 4,
    parameter LBDEPTH    = MAXW*MAXNG,
    // cycles from w_addr to w_data: 1 = plain synchronous RAM, 2 = RAM +
    // one extra register (v4_core: the weight BRAMs span the die and fed
    // the 224 DSPs directly at -0.91 ns in the second in-context P&R)
    parameter W_LAT      = 1,
    // DW_HALF = 1: depthwise with P/2 MACs used twice (one input beat
    // every 2 cycles), dw_linebuf_grouped HALF
    parameter DW_HALF    = 0,
    // DWW_INT = 1: dw weights held by dw_linebuf_grouped (written through
    // dww_*), wd_g/wd_flat unused
    parameter DWW_INT    = 0,
    parameter DWDEPTH    = 64
)(
    input  wire clk,
    input  wire rst,
    input  wire start,
    output reg  done,

    // layer configuration, stable from start to done
    input  wire [7:0] cfg_w_i,          // padded input width
    input  wire [7:0] cfg_h_i,          // padded input height
    input  wire [8:0] cfg_ng_i,         // Cin / P (depthwise: <= MAXNG, pointwise: <= MAXNGV)
    input  wire [5:0] cfg_nco_i,        // Cout / P_CO
    input  wire       cfg_stride2_i,
    // pointwise only: input beats (row,col,group) of a cfg_w x cfg_h map
    // (NOT padded) go straight into the pair vector buffer -- the 1x1
    // expand layers, and conv1 when the feeder streams im2col vectors
    input  wire       cfg_pw_only_i,
    input  wire [4:0] dw_shift_i,
    input  wire [2:0] dw_ash_i,
    input  wire [1:0] dw_act_i,
    input  wire [4:0] pw_shift_i,
    input  wire [2:0] pw_ash_i,
    input  wire [1:0] pw_act_i,

    // input pixel beats
    input  wire                  in_valid,
    output wire                  in_ready,
    input  wire signed [8*P-1:0] in_pix,

    // depthwise weights / requant params (combinational lookups)
    output wire [5:0]              wd_g,
    input  wire signed [72*P-1:0]  wd_flat,
    input  wire [8:0]              dww_we,
    input  wire [7:0]              dww_waddr,
    input  wire [127:0]            dww_wdata,
    input  wire [11:0]             dww_base,
    output wire [5:0]              rq_g,      // lookup: registered by the engine one cycle later
    input  wire signed [32*P-1:0]  dw_bias,
    input  wire signed [8*P-1:0]   dw_alpha,

    // pointwise weights (synchronous read, 1 cycle)
    input  wire [15:0]                  w_base_i,     // first weight word of this layer
    output reg  [15:0]                  w_addr,
    input  wire signed [8*P*P_CO-1:0]   w_data,

    // pointwise requant params (combinational lookup by output tile)
    output wire [5:0]                pwq_cot,
    input  wire signed [32*P_CO-1:0] pw_bias,
    input  wire signed [8*P_CO-1:0]  pw_alpha,

    // output tiles: P_CO channels (tile o_cot) of positions A and B
    output wire                     o_valid,
    output wire [15:0]              o_pair,
    output wire [5:0]               o_cot,
    output wire                     o_b_valid,
    output wire signed [8*P_CO-1:0] o_ya,
    output wire signed [8*P_CO-1:0] o_yb,

    // shared requant: while x_sel (a GDConv pass, the engine idle), lanes
    // 0..P_CO-1 of the pointwise requant take x_acc instead of res_a
    // (same BIAS_LAT 1 contract, same pw_bias/pw_alpha/pw_* settings);
    // the result comes out on o_ya, latency 8
    input  wire                     x_sel,
    input  wire signed [32*P_CO-1:0] x_acc
);
    // static configuration registered locally (placed next to its users): the first in-context P&R had descriptor -> engine paths at -1.33 ns from routing alone; callers hold cfg_* >= 1 cycle before start
    reg [7:0] cfg_w;
    reg [7:0] cfg_h;
    reg [8:0] cfg_ng;
    reg [5:0] cfg_nco;
    reg  cfg_stride2;
    reg  cfg_pw_only;
    reg [4:0] dw_shift;
    reg [2:0] dw_ash;
    reg [1:0] dw_act;
    reg [4:0] pw_shift;
    reg [2:0] pw_ash;
    reg [1:0] pw_act;
    reg [15:0] w_base;
    reg [8:0] cfg_ng_m1;
    reg [5:0] cfg_nco_m1;
    reg [7:0] cfg_w_m1, cfg_h_m1;
    always @(posedge clk) begin
        cfg_w <= cfg_w_i;
        cfg_h <= cfg_h_i;
        cfg_ng <= cfg_ng_i;
        cfg_nco <= cfg_nco_i;
        cfg_stride2 <= cfg_stride2_i;
        cfg_pw_only <= cfg_pw_only_i;
        dw_shift <= dw_shift_i;
        dw_ash <= dw_ash_i;
        dw_act <= dw_act_i;
        pw_shift <= pw_shift_i;
        pw_ash <= pw_ash_i;
        pw_act <= pw_act_i;
        w_base <= w_base_i;
        cfg_ng_m1  <= cfg_ng_i - 9'd1;
        cfg_nco_m1 <= cfg_nco_i - 6'd1;
        cfg_w_m1   <= cfg_w_i - 8'd1;
        cfg_h_m1   <= cfg_h_i - 8'd1;
    end
    // (minus-one copies: fifth P&R had cfg -> subtract -> compare -> counters at -0.38 ns)
    localparam PW  = 8*P;
    localparam VAW = $clog2(2*MAXNGV);         // vector RAM address: {slot, g}

    // =========================================================
    // depthwise
    // =========================================================
    wire                 dw_valid, dw_last;
    wire                 dw_ready;
    wire [7:0]           dw_row, dw_col;
    wire [5:0]           dw_g;
    wire signed [20*P-1:0] dw_y;

    wire dw_in_ready;
    wire vb_can_write;
    assign in_ready = cfg_pw_only ? vb_can_write : dw_in_ready;

    dw_linebuf_grouped #(.LANES(P), .MAXW(MAXW), .MAXNG(MAXNG), .LBDEPTH(LBDEPTH), .HALF(DW_HALF),
                         .DWW_INT(DWW_INT), .DWDEPTH(DWDEPTH)) u_dw (
        .clk(clk), .rst(rst), .start(start),
        .cfg_w(cfg_w), .cfg_h(cfg_h), .cfg_ng(cfg_ng[5:0]), .cfg_stride2(cfg_stride2),
        .in_valid(in_valid && !cfg_pw_only), .in_ready(dw_in_ready), .in_pix(in_pix),
        .wd_g(wd_g), .wd_flat(wd_flat),
        .dww_we(dww_we), .dww_waddr(dww_waddr), .dww_wdata(dww_wdata), .dww_base(dww_base),
        .out_valid(dw_valid), .out_ready(dw_ready),
        .out_row(dw_row), .out_col(dw_col), .out_g(dw_g), .out_last(dw_last), .dw_flat(dw_y)
    );

    // =========================================================
    // depthwise -> requant -> vector buffer, fully registered flow
    // control (first in-context P&R: the old combinational stall
    // rq_en = !rq_v[last] | vb_can_write fanned out to 2,164 loads and
    // chained through 5 LUT levels into the feeder FIFO, -1.45 ns at 5 ns)
    //
    //   dw out --> S1 (4 entries) --pop--> P0 --> P1 (+ params lookup,
    //   registered) --> requant_act (5 stages, never stalls) --> S2
    //   (16 entries) --> vector buffer
    //
    // dw_ready comes from S1's count register; a pop from S1 is issued
    // only when S2 is guaranteed room for everything in flight.
    // =========================================================
    localparam RQL = 8;              // requant_act latency
    localparam S1D = 4, S2D = 16;
    localparam DWB = 20*P;

    // distributed: the first synthesis with the depthwise path present
    // mapped this 4-word FIFO to 4 RAMB36 + 1 RAMB18 (2026-10-08)
    (* ram_style = "distributed" *) reg [DWB-1:0] s1_y [0:S1D-1];
    (* ram_style = "distributed" *) reg [5:0]     s1_g [0:S1D-1];
    (* ram_style = "distributed" *) reg           s1_l [0:S1D-1];
    reg [2:0]     s1_cnt;
    reg [1:0]     s1_wr, s1_rd;
    assign dw_ready = (s1_cnt < 3'd3);
    wire s1_push = dw_valid && dw_ready;

    reg [PW-1:0]  s2_y   [0:S2D-1];
    reg           s2_l   [0:S2D-1];
    reg [4:0]     s2_cnt;
    reg [3:0]     s2_wr, s2_rd;
    reg [3:0]     infl;              // beats between S1 pop and S2 push
    wire s1_pop = (s1_cnt != 3'd0) && ({1'b0, s2_cnt} + {2'b0, infl} < S2D - 1);

    // P0: popped beat ; P1: params registered next to it
    reg           p0_v, p0_l, p1_v, p1_l;
    reg [DWB-1:0] p0_y, p1_y;
    reg [5:0]     p0_g;
    reg signed [32*P-1:0] p1_bias;
    reg signed [8*P-1:0]  p1_alpha;
    assign rq_g = p0_g;

    reg  [RQL-1:0] rq_v;
    reg  [RQL-1:0] rq_last;
    wire rq_out_v = rq_v[RQL-1];
    wire s2_pop;

    always @(posedge clk) begin
        if (s1_push) begin
            s1_y[s1_wr] <= dw_y; s1_g[s1_wr] <= dw_g; s1_l[s1_wr] <= dw_last;
        end
        p0_y <= s1_y[s1_rd]; p0_g <= s1_g[s1_rd]; p0_l <= s1_l[s1_rd];
        p1_y <= p0_y; p1_l <= p0_l;
        p1_bias <= dw_bias; p1_alpha <= dw_alpha;
        if (rst || start) begin
            s1_cnt <= 3'd0; s1_wr <= 2'd0; s1_rd <= 2'd0;
            p0_v <= 1'b0; p1_v <= 1'b0;
            rq_v <= {RQL{1'b0}}; rq_last <= {RQL{1'b0}};
            infl <= 4'd0;
        end else begin
            if (s1_push) s1_wr <= s1_wr + 2'd1;
            if (s1_pop)  s1_rd <= s1_rd + 2'd1;
            s1_cnt <= s1_cnt + s1_push - s1_pop;
            p0_v <= s1_pop;
            p1_v <= p0_v;
            rq_v    <= {rq_v[RQL-2:0], p1_v};
            rq_last <= {rq_last[RQL-2:0], p1_v & p1_l};
            infl <= infl + s1_pop - rq_out_v;
        end
    end

    wire signed [PW-1:0] rq_y;
    requant_act #(.N(P), .IN_W(20)) u_rq_dw (
        .clk(clk), .en(1'b1),
        .acc(p1_y), .bias(p1_bias), .alpha(p1_alpha),
        .shift(dw_shift), .ash(dw_ash), .act(dw_act),
        .y(rq_y)
    );

    always @(posedge clk) begin
        if (rq_out_v) begin s2_y[s2_wr] <= rq_y; s2_l[s2_wr] <= rq_last[RQL-1]; end
        if (rst || start) begin
            s2_cnt <= 5'd0; s2_wr <= 4'd0; s2_rd <= 4'd0;
        end else begin
            if (rq_out_v) s2_wr <= s2_wr + 4'd1;
            if (s2_pop)   s2_rd <= s2_rd + 4'd1;
            s2_cnt <= s2_cnt + rq_out_v - s2_pop;
        end
    end
    wire          s2_v    = (s2_cnt != 5'd0);
    wire [PW-1:0] s2_head = s2_y[s2_rd];
    wire          s2_hl   = s2_l[s2_rd];

    // =========================================================
    // pair vector buffer (2 slots x {A,B} x MAXNGV words)
    // =========================================================
    reg [PW-1:0] vram_a [0:2*MAXNGV-1];
    reg [PW-1:0] vram_b [0:2*MAXNGV-1];
    // zero at configuration: the B half of an odd last position (and of
    // every 1x1-map pass) is never written. The packed DSP product's A
    // part does not depend on B, but in simulation an X in B makes the
    // whole packed product X (found with a 4096-input pass: words 32..255
    // had never been written by an earlier pass).
    integer vi;
    initial for (vi = 0; vi < 2*MAXNGV; vi = vi + 1) begin vram_a[vi] = 0; vram_b[vi] = 0; end

    reg [1:0] slot_full;           // per slot
    reg [1:0] slot_bvalid;         // per slot: B position present
    reg       ws;                  // slot being written
    reg       wpos;                // 0: writing A, 1: writing B
    reg [8:0] wg;                  // group being written
    reg       frame_in_done;       // last depthwise beat written

    assign vb_can_write = !slot_full[ws];

    // pointwise-only input position counters (last beat of the map)
    reg [7:0] po_r, po_c;
    reg [8:0] po_g;
    wire po_last = (po_g == cfg_ng_m1) && (po_c == cfg_w_m1) && (po_r == cfg_h_m1);
    wire po_we   = cfg_pw_only && in_valid && vb_can_write;
    always @(posedge clk) begin
        if (rst || start) begin
            po_r <= 8'd0; po_c <= 8'd0; po_g <= 9'd0;
        end else if (po_we) begin
            if (po_g == cfg_ng_m1) begin
                po_g <= 9'd0;
                if (po_c == cfg_w_m1) begin po_c <= 8'd0; po_r <= po_r + 8'd1; end
                else po_c <= po_c + 8'd1;
            end else po_g <= po_g + 9'd1;
        end
    end

    // vector buffer write port: depthwise requant output, or the raw
    // input beats in pointwise-only mode
    assign        s2_pop   = !cfg_pw_only && s2_v && vb_can_write;
    wire          vb_we    = cfg_pw_only ? po_we   : s2_pop;
    wire [PW-1:0] vb_wdata = cfg_pw_only ? in_pix  : s2_head;
    wire          vb_wlast = cfg_pw_only ? po_last : s2_hl;

    // the RAM write itself is registered one cycle after the bookkeeping
    // (second P&R: wg -> vram, -0.99 ns). Safe: the sequencer's first read
    // of a slot comes >= 2 cycles after slot_full is set.
    wire [VAW-1:0] vwaddr = {ws, wg[VAW-2:0]};
    reg            vw_a, vw_b;
    reg [VAW-1:0]  vw_addr;
    reg [PW-1:0]   vw_data;
    always @(posedge clk) begin
        vw_a <= vb_we && !wpos && !(rst || start);
        vw_b <= vb_we &&  wpos && !(rst || start);
        vw_addr <= vwaddr;
        vw_data <= vb_wdata;
        if (vw_a) vram_a[vw_addr] <= vw_data;
        if (vw_b) vram_b[vw_addr] <= vw_data;
    end

    // sequencer-side slot release (declared here, driven below)
    reg        rs;                 // slot being read
    wire       seq_release;

    always @(posedge clk) begin
        if (rst || start) begin
            slot_full <= 2'b00; slot_bvalid <= 2'b00;
            ws <= 1'b0; wpos <= 1'b0; wg <= 9'd0;
            frame_in_done <= 1'b0;
        end else begin
            if (seq_release) slot_full[rs] <= 1'b0;
            if (vb_we) begin
                if (wg == cfg_ng_m1) begin
                    wg <= 9'd0;
                    if (wpos || vb_wlast) begin
                        // pair complete (or odd last position): hand over
                        slot_full[ws]   <= 1'b1;
                        slot_bvalid[ws] <= wpos;
                        ws   <= ~ws;
                        wpos <= 1'b0;
                    end else begin
                        wpos <= 1'b1;
                    end
                    if (vb_wlast) frame_in_done <= 1'b1;
                end else begin
                    wg <= wg + 9'd1;
                end
            end
        end
    end

    // =========================================================
    // sequencer
    // =========================================================
    reg        busy_seq;
    reg [8:0]  sg;
    reg [5:0]  scot;
    reg [15:0] pair_cnt;           // pair index of the slot being read
    reg        s_bvalid;

    wire issue     = busy_seq;
    wire last_g    = (sg == cfg_ng_m1);
    wire last_cot  = (scot == cfg_nco_m1);
    assign seq_release = issue && last_g && last_cot;

    // vector RAM reads (synchronous) + control, aligned with w_data
    reg [PW-1:0] xa_r, xb_r;
    reg          b_v, b_first, b_last;
    always @(posedge clk) begin
        xa_r <= vram_a[{rs, sg[VAW-2:0]}];
        xb_r <= vram_b[{rs, sg[VAW-2:0]}];
    end

    // result bookkeeping travelling with each issued "last" beat
    localparam TAGQ = 64;
    always @(posedge clk) begin
        if (rst || start) begin
            busy_seq <= 1'b0;
            sg <= 9'd0; scot <= 6'd0;
            rs <= 1'b0;
            pair_cnt <= 16'd0;
            b_v <= 1'b0; b_first <= 1'b0; b_last <= 1'b0;
        end else begin
            b_v     <= issue;
            b_first <= issue && (sg == 9'd0);
            b_last  <= issue && last_g;
            if (!busy_seq) begin
                if (slot_full[rs]) begin
                    busy_seq <= 1'b1;
                    s_bvalid <= slot_bvalid[rs];
                end
            end else begin
                if (last_g) begin
                    sg <= 9'd0;
                    if (last_cot) begin
                        scot     <= 6'd0;
                        rs       <= ~rs;
                        pair_cnt <= pair_cnt + 16'd1;
                        // continue straight into the other slot if it is ready
                        busy_seq <= slot_full[~rs];
                        s_bvalid <= slot_bvalid[~rs];
                    end else begin
                        scot <= scot + 6'd1;
                    end
                end else begin
                    sg <= sg + 9'd1;
                end
            end
        end
    end

    // weight address = w_base + cot*ng + g of the beat issued this cycle.
    // Beats of a pair are issued back to back in exactly that order, so
    // it is a plain counter restarting at w_base for every pair (was a
    // multiply feeding 32 BRAMs: -0.74 ns in the core synthesis).
    always @(posedge clk) begin
        if (rst || start)                  w_addr <= w_base;
        else if (issue && seq_release)     w_addr <= w_base;
        else if (issue)                    w_addr <= w_addr + 16'd1;
    end

    // =========================================================
    // pointwise array
    // =========================================================
    wire                      res_valid;
    wire signed [32*P_CO-1:0] res_a, res_b;
    // align the operands with w_data (W_LAT cycles after w_addr)
    reg [PW-1:0] xa_r2, xb_r2;
    reg          b_v2, b_first2, b_last2;
    always @(posedge clk) begin
        xa_r2 <= xa_r; xb_r2 <= xb_r;
        if (rst || start) begin b_v2 <= 1'b0; b_first2 <= 1'b0; b_last2 <= 1'b0; end
        else begin b_v2 <= b_v; b_first2 <= b_first; b_last2 <= b_last; end
    end
    wire          a_v     = (W_LAT == 2) ? b_v2     : b_v;
    wire          a_first = (W_LAT == 2) ? b_first2 : b_first;
    wire          a_last  = (W_LAT == 2) ? b_last2  : b_last;
    wire [PW-1:0] a_xa    = (W_LAT == 2) ? xa_r2    : xa_r;
    wire [PW-1:0] a_xb    = (W_LAT == 2) ? xb_r2    : xb_r;

    pw_array_packed #(.P_CI(P), .P_CO(P_CO), .ACC_W(32), .N_DSP_COLS(N_DSP_COLS)) u_pw (
        .clk(clk), .rst(rst || start),
        .in_valid(a_v), .in_first(a_first), .in_last(a_last),
        .xa(a_xa), .xb(a_xb), .w(w_data),
        .res_valid(res_valid), .res_a(res_a), .res_b(res_b)
    );

    // tags of issued output tiles, in issue order (a result exits the
    // array in the same order its last beat entered)
    reg [5:0]  tq_cot   [0:TAGQ-1];
    reg [15:0] tq_pair  [0:TAGQ-1];
    reg        tq_bv    [0:TAGQ-1];
    reg [5:0]  tq_wr, tq_rd;
    always @(posedge clk) begin
        if (rst || start) begin
            tq_wr <= 6'd0;
        end else if (issue && last_g) begin
            tq_cot[tq_wr]  <= scot;
            tq_pair[tq_wr] <= pair_cnt;
            tq_bv[tq_wr]   <= s_bvalid;
            tq_wr <= tq_wr + 6'd1;
        end
    end

    // =========================================================
    // pointwise requant (A and B lanes share per-channel params)
    // =========================================================
    assign pwq_cot = tq_cot[tq_rd];
    // A and B results go through ONE P_CO-lane requant, A in the cycle of
    // res_valid and B in the next one (2026-10-08 area cut: the 2*P_CO-lane
    // requant was 8,545 LUT). Results are >= 2 cycles apart, so the B slot
    // is always free; A's output is held one cycle to meet B's. The
    // parameter lookup still holds the tile's values for B's bias sample
    // (pwq_r changes 3 cycles after res_valid).
    localparam PQL = RQL + 1;
    reg [PQL-1:0] pq_v;
    reg [5:0]  pq_cot  [0:PQL-1];
    reg [15:0] pq_pair [0:PQL-1];
    reg        pq_bv   [0:PQL-1];
    integer k;
    always @(posedge clk) begin
        if (rst || start) begin
            pq_v <= {PQL{1'b0}};
            tq_rd <= 6'd0;
        end else begin
            pq_v <= {pq_v[PQL-2:0], res_valid};
            if (res_valid) tq_rd <= tq_rd + 6'd1;
            pq_cot[0]  <= tq_cot[tq_rd];
            pq_pair[0] <= tq_pair[tq_rd];
            pq_bv[0]   <= tq_bv[tq_rd];
            for (k = 1; k < PQL; k = k + 1) begin
                pq_cot[k] <= pq_cot[k-1]; pq_pair[k] <= pq_pair[k-1]; pq_bv[k] <= pq_bv[k-1];
            end
        end
    end

    // BIAS_LAT = 1: pw_bias/pw_alpha arrive one cycle after the
    // accumulators (the caller's parameter lookup is registered twice)
    reg                       rb_v;
    reg signed [32*P_CO-1:0]  rb_h;
    always @(posedge clk) begin
        rb_v <= res_valid && !(rst || start);
        rb_h <= res_b;
    end
    // synthesis translate_off
    always @(posedge clk)
        if (res_valid && rb_v) $display("ERROR dwpw_engine: pointwise results 1 cycle apart (B requant slot taken) at %0t", $time);
    // synthesis translate_on
    wire signed [8*P_CO-1:0] pq_y;
    requant_act #(.N(P_CO), .IN_W(32), .BIAS_LAT(1)) u_rq_pw (
        .clk(clk), .en(1'b1),
        .acc(x_sel ? x_acc : rb_v ? rb_h : res_a), .bias(pw_bias), .alpha(pw_alpha),
        .shift(pw_shift), .ash(pw_ash), .act(pw_act),
        .y(pq_y)
    );
    reg signed [8*P_CO-1:0] pq_ya;
    always @(posedge clk) pq_ya <= pq_y;
    // GDConv (x_sel) keeps the undelayed output, latency 8
    assign o_ya = x_sel ? pq_y : pq_ya;
    assign o_yb = pq_y;

    // =========================================================
    // outputs + done
    // =========================================================
    // B's requant output, A's held copy and pq_*[PQL-1] are aligned
    assign o_valid   = pq_v[PQL-1];
    assign o_cot     = pq_cot[PQL-1];
    assign o_pair    = pq_pair[PQL-1];
    assign o_b_valid = pq_bv[PQL-1];

    reg [15:0] tiles_out;
    always @(posedge clk) begin
        if (rst || start) begin
            tiles_out <= 16'd0;
            done <= 1'b0;
        end else begin
            if (o_valid) tiles_out <= tiles_out + 16'd1;
            // done: every written pair has been read and every tile is out
            done <= frame_in_done && (slot_full == 2'b00) && !busy_seq &&
                    (tq_rd == tq_wr) && (pq_v == {PQL{1'b0}}) && !res_valid && !b_v && !a_v &&
                    !done && (tiles_out != 16'd0);
        end
    end
endmodule
