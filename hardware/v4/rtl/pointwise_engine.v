// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- "G-esteso" pipeline, pointwise stage:
// output[co] = act( Σ_ci wp(ci,co)·dw(ci) + bias(co) ), no spatial
// kernel at all (see hardware/v4/docs/DEPTHWISE_SEPARABLE_PIPELINE.md
// §2) -- structurally identical to the real, existing, timing-closed
// v3-artix7 generic engine's own FC-style job. This module is a
// deliberately simple, direct stand-in (proves the pipeline
// end-to-end) -- real, disclosed later work: replace with an actual
// adapter onto packed_pe_chained.v/neural_processor_packed.v so the
// real generic engine is reused, not reimplemented.
//
// Saturation/activation is a faithful, parameterized port of
// neural_processor_packed.v's own real saturate_activate convention
// (same one already reused in winograd_f23_output_stage.v), widened
// by one bit before the bias add per the REAL overflow bug found and
// fixed in that earlier module -- applied proactively here, not
// rediscovered the same way twice.
// ============================================================
module pointwise_engine #(
    parameter CIN       = 4,
    parameter COUT      = 4,
    parameter DW_WIDTH  = 20,  // matches depthwise_mac3x3.v's own y width
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 40
)(
    input  wire signed [DW_WIDTH*CIN-1:0] dw_flat,
    input  wire signed [8*CIN*COUT-1:0]   wp_flat,   // wp_flat[co*CIN*8 + ci*8 +: 8]
    input  wire signed [8*COUT-1:0]       bias_flat,
    input  wire [1:0]                     activation,

    output wire signed [8*COUT-1:0]       y_flat
);
    localparam ACT_NONE = 2'd0;
    localparam ACT_RELU = 2'd1;
    localparam SUM_WIDTH = ACC_WIDTH + 1;

    genvar co, ci;
    generate
        for (co = 0; co < COUT; co = co + 1) begin : GEN_COUT
            // REAL BUG found and fixed via this module's own testbench:
            // a signed NxM multiply needs N+M bits, not N+M-1 -- the
            // THE REAL bug, found via this module's own random trials
            // (the hand-picked edge cases happened not to expose it):
            // a part-select of a `signed` vector is UNSIGNED per
            // Verilog's own language semantics, even though the
            // parent bus is declared signed -- `dw_flat[...] *
            // wp_flat[...]` computed an UNSIGNED multiply, corrupting
            // the sign for any negative operand (exactly the observed
            // symptom: results clamping to +127 where -128 was
            // expected, and vice versa). Fixed with explicit
            // $signed() casts at the point of use -- the standard,
            // minimal fix for this well-known Verilog pitfall. Width
            // DW_WIDTH+8 bits is the correct, standard size for an
            // N-bit x M-bit signed product (N+M bits, no more).
            wire signed [DW_WIDTH+8-1:0] prod [0:CIN-1];
            for (ci = 0; ci < CIN; ci = ci + 1) begin : GEN_CIN
                assign prod[ci] = $signed(dw_flat[ci*DW_WIDTH +: DW_WIDTH]) * $signed(wp_flat[(co*CIN+ci)*8 +: 8]);
            end

            reg signed [ACC_WIDTH-1:0] acc;
            integer k;
            always @(*) begin
                acc = {ACC_WIDTH{1'b0}};
                for (k = 0; k < CIN; k = k + 1)
                    acc = acc + prod[k];
            end

            wire signed [SUM_WIDTH-1:0] bias_ext =
                {{(SUM_WIDTH-DATA_WIDTH){bias_flat[co*8+DATA_WIDTH-1]}}, bias_flat[co*8 +: DATA_WIDTH]};
            wire signed [SUM_WIDTH-1:0] final_sum = acc + bias_ext;

            function automatic signed [DATA_WIDTH-1:0] saturate_activate(
                input signed [SUM_WIDTH-1:0] fa, input [1:0] act
            );
                reg sign, upper_all0, upper_all1, in_range, le_zero;
                reg signed [DATA_WIDTH-1:0] y_none, y_relu;
                begin
                    sign       = fa[SUM_WIDTH-1];
                    upper_all0 = ~(|fa[SUM_WIDTH-1:DATA_WIDTH-1]);
                    upper_all1 =  &fa[SUM_WIDTH-1:DATA_WIDTH-1];
                    in_range   = upper_all0 | upper_all1;
                    le_zero    = sign | ~(|fa);
                    y_none = in_range ? fa[DATA_WIDTH-1:0]
                                       : (sign ? {1'b1, {(DATA_WIDTH-1){1'b0}}}
                                               : {1'b0, {(DATA_WIDTH-1){1'b1}}});
                    y_relu = le_zero ? {DATA_WIDTH{1'b0}}
                                      : (upper_all0 ? fa[DATA_WIDTH-1:0]
                                                    : {1'b0, {(DATA_WIDTH-1){1'b1}}});
                    saturate_activate = (act == ACT_NONE) ? y_none : y_relu;
                end
            endfunction

            assign y_flat[co*8 +: 8] = saturate_activate(final_sum, activation);
        end
    endgenerate
endmodule
