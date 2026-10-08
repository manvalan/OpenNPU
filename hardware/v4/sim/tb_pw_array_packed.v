// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- isolated test for pw_array_packed.v. Independent golden:
// plain integer dot products per (column, position A/B) over the beats
// of each accumulation group. Random group lengths (1..6 ci tiles),
// random bubbles between beats, back-to-back groups with no gap, and
// extreme-value groups (all -128, mixed -128/127). Results must come
// out in order, exactly one per group.
// ============================================================
module tb;
    localparam P_CI  = `ifdef TB_PCI `TB_PCI `else 4 `endif;
    localparam P_CO  = `ifdef TB_PCO `TB_PCO `else 3 `endif;
    localparam ACC_W = 32;
    localparam NDSP  = `ifdef TB_NDSP `TB_NDSP `else P_CO `endif;
    localparam NGRP  = 3000;
    localparam QMAX  = 4096;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst;

    reg in_valid, in_first, in_last;
    reg signed [8*P_CI-1:0] xa, xb;
    reg signed [8*P_CI*P_CO-1:0] w;
    wire res_valid;
    wire signed [ACC_W*P_CO-1:0] res_a, res_b;

    pw_array_packed #(.P_CI(P_CI), .P_CO(P_CO), .ACC_W(ACC_W), .N_DSP_COLS(NDSP)) dut (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_first(in_first), .in_last(in_last),
        .xa(xa), .xb(xb), .w(w),
        .res_valid(res_valid), .res_a(res_a), .res_b(res_b)
    );

    // expected results queue
    reg signed [ACC_W-1:0] exp_a [0:QMAX-1][0:P_CO-1];
    reg signed [ACC_W-1:0] exp_b [0:QMAX-1][0:P_CO-1];
    integer q_wr, q_rd, errors, checked;

    integer k;
    always @(posedge clk) begin
        if (!rst && res_valid) begin
            if (q_rd >= q_wr) begin
                errors = errors + 1;
                $display("FAIL: unexpected result (rd=%0d wr=%0d)", q_rd, q_wr);
            end else begin
                for (k = 0; k < P_CO; k = k + 1) begin
                    if (res_a[k*ACC_W +: ACC_W] !== exp_a[q_rd % QMAX][k] ||
                        res_b[k*ACC_W +: ACC_W] !== exp_b[q_rd % QMAX][k]) begin
                        errors = errors + 1;
                        if (errors < 20)
                            $display("FAIL grp %0d col %0d: got A=%0d B=%0d exp A=%0d B=%0d", q_rd, k,
                                     res_a[k*ACC_W +: ACC_W], res_b[k*ACC_W +: ACC_W],
                                     exp_a[q_rd % QMAX][k], exp_b[q_rd % QMAX][k]);
                    end
                end
                checked = checked + 1;
                q_rd = q_rd + 1;
            end
        end
    end

    integer g, t, nt, ci, co, mode;
    reg signed [ACC_W-1:0] sa [0:P_CO-1];
    reg signed [ACC_W-1:0] sb [0:P_CO-1];
    reg signed [7:0] va, vb, vw;
    integer bubble_pct, wdg;

    function automatic signed [7:0] rnd8(input integer m);
        begin
            case (m)
                1: rnd8 = -128;
                2: rnd8 = ($random & 1) ? -128 : 127;
                default: rnd8 = $random;
            endcase
        end
    endfunction

    initial begin
        errors = 0; checked = 0; q_wr = 0; q_rd = 0;
        rst = 1; in_valid = 0; in_first = 0; in_last = 0; xa = 0; xb = 0; w = 0;
        repeat (4) @(posedge clk);
        @(negedge clk) rst = 0;

        for (g = 0; g < NGRP; g = g + 1) begin
            nt = 1 + ($random & 32'h7fffffff) % 6;
            mode = (g % 17 == 5) ? 1 : ((g % 13 == 7) ? 2 : 0);
            bubble_pct = (g < NGRP/3) ? 0 : ((g < 2*NGRP/3) ? 25 : 60);
            for (co = 0; co < P_CO; co = co + 1) begin sa[co] = 0; sb[co] = 0; end
            for (t = 0; t < nt; t = t + 1) begin
                // optional bubbles before the beat
                while ((($random & 127) < bubble_pct)) begin
                    in_valid <= 0;
                    @(negedge clk);
                end
                for (ci = 0; ci < P_CI; ci = ci + 1) begin
                    va = rnd8(mode); vb = rnd8(mode);
                    xa[ci*8 +: 8] <= va; xb[ci*8 +: 8] <= vb;
                    for (co = 0; co < P_CO; co = co + 1) begin
                        vw = rnd8(mode);
                        w[(co*P_CI + ci)*8 +: 8] <= vw;
                        sa[co] = sa[co] + va * vw;
                        sb[co] = sb[co] + vb * vw;
                    end
                end
                in_valid <= 1;
                in_first <= (t == 0);
                in_last  <= (t == nt-1);
                @(negedge clk);
            end
            for (co = 0; co < P_CO; co = co + 1) begin
                exp_a[q_wr % QMAX][co] = sa[co];
                exp_b[q_wr % QMAX][co] = sb[co];
            end
            q_wr = q_wr + 1;
        end
        in_valid <= 0;
        wdg = 0;
        while (q_rd < q_wr && wdg < 1000) begin @(negedge clk); wdg = wdg + 1; end
        if (q_rd != q_wr) begin
            errors = errors + 1;
            $display("FAIL: %0d results received, %0d expected", q_rd, q_wr);
        end
        $display("=== %0d/%0d groups checked (P_CI=%0d P_CO=%0d NDSP=%0d, %0d values each), %0d errors ===",
                 checked, NGRP, P_CI, P_CO, NDSP, 2*P_CO, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_pw_array_packed)");
        $finish;
    end
endmodule
