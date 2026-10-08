// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- isolated correctness test for
// winograd_f23_multichan.v (CIN parallel channels summed). Same
// discipline as tb_winograd_f23_core.v: cross-check bit-exact
// against an independent golden direct-conv model that ALSO sums
// over Cin, not trusting the accumulation wiring by inspection.
// ============================================================
module tb;
    localparam CIN = 4;

    reg signed [7:0]  d [0:CIN-1][0:15];  // d[ci][4*r+c]
    reg signed [7:0]  g [0:CIN-1][0:8];   // g[ci][3*r+c]
    reg signed [15:0] u [0:CIN-1][0:15];  // u[ci][4*r+c]

    reg signed [8*16*CIN-1:0]  d_flat;
    reg signed [16*16*CIN-1:0] u_flat;

    wire signed [47:0] y0, y1, y2, y3;

    winograd_f23_multichan #(.CIN(CIN)) dut (
        .d_flat(d_flat), .u_flat(u_flat),
        .y0(y0), .y1(y1), .y2(y2), .y3(y3)
    );

    integer ci, vi;
    task automatic pack_buses;
        begin
            for (ci = 0; ci < CIN; ci = ci + 1) begin
                for (vi = 0; vi < 16; vi = vi + 1)
                    d_flat[ci*128 + vi*8 +: 8] = d[ci][vi];
                for (vi = 0; vi < 16; vi = vi + 1)
                    u_flat[ci*256 + vi*16 +: 16] = u[ci][vi];
            end
        end
    endtask

    task automatic compute_kernel_transform(input integer c);
        integer col, i;
        reg signed [19:0] c0, c1, c2;
        reg signed [19:0] u1row [0:3][0:2];
        begin
            for (col = 0; col < 3; col = col + 1) begin
                c0 = g[c][0*3+col];
                c1 = g[c][1*3+col];
                c2 = g[c][2*3+col];
                u1row[0][col] = 2*c0;
                u1row[1][col] = c0 + c1 + c2;
                u1row[2][col] = c0 - c1 + c2;
                u1row[3][col] = 2*c2;
            end
            for (i = 0; i < 4; i = i + 1) begin
                u[c][i*4+0] = 2*u1row[i][0];
                u[c][i*4+1] = u1row[i][0] + u1row[i][1] + u1row[i][2];
                u[c][i*4+2] = u1row[i][0] - u1row[i][1] + u1row[i][2];
                u[c][i*4+3] = 2*u1row[i][2];
            end
        end
    endtask

    function automatic signed [47:0] golden_conv(input integer or_, input integer oc);
        integer kr, kc, c;
        reg signed [47:0] acc;
        begin
            acc = 0;
            for (c = 0; c < CIN; c = c + 1)
                for (kr = 0; kr < 3; kr = kr + 1)
                    for (kc = 0; kc < 3; kc = kc + 1)
                        acc = acc + d[c][(or_+kr)*4 + (oc+kc)] * g[c][kr*3+kc];
            golden_conv = acc;
        end
    endfunction

    integer errors, tests;
    reg signed [47:0] gy0, gy1, gy2, gy3;

    task automatic run_one(input [200:0] label);
        integer c;
        begin
            for (c = 0; c < CIN; c = c + 1) compute_kernel_transform(c);
            pack_buses;
            #1;
            gy0 = golden_conv(0,0);
            gy1 = golden_conv(0,1);
            gy2 = golden_conv(1,0);
            gy3 = golden_conv(1,1);
            tests = tests + 1;
            if (y0 !== gy0 || y1 !== gy1 || y2 !== gy2 || y3 !== gy3) begin
                errors = errors + 1;
                $display("FAIL [%0s]: got (%0d,%0d,%0d,%0d) expected (%0d,%0d,%0d,%0d)",
                          label, y0, y1, y2, y3, gy0, gy1, gy2, gy3);
            end
        end
    endtask

    integer i, k, c2;
    initial begin
        errors = 0; tests = 0;

        // ---- edge cases ----
        for (c2 = 0; c2 < CIN; c2 = c2 + 1) begin
            for (i = 0; i < 16; i = i + 1) d[c2][i] = 8'sd0;
            for (i = 0; i < 9; i = i + 1)  g[c2][i] = 8'sd0;
        end
        run_one("all-zero");

        for (c2 = 0; c2 < CIN; c2 = c2 + 1) begin
            for (i = 0; i < 16; i = i + 1) d[c2][i] = 8'sd127;
            for (i = 0; i < 9; i = i + 1)  g[c2][i] = 8'sd127;
        end
        run_one("all-max-positive-all-channels");

        for (c2 = 0; c2 < CIN; c2 = c2 + 1) begin
            for (i = 0; i < 16; i = i + 1) d[c2][i] = -8'sd128;
            for (i = 0; i < 9; i = i + 1)  g[c2][i] = -8'sd128;
        end
        run_one("all-min-negative-all-channels");

        // alternate extreme signs channel-by-channel -- stresses the
        // cross-channel accumulator's own sign handling, not just a
        // single channel's internal transform.
        for (c2 = 0; c2 < CIN; c2 = c2 + 1) begin
            for (i = 0; i < 16; i = i + 1) d[c2][i] = (c2 % 2 == 0) ? 8'sd127 : -8'sd128;
            for (i = 0; i < 9; i = i + 1)  g[c2][i] = (c2 % 2 == 0) ? -8'sd128 : 8'sd127;
        end
        run_one("alternating-extreme-channels");

        // ---- random trials ----
        for (k = 0; k < 2000; k = k + 1) begin
            for (c2 = 0; c2 < CIN; c2 = c2 + 1) begin
                for (i = 0; i < 16; i = i + 1) d[c2][i] = $random;
                for (i = 0; i < 9; i = i + 1)  g[c2][i] = $random;
            end
            run_one("random");
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_winograd_f23_multichan, CIN=%0d, bit-exact vs golden direct conv)", CIN);
        $finish;
    end
endmodule
