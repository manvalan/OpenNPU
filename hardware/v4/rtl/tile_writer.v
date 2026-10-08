// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- output tile writer for dwpw_engine.v (+ residual add).
//
// The engine emits, per output tile, 16 INT8 channels (tile o_cot) of
// two positions A = 2*pair and B = 2*pair+1. With P_CO = 16 each of
// them is exactly one 128-bit feature-map word:
//   word(pos, cot) = out_base + ((pos_offset + pos) << ngo_log2) + cot
// (ngo = Cout/16 is a power of two for every MobileFaceNet layer:
// 4, 8, 16, 32). Same layout the feeder reads, so a layer's output is
// directly the next layer's input.
//
// Residual (MobileFaceNet stride-1 bottlenecks with Cin == Cout): the
// block input X lives at res_base with the same layout; the matching X
// word is read and added byte-wise with INT8 saturation before the
// write: y = sat8(y + x).
//
// t_odd (pool_unit.v): a tile with no B word written at position
// 2*pair+1 instead of 2*pair.
//
// Tiles arrive at most once every ng >= 2 cycles (each needs ng array
// beats); the writer retires one word per cycle (2 per tile), through a
// small tile FIFO. `overflow` is a sticky error flag (must stay 0).
// Residual read port: fixed latency 4 after rd_en (registered here).
// ============================================================
module tile_writer #(
    parameter AW = 15
)(
    input  wire clk,
    input  wire rst,
    input  wire start,

    input  wire [AW-1:0] cfg_out_base_i,
    input  wire [2:0]    cfg_ngo_log2_i,
    input  wire [15:0]   cfg_pos_offset_i,
    input  wire          cfg_res_en_i,
    input  wire [AW-1:0] cfg_res_base_i,

    input  wire          t_valid,
    input  wire [15:0]   t_pair,
    input  wire [5:0]    t_cot,
    input  wire          t_b_valid,
    input  wire          t_odd,
    input  wire [127:0]  t_ya,
    input  wire [127:0]  t_yb,

    output reg           rd_en,
    output reg  [AW-1:0] rd_addr,
    input  wire [127:0]  rd_data,

    output reg           wr_en,
    output reg  [AW-1:0] wr_addr,
    output reg  [127:0]  wr_data,

    output wire          idle,
    output reg           overflow
);
    // static configuration registered locally (placed next to its users): the first in-context P&R had descriptor -> engine paths at -1.33 ns from routing alone; callers hold cfg_* >= 1 cycle before start
    reg [AW-1:0] cfg_out_base;
    reg [2:0] cfg_ngo_log2;
    reg [15:0] cfg_pos_offset;
    reg  cfg_res_en;
    reg [AW-1:0] cfg_res_base;
    always @(posedge clk) begin
        cfg_out_base <= cfg_out_base_i;
        cfg_ngo_log2 <= cfg_ngo_log2_i;
        cfg_pos_offset <= cfg_pos_offset_i;
        cfg_res_en <= cfg_res_en_i;
        cfg_res_base <= cfg_res_base_i;
    end
    // ---------------- input register (tiles cross the die from the
    // engine's requant; second P&R: -0.90 ns into the FIFO RAM) ----------
    reg         ti_valid, ti_bv, ti_odd;
    reg [15:0]  ti_pair;
    reg [5:0]   ti_cot;
    reg [127:0] ti_ya, ti_yb;
    always @(posedge clk) begin
        ti_valid <= t_valid && !(rst || start);
        ti_pair <= t_pair; ti_cot <= t_cot; ti_bv <= t_b_valid; ti_odd <= t_odd;
        ti_ya <= t_ya; ti_yb <= t_yb;
    end

    // ---------------- tile FIFO ----------------
    localparam TD = 4;
    reg [15:0]  q_pair [0:TD-1];
    reg [5:0]   q_cot  [0:TD-1];
    reg         q_bv   [0:TD-1];
    reg         q_odd  [0:TD-1];
    reg [127:0] q_ya   [0:TD-1];
    reg [127:0] q_yb   [0:TD-1];
    reg [2:0]   q_cnt;
    (* max_fanout = 32 *) reg [1:0] q_wr;
    reg [1:0]   q_rd;

    // ---------------- word issuer: A then B of the head tile ----------------
    reg phase_b;                       // 0: issue A, 1: issue B
    wire head_v = (q_cnt != 3'd0);
    wire issue  = head_v;
    wire pop    = issue && (phase_b || !q_bv[q_rd]);

    // sa: position registered ; s0: offset = pos << log2(ngo) + cot
    // (fifth P&R: the fused tile -> offset math was the worst path, -0.41)
    wire [15:0]  pos      = cfg_pos_offset + {q_pair[q_rd], 1'b0} + {15'd0, phase_b | q_odd[q_rd]};
    wire [127:0] wdat     = phase_b ? q_yb[q_rd] : q_ya[q_rd];
    reg          sa_v;
    reg [15:0]   sa_pos;
    reg [5:0]    sa_cot;
    reg [127:0]  sa_d;
    wire [AW-1:0] off     = (sa_pos[AW-1:0] << cfg_ngo_log2) + sa_cot;

    always @(posedge clk) begin
        if (rst || start) begin
            q_cnt <= 3'd0; q_wr <= 2'd0; q_rd <= 2'd0; phase_b <= 1'b0;
        end else begin
            if (ti_valid) begin
                q_pair[q_wr] <= ti_pair; q_cot[q_wr] <= ti_cot; q_bv[q_wr] <= ti_bv; q_odd[q_wr] <= ti_odd;
                q_ya[q_wr] <= ti_ya; q_yb[q_wr] <= ti_yb;
                q_wr <= q_wr + 2'd1;
            end
            if (issue) phase_b <= pop ? 1'b0 : 1'b1;
            if (pop) q_rd <= q_rd + 2'd1;
            q_cnt <= q_cnt + ti_valid - pop;
        end
    end
    always @(posedge clk) begin
        if (rst || start) overflow <= 1'b0;
        else if (ti_valid && q_cnt == TD && !pop) overflow <= 1'b1;
    end

    // ---------------- residual read + aligned word pipe ----------------
    // s0: word offset registered (the tile->offset math alone in a cycle:
    //     -0.23 ns at 5 ns in the core synthesis when fused with the base
    //     add) ; s1: rd_en/rd_addr registered (memory samples) ;
    // s2: BRAM ; s3: BRAM output reg ; s4: data (after the bank-mux reg)
    reg          s0_v, s1_v, s2_v, s3_v, s4_v, s5_v;
    reg [AW-1:0] s0_o, s1_a, s2_a, s3_a, s4_a, s5_a;
    reg [127:0]  s0_d, s1_d, s2_d, s3_d, s4_d, s5_d;
    always @(posedge clk) begin
        if (rst || start) begin
            sa_v <= 1'b0; s0_v <= 1'b0; s1_v <= 1'b0; s2_v <= 1'b0; s3_v <= 1'b0; s4_v <= 1'b0; s5_v <= 1'b0; rd_en <= 1'b0;
        end else begin
            sa_v <= issue; sa_pos <= pos; sa_cot <= q_cot[q_rd]; sa_d <= wdat;
            s0_v <= sa_v;  s0_o <= off; s0_d <= sa_d;
            rd_en   <= s0_v && cfg_res_en;
            rd_addr <= cfg_res_base + s0_o;
            s1_v <= s0_v;  s1_a <= cfg_out_base + s0_o; s1_d <= s0_d;
            s2_v <= s1_v;  s2_a <= s1_a;               s2_d <= s1_d;
            s3_v <= s2_v;  s3_a <= s2_a;               s3_d <= s2_d;
            s4_v <= s3_v;  s4_a <= s3_a;               s4_d <= s3_d;
            s5_v <= s4_v;  s5_a <= s4_a;               s5_d <= s4_d;
        end
    end

    // byte-wise saturating add
    reg [127:0] sum;
    integer b;
    reg signed [8:0] t9;
    always @(*) begin
        for (b = 0; b < 16; b = b + 1) begin
            t9 = $signed(s5_d[b*8 +: 8]) + $signed(rd_data[b*8 +: 8]);
            sum[b*8 +: 8] = (t9 > 9'sd127) ? 8'h7F : ((t9 < -9'sd128) ? 8'h80 : t9[7:0]);
        end
    end

    always @(posedge clk) begin
        if (rst || start) begin
            wr_en <= 1'b0;
        end else begin
            wr_en   <= s5_v;
            wr_addr <= s5_a;
            wr_data <= cfg_res_en ? sum : s5_d;
        end
    end

    assign idle = !ti_valid && (q_cnt == 3'd0) && !sa_v && !s0_v && !s1_v && !s2_v && !s3_v && !s4_v && !s5_v && !wr_en;
endmodule
