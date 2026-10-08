// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- A.1 architecture, third isolated
// building block: bias + activation + saturation on top of
// winograd_f23_multichan.v's own accumulator output.
//
// Deliberately NOT a new convention -- this is a faithful,
// parameterized port of the REAL, already-in-production logic in
// hardware/v3/rtl/neural_processor_packed.v's own saturate_activate
// function (bias sign-extended and added BEFORE saturation,
// ACT_NONE=0/ACT_RELU=1), so a Winograd-computed activation byte is
// bit-for-bit indistinguishable downstream from one computed the
// standard MAC way -- required for the compiled backbone to ever
// hand off to the generic engine's own layers (per this project's
// own "a layer just looks like a fast job" design decision).
//
// Bias is per-output-CHANNEL (shared across all 4 spatial positions
// of the same Winograd tile), matching neural_processor_packed.v's
// own "job_bias ... shared (same neuron)" convention exactly.
// ============================================================
module winograd_f23_output_stage #(
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 48
)(
    input  wire signed [ACC_WIDTH-1:0]  acc0, acc1, acc2, acc3,
    input  wire signed [DATA_WIDTH-1:0] bias,
    input  wire [1:0]                   activation,  // ACT_NONE=0, ACT_RELU=1

    output wire signed [DATA_WIDTH-1:0] y0, y1, y2, y3
);
    localparam ACT_NONE = 2'd0;
    localparam ACT_RELU = 2'd1;

    // ---- REAL BUG found and fixed via this module's own testbench
    // (an intentionally adversarial edge case: acc AT the extreme of
    // its ACC_WIDTH range, bias pushing further): adding an ACC_WIDTH-
    // wide accumulator to an ACC_WIDTH-wide sign-extended bias in
    // ACC_WIDTH-wide arithmetic can itself overflow when acc is
    // already at the edge of its own range -- never hit in this
    // project's own real conv-computed accumulator values (nowhere
    // near the ACC_WIDTH extreme in practice), but a real, cheap-to-
    // fix latent correctness gap, not dismissed just because the
    // triggering input is unrealistic. Fix: do the add in one extra
    // bit of width (SUM_WIDTH = ACC_WIDTH+1) -- provably never
    // overflows, since |acc| < 2^(ACC_WIDTH-1) and |bias| <=
    // 2^(DATA_WIDTH-1), so |acc+bias| is always comfortably inside
    // 2^ACC_WIDTH, the SUM_WIDTH signed range.
    localparam SUM_WIDTH = ACC_WIDTH + 1;

    wire signed [SUM_WIDTH-1:0] bias_ext =
        {{(SUM_WIDTH-DATA_WIDTH){bias[DATA_WIDTH-1]}}, bias};

    wire signed [SUM_WIDTH-1:0] final0 = acc0 + bias_ext;
    wire signed [SUM_WIDTH-1:0] final1 = acc1 + bias_ext;
    wire signed [SUM_WIDTH-1:0] final2 = acc2 + bias_ext;
    wire signed [SUM_WIDTH-1:0] final3 = acc3 + bias_ext;

    // ---- faithful port of neural_processor_packed.v's own
    // saturate_activate, parameterized on SUM_WIDTH/DATA_WIDTH ----
    function automatic signed [DATA_WIDTH-1:0] saturate_activate(
        input signed [SUM_WIDTH-1:0] final_acc,
        input [1:0] act
    );
        reg sign;
        reg upper_all0, upper_all1, in_range, le_zero;
        reg signed [DATA_WIDTH-1:0] y_none, y_relu;
        begin
            sign       = final_acc[SUM_WIDTH-1];
            upper_all0 = ~(|final_acc[SUM_WIDTH-1:DATA_WIDTH-1]);
            upper_all1 =  &final_acc[SUM_WIDTH-1:DATA_WIDTH-1];
            in_range   = upper_all0 | upper_all1;
            le_zero    = sign | ~(|final_acc);

            y_none = in_range ? final_acc[DATA_WIDTH-1:0]
                               : (sign ? {1'b1, {(DATA_WIDTH-1){1'b0}}}
                                       : {1'b0, {(DATA_WIDTH-1){1'b1}}});
            y_relu = le_zero ? {DATA_WIDTH{1'b0}}
                              : (upper_all0 ? final_acc[DATA_WIDTH-1:0]
                                            : {1'b0, {(DATA_WIDTH-1){1'b1}}});
            saturate_activate = (act == ACT_NONE) ? y_none : y_relu;
        end
    endfunction

    assign y0 = saturate_activate(final0, activation);
    assign y1 = saturate_activate(final1, activation);
    assign y2 = saturate_activate(final2, activation);
    assign y3 = saturate_activate(final3, activation);
endmodule
