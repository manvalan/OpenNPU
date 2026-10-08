// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- pooling unit: max or average pooling over a KxK window, 16
// channels per word, fed by conv3_feeder.v in pooling order (for every
// output position, for every group g, the K*K taps of g consecutive).
//
//   max: acc = max of the taps inside the map (out_pad taps ignored);
//        a window with no tap inside (a zero group emitted for a
//        concatenation copy, g >= map groups) gives 0
//   avg: acc = sum of the K*K taps (outside = 0, count_include_pad)
//   y   = sat8((acc * mul + round) >>> sh), round = 2^(sh-1) (sh > 0)
//
// mul/sh come from the descriptor: max pooling uses mul = 1, sh = 0
// (y = acc); 2x2 average mul = 1, sh = 2; 3x3 average e.g. mul = 57,
// sh = 9 (57/512 ~ 1/9, the compiler's v4_ref.pool() uses the same
// integers, so the result is bit-exact whatever the constants).
//
// Output: one 16-channel word per (position, group) as a tile for
// tile_writer.v (t_pair = pos/2, t_odd = pos%2, no B word), at most one
// every K*K cycles (K = 1, a copy: one per cycle -- tile_writer retires
// one word per cycle). done pulses with the last word.
// Scaling with mul != 1 or sh != 0 needs >= 4 cycles per window (it is
// done 4 lanes at a time, then round / shift / saturate in 3 pipeline
// steps): only average pooling uses it, with 4 or 9 taps per window.
// ============================================================
module pool_unit (
    input  wire clk,
    input  wire rst,
    input  wire start,
    output reg  done,

    // stable from >= 1 cycle before start
    input  wire [7:0]  cfg_ow_i,
    input  wire [7:0]  cfg_oh_i,
    input  wire [5:0]  cfg_ng_i,
    input  wire        cfg_k2_i,       // 2x2 (4 taps) else 3x3 (9 taps)
    input  wire        cfg_k1_i,       // 1 tap (copy / upsampling: y = x with mul 1, sh 0)
    input  wire        cfg_max_i,      // max pooling, else average
    input  wire [7:0]  cfg_mul_i,
    input  wire [3:0]  cfg_sh_i,

    input  wire         in_valid,
    output wire         in_ready,
    input  wire [127:0] in_data,
    input  wire         in_pad,

    output reg          t_valid,
    output reg  [15:0]  t_pair,
    output reg          t_odd,
    output reg  [5:0]   t_cot,
    output reg  [127:0] t_y
);
    reg [7:0] ow_m1, oh_m1;
    reg [5:0] ng_m1;
    reg [3:0] nt_m1;
    reg       mx;
    reg [7:0] mul;
    reg [3:0] sh;
    always @(posedge clk) begin
        ow_m1 <= cfg_ow_i - 8'd1; oh_m1 <= cfg_oh_i - 8'd1; ng_m1 <= cfg_ng_i - 6'd1;
        nt_m1 <= cfg_k1_i ? 4'd0 : cfg_k2_i ? 4'd3 : 4'd8; mx <= cfg_max_i; mul <= cfg_mul_i; sh <= cfg_sh_i;
    end

    assign in_ready = 1'b1;
    // input registered: conv3_feeder FIFO read -> compare/add -> s1_acc
    // was -0.96 ns (6 levels) in the first generic-board P&R
    reg         i_v, i_pad;
    reg [127:0] i_data;
    always @(posedge clk) begin
        i_v <= in_valid && !(rst || start);
        i_data <= in_data; i_pad <= in_pad;
    end
    wire beat = i_v;

    // ---------------- tap accumulation ----------------
    reg [3:0]  tap;
    reg [5:0]  g;
    reg [7:0]  oj, oi;
    reg [15:0] pos;
    reg [191:0] acc;                 // 16 lanes x 12 bit signed
    reg [191:0] nacc;
    reg         anyv;                // max: a tap inside the map seen in this window
    wire        nanyv = (tap == 4'd0) ? !i_pad : (anyv | !i_pad);
    integer l;
    reg signed [11:0] a12, x12;
    always @(*) begin
        for (l = 0; l < 16; l = l + 1) begin
            a12 = acc[l*12 +: 12];
            x12 = {{4{i_data[l*8+7]}}, i_data[l*8 +: 8]};
            if (mx) begin
                if (tap == 4'd0) nacc[l*12 +: 12] = i_pad ? -12'sd128 : x12;
                else             nacc[l*12 +: 12] = (!i_pad && x12 > a12) ? x12 : a12;
            end else begin
                nacc[l*12 +: 12] = (tap == 4'd0) ? x12 : a12 + x12;
            end
        end
    end

    reg        s1_v, s1_last;
    reg [15:0] s1_pos;
    reg [5:0]  s1_g;
    reg [191:0] s1_acc;
    always @(posedge clk) begin
        if (rst || start) begin
            tap <= 4'd0; g <= 6'd0; oj <= 8'd0; oi <= 8'd0; pos <= 16'd0; s1_v <= 1'b0;
        end else begin
            s1_v <= 1'b0;
            if (beat) begin
                acc <= nacc; anyv <= nanyv;
                if (tap == nt_m1) begin
                    tap <= 4'd0;
                    s1_v <= 1'b1; s1_acc <= (mx && !nanyv) ? 192'd0 : nacc; s1_pos <= pos; s1_g <= g;
                    s1_last <= (g == ng_m1) && (oj == ow_m1) && (oi == oh_m1);
                    if (g == ng_m1) begin
                        g <= 6'd0; pos <= pos + 16'd1;
                        if (oj == ow_m1) begin oj <= 8'd0; oi <= oi + 8'd1; end
                        else oj <= oj + 8'd1;
                    end else g <= g + 6'd1;
                end else tap <= tap + 4'd1;
            end
        end
    end

    // ---------------- scale: product, then round / shift / saturate ----------------
    // mul = 1, sh = 0 (max pooling, copy, upsampling): y = sat8(acc), one
    // word per cycle. Otherwise (average pooling: >= 4 taps, so >= 4
    // cycles between windows) the 16 lanes are scaled 4 at a time over 4
    // cycles: 4 multipliers and 4 round/shift/saturate lanes instead of 16.
    function [7:0] sat8_12(input [11:0] a);
        sat8_12 = ($signed(a) > 12'sd127) ? 8'h7F : (($signed(a) < -12'sd128) ? 8'h80 : a[7:0]);
    endfunction
    reg        fast;
    always @(posedge clk) fast <= (mul == 8'd1) && (sh == 4'd0);

    // serial path, stage A: 4 products per cycle (quarter q of the window)
    reg [191:0] sc_acc;
    reg [15:0]  sc_pos;  reg [5:0] sc_g;  reg sc_last;
    reg [1:0]   qa;      reg       a_run;
    reg [79:0]  pa;                  // 4 lanes x 20 bit signed
    reg         pa_v;    reg [1:0] pa_q;
    reg [15:0]  pa_pos;  reg [5:0] pa_g;  reg pa_last;
    wire [47:0] acc_q = sc_acc[47:0];   // sc_acc shifts down one quarter per cycle
    integer m;
    always @(posedge clk) begin
        if (rst || start) begin a_run <= 1'b0; pa_v <= 1'b0; end
        else begin
            pa_v <= 1'b0;
            if (a_run) begin
                for (m = 0; m < 4; m = m + 1)
                    pa[m*20 +: 20] <= $signed(acc_q[m*12 +: 12]) * $signed({1'b0, mul});
                sc_acc <= {48'd0, sc_acc[191:48]};
                pa_v <= 1'b1; pa_q <= qa;
                if (qa == 2'd3) begin
                    a_run <= 1'b0; pa_pos <= sc_pos; pa_g <= sc_g; pa_last <= sc_last;
                end
                qa <= qa + 2'd1;
            end
            if (s1_v && !fast) begin
`ifndef SYNTHESIS
                if (a_run && qa != 2'd3) $display("ERROR pool_unit: scaled windows closer than 4 cycles");
`endif
                sc_acc <= s1_acc; sc_pos <= s1_pos; sc_g <= s1_g; sc_last <= s1_last;
                a_run <= 1'b1; qa <= 2'd0;
            end
        end
    end

    // stage B, three registered steps (the first board P&R had the whole
    // round + variable shift + saturate in one cycle: 11-13 logic levels,
    // -1.93 ns at 199 MHz, 2026-10-07): B1 adds the rounding constant, B2
    // shifts, B3 saturates (sign-extension check, no carry chain) into ylo.
    // Two more cycles of latency; windows are >= 4 cycles apart anyway.
    reg signed [20:0] rnd;
    always @(posedge clk) rnd <= (sh == 4'd0) ? 21'sd0 : (21'sd1 <<< (sh - 4'd1));
    reg [83:0]  pb;                  // B1: 4 lanes x 21 bit, product + round
    reg         pb_v;    reg [1:0] pb_q;
    reg [15:0]  pb_pos;  reg [5:0] pb_g;  reg pb_last;
    reg [83:0]  pc;                  // B2: 4 lanes x 21 bit, shifted
    reg         pc_v;    reg [1:0] pc_q;
    reg [15:0]  pc_pos;  reg [5:0] pc_g;  reg pc_last;
    integer n;
    always @(posedge clk) begin
        for (n = 0; n < 4; n = n + 1) begin
            pb[n*21 +: 21] <= $signed(pa[n*20 +: 20]) + rnd;
            pc[n*21 +: 21] <= $signed(pb[n*21 +: 21]) >>> sh;
        end
        pb_q <= pa_q; pb_pos <= pa_pos; pb_g <= pa_g; pb_last <= pa_last;
        pc_q <= pb_q; pc_pos <= pb_pos; pc_g <= pb_g; pc_last <= pb_last;
        if (rst || start) begin pb_v <= 1'b0; pc_v <= 1'b0; end
        else begin pb_v <= pa_v; pc_v <= pb_v; end
    end
    // B3: saturate to int8 -- in range iff bits [20:7] are all equal
    reg [31:0] y4;
    reg [20:0] c21;
    always @(*) begin
        for (n = 0; n < 4; n = n + 1) begin
            c21 = pc[n*21 +: 21];
            if (&c21[20:7] || ~|c21[20:7]) y4[n*8 +: 8] = c21[7:0];
            else                           y4[n*8 +: 8] = c21[20] ? 8'h80 : 8'h7F;
        end
    end
    reg [95:0] ylo;                  // lanes 0..11 of the word being scaled

    integer f;
    always @(posedge clk) begin
        if (rst || start) begin t_valid <= 1'b0; done <= 1'b0; end
        else begin
            t_valid <= 1'b0; done <= 1'b0;
            if (pc_v) begin
                case (pc_q)
                    2'd0: ylo[31:0]  <= y4;
                    2'd1: ylo[63:32] <= y4;
                    2'd2: ylo[95:64] <= y4;
                    default: begin
                        t_valid <= 1'b1; t_y <= {y4, ylo};
                        t_pair <= {1'b0, pc_pos[15:1]}; t_odd <= pc_pos[0]; t_cot <= pc_g;
                        done <= pc_last;
                    end
                endcase
            end else if (s1_v && fast) begin
                t_valid <= 1'b1;
                for (f = 0; f < 16; f = f + 1) t_y[f*8 +: 8] <= sat8_12(s1_acc[f*12 +: 12]);
                t_pair <= {1'b0, s1_pos[15:1]}; t_odd <= s1_pos[0]; t_cot <= s1_g;
                done <= s1_last;
            end
        end
    end
endmodule
