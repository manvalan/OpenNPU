// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- requantization + activation, N lanes in parallel.
//
// Brings a wide accumulator back to INT8 so the next stage (the packed
// pointwise array needs INT8 operands) can use it. Power-of-two scales,
// the scheme ESP-DL itself uses (per-tensor exponents), followed by the
// activation on the INT8 value, which is also where ESP-DL applies
// PReLU (a separate layer on the quantized tensor):
//
//   s = acc + bias                                  (per lane)
//   q = sat8( (s + 2^(shift-1)) >>> shift )         (shift = 0: q = sat8(s))
//   act NONE : y = q
//   act RELU : y = max(q, 0)
//   act PRELU: y = q >= 0 ? q : sat8( (q*alpha + 2^(ash-1)) >>> ash )
//
// Rounding is round-half-up (add half, arithmetic shift). Latency 8
// (7 -> 8 after the fifth P&R: saturation flags and the PReLU product
// split),
// (3 -> 5 after the first core synthesis, 5 -> 7 after the third
// in-context P&R, where the last stage -- rounding shift + saturate +
// activation select, 9 logic levels -- was the worst path at -1.16 ns).
// BIAS_LAT = 1: bias and alpha are sampled one cycle AFTER acc (lets
// the caller register its parameter lookup once more),
// one vector per cycle, all registers gated by `en`. Every input
// (including shift/ash/act/alpha) is sampled with its vector and
// carried down the pipe, so per-channel alpha and per-layer settings
// may change on every beat.
// ============================================================
module requant_act #(
    parameter N        = 16,
    parameter IN_W     = 20,
    parameter BIAS_LAT = 0
)(
    input  wire clk,
    input  wire en,

    input  wire signed [IN_W*N-1:0] acc,
    input  wire signed [32*N-1:0]   bias,
    input  wire signed [8*N-1:0]    alpha,
    input  wire [4:0]               shift,
    input  wire [2:0]               ash,
    input  wire [1:0]               act,     // 0 none, 1 relu, 2 prelu

    output wire signed [8*N-1:0]    y
);
    localparam ACT_NONE = 2'd0, ACT_RELU = 2'd1, ACT_PRELU = 2'd2;
    localparam SW = 34;   // IN_W <= 32 and 32-bit bias: 33 bits + 1 for rounding

    // settings travelling with the data (no SRLs: see header history)
    // shift2/half1/ash6/halfa6 feed every lane: replicated (-1.01 /
    // -0.82 / -0.78 ns in the first generic-board P&R, mostly route)
    (* shreg_extract = "no" *) reg [4:0] shift1;
    (* shreg_extract = "no", max_fanout = 16 *) reg [4:0] shift2;
    (* shreg_extract = "no", max_fanout = 8 *) reg [SW-1:0] half1;
    (* shreg_extract = "no" *) reg [2:0] ash1, ash2, ash3, ash4, ash5;
    (* shreg_extract = "no", max_fanout = 16 *) reg [2:0] ash6;
    (* shreg_extract = "no" *) reg [1:0] act1, act2, act3, act4, act5, act6, act7;
    (* shreg_extract = "no" *) reg signed [8*N-1:0] al1, al2, al3, al4, al5;
    (* shreg_extract = "no", max_fanout = 8 *) reg [16:0] halfa6;
    always @(posedge clk) begin
        if (en) begin
            shift1 <= shift;  shift2 <= shift1;
            half1  <= (shift == 5'd0) ? {SW{1'b0}} : ({{(SW-1){1'b0}}, 1'b1} << (shift - 5'd1));
            ash1 <= ash; ash2 <= ash1; ash3 <= ash2; ash4 <= ash3; ash5 <= ash4; ash6 <= ash5;
            act1 <= act; act2 <= act1; act3 <= act2; act4 <= act3; act5 <= act4; act6 <= act5; act7 <= act6;
            al1 <= alpha;
            al2 <= (BIAS_LAT != 0) ? alpha : al1;
            al3 <= al2; al4 <= al3; al5 <= al4;
            halfa6 <= (ash5 == 3'd0) ? 17'd0 : (17'd1 << (ash5 - 3'd1));
        end
    end

    genvar l;
    generate
        for (l = 0; l < N; l = l + 1) begin : GEN_L
            wire signed [IN_W-1:0] a_l = acc[l*IN_W +: IN_W];
            wire signed [SW-1:0] a_ext = {{(SW-IN_W){a_l[IN_W-1]}}, a_l};
            wire signed [31:0]   b_l   = bias[l*32 +: 32];
            wire signed [SW-1:0] b_ext = {{(SW-32){b_l[31]}}, b_l};

            // st1: operands registered
            reg signed [SW-1:0] a1, b1;
            always @(posedge clk) if (en) begin a1 <= a_ext; b1 <= b_ext; end

            // st2: bias + rounding offset
            reg signed [SW-1:0] s2;
            wire signed [SW-1:0] bsel = (BIAS_LAT != 0) ? b_ext : b1;
            always @(posedge clk) if (en) s2 <= a1 + bsel + $signed(half1);

            // st3: arithmetic shift
            reg signed [SW-1:0] sh3;
            always @(posedge clk) if (en) sh3 <= s2 >>> shift2;

            // st4: saturation flags registered
            reg hi0_4, hi1_4, sg4;
            reg [7:0] lo4;
            always @(posedge clk) if (en) begin
                hi0_4 <= ~(|sh3[SW-1:7]);
                hi1_4 <=  (&sh3[SW-1:7]);
                sg4   <= sh3[SW-1];
                lo4   <= sh3[7:0];
            end

            // st5: saturate to int8
            reg signed [7:0] q5;
            always @(posedge clk)
                if (en) q5 <= (hi0_4 | hi1_4) ? lo4 : (sg4 ? 8'sh80 : 8'sh7F);

            // st6: PReLU product in two nibble products (the full 8x8 LUT
            // multiply was -0.36 ns in the fifth P&R)
            wire signed [7:0] al_l = al5[l*8 +: 8];
            wire signed [4:0] al_lo = {1'b0, al_l[3:0]};
            wire signed [3:0] al_hi = al_l[7:4];
            reg signed [12:0] pl6;
            reg signed [11:0] ph6;
            reg signed [7:0]  q6;
            always @(posedge clk) if (en) begin
                pl6 <= q5 * al_lo; ph6 <= q5 * al_hi; q6 <= q5;
            end

            // st7: combine + rounding shift
            reg signed [16:0] ps7;
            reg signed [7:0]  q7;
            wire signed [16:0] pm6 = ($signed(ph6) <<< 4) + $signed(pl6);
            always @(posedge clk) if (en) begin
                ps7 <= (pm6 + $signed(halfa6)) >>> ash6;
                q7  <= q6;
            end

            // st8: saturate + activation select
            wire p_hi0 = ~(|ps7[16:7]);
            wire p_hi1 =  (&ps7[16:7]);
            wire signed [7:0] pr = (p_hi0 | p_hi1) ? ps7[7:0] : (ps7[16] ? 8'sh80 : 8'sh7F);
            reg signed [7:0] y8;
            always @(posedge clk) begin
                if (en) begin
                    case (act7)
                        ACT_RELU:  y8 <= q7[7] ? 8'sd0 : q7;
                        ACT_PRELU: y8 <= q7[7] ? pr : q7;
                        default:   y8 <= q7;
                    endcase
                end
            end
            assign y[l*8 +: 8] = y8;
        end
    endgenerate
endmodule
