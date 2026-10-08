// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- G-esteso, step 2: streaming pointwise (1x1 conv) MAC array.
//
// Datapath reused from v3's neural_processor_packed.v (the real,
// timing-closed engine): the SAME 2-MACs-per-DSP48E1 packing formula
// (verified exhaustively 16,777,216/16,777,216 in tb_mac2_dsp_packed.v),
// the SAME raw product register + separate unpack stage (EXP-0094
// timing fix), the SAME balanced registered adder tree. What is dropped
// is the per-job FSM (IDLE/LOAD/.../DONE, which drains the pipeline
// after every neuron) and the DDR3 activation fetch: this array is a
// pure stream, one beat per cycle, no bubbles between output tiles.
//
// One beat = one (ci_tile, co_tile) step for ONE PAIR of spatial
// positions (A, B) that share every weight:
//   xa, xb : P_CI int8 activations of positions A and B (same ci tile)
//   w      : P_CO x P_CI int8 weights, w[(co*P_CI + ci)*8 +: 8]
//   first  : this beat starts a new accumulation (first ci tile)
//   last   : this beat ends it (last ci tile) -> result emitted
// Column co computes sum_ci w[co][ci]*x[ci] for A and for B, so the
// array does 2*P_CI*P_CO MACs per cycle on P_CI*P_CO DSP48E1.
//
// Output: when a `last` beat reaches the end of the pipe, res_valid
// pulses for one cycle with all 2*P_CO accumulators (ACC_W bits each):
// res_a[co*ACC_W +: ACC_W], res_b[...]. No back-pressure inside the
// array (every stage always advances) -- the feeder guarantees the
// consumer can take a result every cycle a `last` exits.
//
// Latency from beat to res_valid: 1 (packed regs) + 2 (DSP M, P) + 1
// (unpack) + log2(P_CI) (tree) + 1 (accumulate) = 5 + log2(P_CI).
// ============================================================
module pw_array_packed #(
    parameter P_CI  = 16,   // must be a power of two
    parameter P_CO  = 14,
    parameter ACC_W = 32,
    // columns [0, N_DSP_COLS) use packed DSP48E1 multiplies; columns
    // [N_DSP_COLS, P_CO) use two plain 8x8 LUT multiplies per cell
    // (same pipeline depth, same results). Lets a 16x16 array exist on
    // a 240-DSP part: 14 DSP columns (224 DSP) + 2 LUT columns.
    parameter N_DSP_COLS = P_CO
)(
    input  wire clk,
    input  wire rst,

    input  wire                        in_valid,
    input  wire                        in_first,
    input  wire                        in_last,
    input  wire signed [8*P_CI-1:0]      xa,
    input  wire signed [8*P_CI-1:0]      xb,
    input  wire signed [8*P_CI*P_CO-1:0] w,

    output reg                         res_valid,
    output wire signed [ACC_W*P_CO-1:0] res_a,
    output wire signed [ACC_W*P_CO-1:0] res_b
);
    localparam TL = $clog2(P_CI);
    localparam A_W = 25;          // DSP48E1 A port
    localparam PROD_W = A_W + 8;  // 33

    // ---------------- control pipeline ----------------
    // stage index: 0 packed-operand regs, 1 DSP M reg, 2 DSP P reg,
    // 3 unpack, 4..3+TL tree, then acc
    localparam NST = 4 + TL;
    // tv/tf drive every accumulator of every column (f_pipe -> acc_a was
    // -0.84 ns in the first generic-board P&R): replicated
    (* max_fanout = 64 *) reg [NST-1:0] v_pipe, f_pipe;
    reg [NST-1:0] l_pipe;
    always @(posedge clk) begin
        if (rst) begin
            v_pipe <= {NST{1'b0}};
            f_pipe <= {NST{1'b0}};
            l_pipe <= {NST{1'b0}};
        end else begin
            v_pipe <= {v_pipe[NST-2:0], in_valid};
            f_pipe <= {f_pipe[NST-2:0], in_valid & in_first};
            l_pipe <= {l_pipe[NST-2:0], in_valid & in_last};
        end
    end
    wire tv = v_pipe[NST-1];   // tree output valid (aligned with tree sums)
    wire tf = f_pipe[NST-1];
    wire tl = l_pipe[NST-1];

    // ---------------- stage 0: packed operand + weight registers ----------------
    // The x1*2^16 + x0 packing add is done HERE, from the input ports,
    // and registered, so the DSP's A port is driven straight from a
    // register (first OOC run with the add between the input register
    // and the DSP: WNS -1.018 ns at 5 ns, path xa0 -> CARRY4 x3 -> A).
    // One packed register per ci, shared by all P_CO columns.
    localparam A_W0 = 25;
    reg signed [A_W0-1:0]        pk0 [0:P_CI-1];
    reg signed [8*P_CI*P_CO-1:0] w0;
    genvar gi;
    generate
        for (gi = 0; gi < P_CI; gi = gi + 1) begin : GEN_PACK
            wire signed [7:0] x0 = xa[gi*8 +: 8];
            wire signed [7:0] x1 = xb[gi*8 +: 8];
            // separate signed wires, as in neural_processor_packed.v: an
            // inline `($signed(x1) <<< 16) + {sext(x0)}` mixes in an
            // (unsigned) concatenation, which makes the whole expression
            // unsigned and zero-extends x1 -- caught by the tb (8898
            // errors) on the first try of this stage.
            wire signed [A_W0-1:0] x0_sext  = {{(A_W0-8){x0[7]}}, x0};
            wire signed [A_W0-1:0] x1_shift = $signed(x1) <<< 16;
            always @(posedge clk)
                pk0[gi] <= x1_shift + x0_sext;
        end
    endgenerate
    always @(posedge clk) w0 <= w;
    // raw copies for the LUT columns (unused -> trimmed if N_DSP_COLS == P_CO)
    reg signed [8*P_CI-1:0] xa0, xb0;
    always @(posedge clk) begin
        xa0 <= xa;
        xb0 <= xb;
    end

    genvar co, ci, gl, gn;
    generate
        for (co = 0; co < P_CO; co = co + 1) begin : GEN_COL
            // ---------- stages 1-2: packed multiply (DSP M reg, then P reg) ----------
            reg  signed [PROD_W-1:0] prod_m [0:P_CI-1];
            reg  signed [PROD_W-1:0] prod [0:P_CI-1];
            // ---------- stage 3: unpack ----------
            reg  signed [ACC_W-1:0]  pa [0:P_CI-1];
            reg  signed [ACC_W-1:0]  pb [0:P_CI-1];
            for (ci = 0; ci < P_CI; ci = ci + 1) begin : GEN_MAC
                wire signed [7:0] wt = w0[(co*P_CI + ci)*8 +: 8];
                if (co < N_DSP_COLS) begin : G_DSP
                    always @(posedge clk) begin
                        prod_m[ci] <= pk0[ci] * wt;
                        prod[ci]   <= prod_m[ci];
                    end

                    wire signed [15:0] p0 = prod[ci][15:0];
                    wire signed [PROD_W-16-1:0] p1_raw = $signed(prod[ci]) >>> 16;
                    wire signed [15:0] p1 = p1_raw[15:0] + (p0[15] ? 16'sd1 : 16'sd0);
                    always @(posedge clk) begin
                        pa[ci] <= {{(ACC_W-16){p0[15]}}, p0};
                        pb[ci] <= {{(ACC_W-16){p1[15]}}, p1};
                    end
                end else begin : G_LUT
                    wire signed [7:0] x0 = xa0[ci*8 +: 8];
                    wire signed [7:0] x1 = xb0[ci*8 +: 8];
                    (* use_dsp = "no" *) reg signed [15:0] m0, m1;
                    reg signed [15:0] q0, q1;
                    always @(posedge clk) begin
                        m0 <= x0 * wt;
                        m1 <= x1 * wt;
                        q0 <= m0;
                        q1 <= m1;
                        pa[ci] <= {{(ACC_W-16){q0[15]}}, q0};
                        pb[ci] <= {{(ACC_W-16){q1[15]}}, q1};
                    end
                end
            end

            // ---------- stages 4..3+TL: registered balanced adder trees ----------
            reg signed [ACC_W-1:0] ta [0:TL][0:P_CI-1];
            reg signed [ACC_W-1:0] tb [0:TL][0:P_CI-1];
            for (gn = 0; gn < P_CI; gn = gn + 1) begin : GEN_L0
                always @(*) begin
                    ta[0][gn] = pa[gn];
                    tb[0][gn] = pb[gn];
                end
            end
            // level gl holds sums of 2^gl 16-bit products: 16+gl bits are
            // enough, so each adder is only 17+gl bits wide and the result
            // is sign-extended to ACC_W (the extension flops are copies of
            // one sign flop and merge). The full-width 32-bit trees were
            // ~6,800 LUT more (2026-10-08 area cut).
            for (gl = 0; gl < TL; gl = gl + 1) begin : GEN_LVL
                localparam integer TW = 16 + gl;
                for (gn = 0; gn < (P_CI >> (gl+1)); gn = gn + 1) begin : GEN_NODE
                    wire signed [TW:0] sa = $signed(ta[gl][2*gn][TW-1:0]) + $signed(ta[gl][2*gn+1][TW-1:0]);
                    wire signed [TW:0] sb = $signed(tb[gl][2*gn][TW-1:0]) + $signed(tb[gl][2*gn+1][TW-1:0]);
                    always @(posedge clk) begin
                        ta[gl+1][gn] <= {{(ACC_W-TW-1){sa[TW]}}, sa};
                        tb[gl+1][gn] <= {{(ACC_W-TW-1){sb[TW]}}, sb};
                    end
                end
            end

            // ---------- accumulate ----------
            reg signed [ACC_W-1:0] acc_a, acc_b;
            always @(posedge clk) begin
                if (tv) begin
                    acc_a <= tf ? ta[TL][0] : acc_a + ta[TL][0];
                    acc_b <= tf ? tb[TL][0] : acc_b + tb[TL][0];
                end
            end
            assign res_a[co*ACC_W +: ACC_W] = acc_a;
            assign res_b[co*ACC_W +: ACC_W] = acc_b;
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) res_valid <= 1'b0;
        else     res_valid <= tv & tl;
    end
endmodule
