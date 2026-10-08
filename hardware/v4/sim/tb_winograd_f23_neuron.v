// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- isolated correctness test for the
// composed winograd_f23_neuron.v: full CIN-channel conv + bias +
// activation, golden model = independent direct-conv + independent
// clamp (not a copy of either RTL piece's own internal logic).
// ============================================================
module tb;
    localparam CIN        = 4;
    localparam DATA_WIDTH = 8;
    localparam ACC_WIDTH  = 48;

    reg signed [7:0]  d [0:CIN-1][0:15];
    reg signed [7:0]  g [0:CIN-1][0:8];
    reg signed [15:0] u [0:CIN-1][0:15];
    reg signed [7:0]  bias;
    reg [1:0]         activation;

    reg signed [8*16*CIN-1:0]  d_flat;
    reg signed [16*16*CIN-1:0] u_flat;

    wire signed [7:0] y0, y1, y2, y3;

    winograd_f23_neuron #(.CIN(CIN), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) dut (
        .d_flat(d_flat), .u_flat(u_flat),
        .bias(bias), .activation(activation),
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

    // ---- golden: independent direct conv, summed over Cin ----
    function automatic signed [63:0] golden_conv(input integer or_, input integer oc);
        integer kr, kc, c;
        reg signed [63:0] acc;
        begin
            acc = 0;
            for (c = 0; c < CIN; c = c + 1)
                for (kr = 0; kr < 3; kr = kr + 1)
                    for (kc = 0; kc < 3; kc = kc + 1)
                        acc = acc + d[c][(or_+kr)*4 + (oc+kc)] * g[c][kr*3+kc];
            golden_conv = acc;
        end
    endfunction

    // ---- golden: independent bias+activation+clamp ----
    function automatic signed [7:0] golden_sat(input signed [63:0] acc, input signed [7:0] b, input [1:0] act);
        reg signed [63:0] wide;
        reg signed [63:0] v;
        begin
            wide = acc + b;
            if (act == 2'd0) begin
                if (wide > 127)       v = 127;
                else if (wide < -128) v = -128;
                else                  v = wide;
            end else begin
                if (wide <= 0)        v = 0;
                else if (wide > 127)  v = 127;
                else                  v = wide;
            end
            golden_sat = v[7:0];
        end
    endfunction

    integer errors, tests;
    reg signed [7:0] g0, g1, g2, g3;

    task automatic run_one(input [200:0] label);
        integer c;
        begin
            for (c = 0; c < CIN; c = c + 1) compute_kernel_transform(c);
            pack_buses;
            #1;
            g0 = golden_sat(golden_conv(0,0), bias, activation);
            g1 = golden_sat(golden_conv(0,1), bias, activation);
            g2 = golden_sat(golden_conv(1,0), bias, activation);
            g3 = golden_sat(golden_conv(1,1), bias, activation);
            tests = tests + 1;
            if (y0 !== g0 || y1 !== g1 || y2 !== g2 || y3 !== g3) begin
                errors = errors + 1;
                $display("FAIL [%0s]: bias=%0d act=%0d got=(%0d,%0d,%0d,%0d) expected=(%0d,%0d,%0d,%0d)",
                          label, bias, activation, y0,y1,y2,y3, g0,g1,g2,g3);
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
        bias = 8'sd0; activation = 2'd0; run_one("all-zero-none");
        bias = 8'sd0; activation = 2'd1; run_one("all-zero-relu");

        for (c2 = 0; c2 < CIN; c2 = c2 + 1) begin
            for (i = 0; i < 16; i = i + 1) d[c2][i] = 8'sd127;
            for (i = 0; i < 9; i = i + 1)  g[c2][i] = 8'sd127;
        end
        bias = 8'sd127; activation = 2'd0; run_one("all-max-none");
        bias = -8'sd128; activation = 2'd1; run_one("all-max-relu-negbias");

        for (c2 = 0; c2 < CIN; c2 = c2 + 1) begin
            for (i = 0; i < 16; i = i + 1) d[c2][i] = -8'sd128;
            for (i = 0; i < 9; i = i + 1)  g[c2][i] = -8'sd128;
        end
        bias = 8'sd0; activation = 2'd0; run_one("all-min-none");
        bias = 8'sd0; activation = 2'd1; run_one("all-min-relu");

        // ---- random trials, both activation modes, random bias ----
        for (k = 0; k < 3000; k = k + 1) begin
            for (c2 = 0; c2 < CIN; c2 = c2 + 1) begin
                for (i = 0; i < 16; i = i + 1) d[c2][i] = $random;
                for (i = 0; i < 9; i = i + 1)  g[c2][i] = $random;
            end
            bias = $random;
            activation = $random % 2;
            run_one("random");
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_winograd_f23_neuron, CIN=%0d, full pipeline bit-exact vs golden)", CIN);
        $finish;
    end
endmodule
