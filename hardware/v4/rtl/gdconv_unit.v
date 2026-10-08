// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- GDConv (global depthwise conv) unit: MobileFaceNet's 7x7x512 ->
// 1x1x512 "linear GDConv7x7" layer.
//
//   out[c] = requant( sum_{p in 7x7} w[p][c] * x[p][c] + bias[c] )
//
// Fed by the same feeder as the engine (pointwise-only order: beat =
// (position p, group g), g fastest, 16 channels per beat). Per beat,
// 16 LUT multipliers; the 16 partial sums of group g accumulate in a
// small distributed RAM indexed by g (read-modify-write; consecutive
// beats hit different groups, so ng >= 3 keeps the 2-cycle RMW free of
// hazards -- MobileFaceNet: ng = 32).
//
// Weights: 16 bytes per beat, word = w_base + beat/16 of the pw weight
// memory (2048 bit), 128-bit chunk = beat % 16 -> w_addr/w_chunk out,
// w_data (the selected chunk) valid 3 cycles after the beat is accepted
// (BRAM + output register + registered chunk select, done by the caller).
//
// After the last beat, the ng results are requantized (params by group
// through q_g) and emitted one group per cycle as "tiles" for
// tile_writer (pair 0, cot = g, B absent). The requant is not in this
// unit: rq_acc goes to lanes 0..15 of the engine's pointwise requant
// (dwpw_engine x_acc, never busy during a GDConv pass, same settings
// pw_* and same parameter lookup) and its result comes back on rq_y,
// 8 cycles later (rq_acc is one stage after the accumulator read).
// ============================================================
module gdconv_unit #(
    parameter MAXNG = 32
)(
    input  wire clk,
    input  wire rst,
    input  wire start,
    output reg  done,

    input  wire [7:0]  cfg_npos_i,      // positions (49)
    input  wire [5:0]  cfg_ng_i,
    input  wire [15:0] cfg_w_base_i,
    input  wire [4:0]  cfg_shift_i,
    input  wire [2:0]  cfg_ash_i,
    input  wire [1:0]  cfg_act_i,

    input  wire         in_valid,
    output wire         in_ready,
    input  wire [127:0] in_pix,

    output reg  [15:0]  w_addr,
    output reg  [3:0]   w_chunk,
    input  wire [127:0] w_data,       // chunk of the beat accepted 2 cycles earlier

    output wire [5:0]   q_g,          // caller returns params of q_g REGISTERED TWICE (2 cycles)
    input  wire [511:0] q_bias,
    input  wire [127:0] q_alpha,

    output reg  [32*16-1:0] rq_acc,  // to the shared requant (BIAS_LAT 1: q_bias one cycle later)
    input  wire [127:0]     rq_y,

    output wire         t_valid,
    output wire [5:0]   t_cot,
    output wire [127:0] t_y
);
    // static configuration registered locally (see dwpw_engine.v)
    reg [7:0] cfg_npos;
    reg [5:0] cfg_ng;
    reg [15:0] cfg_w_base;
    reg [4:0] cfg_shift;
    reg [2:0] cfg_ash;
    reg [1:0] cfg_act;
    always @(posedge clk) begin
        cfg_npos <= cfg_npos_i;
        cfg_ng <= cfg_ng_i;
        cfg_w_base <= cfg_w_base_i;
        cfg_shift <= cfg_shift_i;
        cfg_ash <= cfg_ash_i;
        cfg_act <= cfg_act_i;
    end
    localparam GW = $clog2(MAXNG);

    // ---------------- accumulate phase ----------------
    reg        acc_phase;
    reg [15:0] beat;
    reg [5:0]  g;
    reg [7:0]  p;
    wire last_beat = (g == cfg_ng - 6'd1) && (p == cfg_npos - 8'd1);
    assign in_ready = acc_phase;
    wire take = in_valid && acc_phase;

    // beat accepted in cycle t (w_addr/w_chunk = its weights); stages
    // a/b/c = cycles t+1..t+3, w_data (its weight chunk) valid at c
    reg         va, vb, vc;
    reg [GW-1:0] ga, gb;
    // gc / eg address the 512-bit accumulator LUTRAM (~85 RAM32M): the
    // first generic-board P&R had them at -0.91 / -1.26 ns with 1 logic
    // level, all route -> replicated (2026-10-07)
    (* max_fanout = 16 *) reg [GW-1:0] gc;
    reg         fa, fb, fc;          // first position (p == 0): start from 0
    reg [127:0] xa, xb, xc;
    always @(posedge clk) begin
        if (rst || start) begin
            va <= 1'b0; vb <= 1'b0; vc <= 1'b0;
        end else begin
            va <= take; ga <= g[GW-1:0]; fa <= (p == 8'd0); xa <= in_pix;
            vb <= va;   gb <= ga;        fb <= fa;         xb <= xa;
            vc <= vb;   gc <= gb;        fc <= fb;         xc <= xb;
        end
    end

    always @(posedge clk) begin
        if (rst || start) begin
            w_addr <= cfg_w_base; w_chunk <= 4'd0; beat <= 16'd0;
        end else if (take) begin
            beat <= beat + 16'd1;
            w_chunk <= w_chunk + 4'd1;
            if (w_chunk == 4'd15) w_addr <= w_addr + 16'd1;
        end
    end

    // stage c -> e: split 8x8 products (x * w[3:0] unsigned nibble, x *
    // w[7:4] signed nibble) + registered accumulator read; stage e:
    // combine + accumulate + write. (third in-context P&R: the whole
    // 8x8 LUT multiply in one cycle was -0.81 ns, the async RMW -0.58 ns)
    (* ram_style = "distributed" *) reg [32*16-1:0] acc [0:MAXNG-1];
    // vd/gd drive the write port of every LUTRAM column (-0.92 / -0.79 ns
    // in the first generic-board P&R, all route): replicated
    reg             ve;
    (* max_fanout = 16 *) reg vd;
    reg             fe;
    (* max_fanout = 16 *) reg fd;
    reg [GW-1:0]    ge;
    (* max_fanout = 16 *) reg [GW-1:0] gd;
    reg [16*13-1:0] pl_e;          // x * w[3:0]  : 8b signed x 5b signed(>=0) -> 13b
    reg [16*12-1:0] ph_e;          // x * w[7:4]  : 8b signed x 4b signed      -> 12b
    reg [32*16-1:0] acc_q;
    integer l;
    genvar gl;
    generate
        for (gl = 0; gl < 16; gl = gl + 1) begin : GEN_P
            wire signed [7:0]  xw = xc[gl*8 +: 8];
            wire signed [4:0]  wl = {1'b0, w_data[gl*8 +: 4]};
            wire signed [3:0]  wh = w_data[gl*8+4 +: 4];
            wire signed [12:0] pl = xw * wl;
            wire signed [11:0] ph = xw * wh;
            always @(posedge clk) begin
                pl_e[gl*13 +: 13] <= pl;
                ph_e[gl*12 +: 12] <= ph;
            end
        end
    endgenerate
    // stage e: combine the two partial products into prod_d; stage d (one
    // cycle later): accumulate + write. (first fixed board P&R: combine +
    // 32-bit accumulate + LUTRAM write in one cycle was -0.107 ns, 9
    // levels.) The accumulator row is read one stage later too (acc_q at
    // gd); the next beat of the same group is ng >= 3 cycles behind, so
    // its read still sees this write.
    reg [32*16-1:0] prod_d;
    reg signed [31:0] prod;
    always @(posedge clk) begin
        ve <= vc && !(rst || start); ge <= gc; fe <= fc;
        vd <= ve && !(rst || start); gd <= ge; fd <= fe;
        acc_q <= acc[ge];
        for (l = 0; l < 16; l = l + 1) begin
            prod = ($signed(ph_e[l*12 +: 12]) <<< 4) + $signed(pl_e[l*13 +: 13]);
            prod_d[l*32 +: 32] <= prod;
        end
    end
    reg  [32*16-1:0] acc_new;
    always @(*) begin
        for (l = 0; l < 16; l = l + 1)
            acc_new[l*32 +: 32] = (fd ? 32'd0 : acc_q[l*32 +: 32]) + prod_d[l*32 +: 32];
    end
    always @(posedge clk) if (vd) acc[gd] <= acc_new;

    // ---------------- emit phase ----------------
    reg        emit;
    (* max_fanout = 16 *) reg [5:0]  eg;
    reg        drain;                  // waiting for the last RMW to land
    always @(posedge clk) begin
        if (rst) begin
            acc_phase <= 1'b0; emit <= 1'b0; drain <= 1'b0;
            g <= 6'd0; p <= 8'd0;
        end else if (start) begin
            acc_phase <= 1'b1; emit <= 1'b0; drain <= 1'b0;
            g <= 6'd0; p <= 8'd0; eg <= 6'd0;
        end else begin
            if (take) begin
                if (g == cfg_ng - 6'd1) begin g <= 6'd0; p <= p + 8'd1; end
                else g <= g + 6'd1;
                if (last_beat) begin acc_phase <= 1'b0; drain <= 1'b1; end
            end
            if (drain && !va && !vb && !vc && !ve && !vd) begin drain <= 1'b0; emit <= 1'b1; eg <= 6'd0; end
            if (emit) begin
                if (eg == cfg_ng - 6'd1) emit <= 1'b0;
                eg <= eg + 6'd1;
            end
        end
    end

    // requant of one group per cycle: the accumulator row is read into
    // rq_acc_l next to the LUTRAM, then registered again into rq_acc that
    // travels to the engine's requant; q_g = eg_l is delayed by the same
    // first cycle, so the caller's 2-cycle parameter lookup of q_g still
    // lands together with rq_acc
    localparam RQL = 8;
    reg             emit_d, emit_l;
    reg [5:0]       eg_d, eg_l;
    reg [32*16-1:0] rq_acc_l;
    assign q_g = eg_l;
    always @(posedge clk) begin
        rq_acc_l <= acc[eg[GW-1:0]];
        emit_l   <= emit && !(rst || start);
        eg_l     <= eg;
        rq_acc   <= rq_acc_l;
        emit_d   <= emit_l && !(rst || start);
        eg_d     <= eg_l;
    end
    reg [RQL-1:0] ev;
    reg [5:0]     eq [0:RQL-1];
    integer k;
    always @(posedge clk) begin
        if (rst || start) ev <= {RQL{1'b0}};
        else ev <= {ev[RQL-2:0], emit_d};
        eq[0] <= eg_d;
        for (k = 1; k < RQL; k = k + 1) eq[k] <= eq[k-1];
    end
    assign t_y     = rq_y;
    assign t_valid = ev[RQL-1];
    assign t_cot   = eq[RQL-1];

    // done once the last group has left the requant
    reg emitted_all;
    always @(posedge clk) begin
        if (rst || start) begin
            emitted_all <= 1'b0; done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (emit && eg == cfg_ng - 6'd1) emitted_all <= 1'b1;
            if (emitted_all && ev == {RQL{1'b0}} && !emit && !emit_l && !emit_d) begin
                done <= 1'b1; emitted_all <= 1'b0;
            end
        end
    end
endmodule
