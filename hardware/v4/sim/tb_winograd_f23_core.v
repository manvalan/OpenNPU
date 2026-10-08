// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- isolated correctness test for
// winograd_f23_core.v. Cross-checks the RTL's Winograd F(2x2,3x3)
// result, bit-exact, against a fully independent GOLDEN model that
// computes the same 2x2 output via brute-force direct convolution
// (no Winograd math at all) -- deliberately not trusting the
// Winograd algebra (scale factors, transform matrices) by
// inspection alone, given this project's own real history of
// exactly this class of subtle arithmetic bug elsewhere.
//
// The kernel transform U' = (2G) g (2G)^T is computed HERE, in the
// testbench, standing in for the future real offline "compiler"
// tool (per this project's A/5 design: weights are synthesis-time
// constants, so this transform never needs to run in real hardware).
// ============================================================
module tb;
    reg signed [7:0] d [0:15];   // 4x4 input tile, row-major d[4*r+c]
    reg signed [7:0] g [0:8];    // 3x3 kernel, row-major g[3*r+c]
    reg signed [15:0] u [0:15];  // 4x4 transformed kernel, row-major

    wire signed [39:0] y0, y1, y2, y3;

    winograd_f23_core dut (
        .d0(d[0]),   .d1(d[1]),   .d2(d[2]),   .d3(d[3]),
        .d4(d[4]),   .d5(d[5]),   .d6(d[6]),   .d7(d[7]),
        .d8(d[8]),   .d9(d[9]),   .d10(d[10]), .d11(d[11]),
        .d12(d[12]), .d13(d[13]), .d14(d[14]), .d15(d[15]),

        .u0(u[0]),   .u1(u[1]),   .u2(u[2]),   .u3(u[3]),
        .u4(u[4]),   .u5(u[5]),   .u6(u[6]),   .u7(u[7]),
        .u8(u[8]),   .u9(u[9]),   .u10(u[10]), .u11(u[11]),
        .u12(u[12]), .u13(u[13]), .u14(u[14]), .u15(u[15]),

        .y0(y0), .y1(y1), .y2(y2), .y3(y3)
    );

    // ---- offline "compiler" kernel transform: U' = (2G) g (2G)^T ----
    task automatic compute_kernel_transform;
        integer j;
        reg signed [19:0] u1_0, u1_1, u1_2, u1_3; // U1 = (2G) * g, per column j
        integer col;
        reg signed [19:0] c0, c1, c2; // g[0][col], g[1][col], g[2][col]
        reg signed [19:0] r0_0, r0_1, r0_2, r0_3; // U1 row 0 across cols, reused per row build
        reg signed [19:0] u1row [0:3][0:2]; // U1[i][j], i=0..3 rows, j=0..2 cols
        integer i;
        begin
            for (col = 0; col < 3; col = col + 1) begin
                c0 = g[0*3+col];
                c1 = g[1*3+col];
                c2 = g[2*3+col];
                u1row[0][col] = 2*c0;
                u1row[1][col] = c0 + c1 + c2;
                u1row[2][col] = c0 - c1 + c2;
                u1row[3][col] = 2*c2;
            end
            for (i = 0; i < 4; i = i + 1) begin
                u[i*4+0] = 2*u1row[i][0];
                u[i*4+1] = u1row[i][0] + u1row[i][1] + u1row[i][2];
                u[i*4+2] = u1row[i][0] - u1row[i][1] + u1row[i][2];
                u[i*4+3] = 2*u1row[i][2];
            end
        end
    endtask

    // ---- golden model: brute-force direct 3x3 convolution over the
    // 4x4 tile, producing the same 2x2 output region, completely
    // independent of the Winograd math above. ----
    function automatic signed [39:0] golden_conv(input integer or_, input integer oc);
        integer kr, kc;
        reg signed [39:0] acc;
        begin
            acc = 0;
            for (kr = 0; kr < 3; kr = kr + 1)
                for (kc = 0; kc < 3; kc = kc + 1)
                    acc = acc + d[(or_+kr)*4 + (oc+kc)] * g[kr*3+kc];
            golden_conv = acc;
        end
    endfunction

    integer errors, tests;
    reg signed [39:0] gy0, gy1, gy2, gy3;

    task automatic run_one(input [200:0] label);
        begin
            compute_kernel_transform;
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

    integer i, k;
    initial begin
        errors = 0; tests = 0;

        // ---- explicit edge cases first, small and inspectable ----
        for (i = 0; i < 16; i = i + 1) d[i] = 8'sd0;
        for (i = 0; i < 9; i = i + 1)  g[i] = 8'sd0;
        run_one("all-zero");

        for (i = 0; i < 16; i = i + 1) d[i] = 8'sd127;
        for (i = 0; i < 9; i = i + 1)  g[i] = 8'sd127;
        run_one("all-max-positive");

        for (i = 0; i < 16; i = i + 1) d[i] = -8'sd128;
        for (i = 0; i < 9; i = i + 1)  g[i] = -8'sd128;
        run_one("all-min-negative");

        for (i = 0; i < 16; i = i + 1) d[i] = -8'sd128;
        for (i = 0; i < 9; i = i + 1)  g[i] = 8'sd127;
        run_one("max-magnitude-opposite-signs");

        // checkerboard pattern -- stresses the +/- coefficient mix
        for (i = 0; i < 16; i = i + 1) d[i] = (i % 2 == 0) ? 8'sd127 : -8'sd128;
        for (i = 0; i < 9; i = i + 1)  g[i] = (i % 2 == 0) ? -8'sd128 : 8'sd127;
        run_one("checkerboard-extremes");

        // ---- random trials ----
        for (k = 0; k < 2000; k = k + 1) begin
            for (i = 0; i < 16; i = i + 1) d[i] = $random;
            for (i = 0; i < 9; i = i + 1)  g[i] = $random;
            run_one("random");
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_winograd_f23_core, bit-exact vs golden direct conv)");
        $finish;
    end
endmodule
