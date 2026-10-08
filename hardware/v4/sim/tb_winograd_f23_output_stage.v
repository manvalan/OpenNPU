// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- isolated correctness test for
// winograd_f23_output_stage.v. Golden model is a plain, obviously-
// correct compare/clamp -- deliberately NOT a copy of the RTL's own
// bit-trick saturation logic, so this is a real independent cross-
// check, not the same bug reflected twice.
// ============================================================
module tb;
    localparam DATA_WIDTH = 8;
    localparam ACC_WIDTH  = 48;

    reg  signed [ACC_WIDTH-1:0]  acc0, acc1, acc2, acc3;
    reg  signed [DATA_WIDTH-1:0] bias;
    reg  [1:0]                   activation;
    wire signed [DATA_WIDTH-1:0] y0, y1, y2, y3;

    winograd_f23_output_stage #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) dut (
        .acc0(acc0), .acc1(acc1), .acc2(acc2), .acc3(acc3),
        .bias(bias), .activation(activation),
        .y0(y0), .y1(y1), .y2(y2), .y3(y3)
    );

    function automatic signed [DATA_WIDTH-1:0] golden_sat(
        input signed [ACC_WIDTH-1:0] acc, input signed [DATA_WIDTH-1:0] b, input [1:0] act
    );
        reg signed [ACC_WIDTH+8:0] wide;
        reg signed [ACC_WIDTH+8:0] v;
        begin
            wide = acc + b;
            if (act == 2'd0) begin // ACT_NONE
                if (wide > 127)       v = 127;
                else if (wide < -128) v = -128;
                else                  v = wide;
            end else begin // ACT_RELU
                if (wide <= 0)        v = 0;
                else if (wide > 127)  v = 127;
                else                  v = wide;
            end
            golden_sat = v[DATA_WIDTH-1:0];
        end
    endfunction

    integer errors, tests;
    reg signed [DATA_WIDTH-1:0] g0, g1, g2, g3;

    task automatic run_one(input [200:0] label);
        begin
            #1;
            g0 = golden_sat(acc0, bias, activation);
            g1 = golden_sat(acc1, bias, activation);
            g2 = golden_sat(acc2, bias, activation);
            g3 = golden_sat(acc3, bias, activation);
            tests = tests + 1;
            if (y0 !== g0 || y1 !== g1 || y2 !== g2 || y3 !== g3) begin
                errors = errors + 1;
                $display("FAIL [%0s]: acc=(%0d,%0d,%0d,%0d) bias=%0d act=%0d got=(%0d,%0d,%0d,%0d) expected=(%0d,%0d,%0d,%0d)",
                          label, acc0, acc1, acc2, acc3, bias, activation, y0,y1,y2,y3, g0,g1,g2,g3);
            end
        end
    endtask

    integer k;
    initial begin
        errors = 0; tests = 0;

        // ---- boundary edge cases: exactly at/around the +-127/-128 clamp ----
        acc0=48'sd127;  acc1=48'sd128;  acc2=48'sd126;  acc3=48'sd129;  bias=8'sd0; activation=2'd0; run_one("none-boundary-pos");
        acc0=-48'sd128; acc1=-48'sd129; acc2=-48'sd127; acc3=-48'sd200; bias=8'sd0; activation=2'd0; run_one("none-boundary-neg");
        acc0=48'sd0;    acc1=-48'sd1;   acc2=48'sd1;    acc3=-48'sd200; bias=8'sd0; activation=2'd1; run_one("relu-boundary-zero");
        acc0=48'sd127;  acc1=48'sd128;  acc2=48'sd5000; acc3=-48'sd5000; bias=8'sd0; activation=2'd1; run_one("relu-boundary-pos");
        // bias pushing a value across the boundary in both directions
        acc0=48'sd120;  acc1=48'sd120;  acc2=48'sd120;  acc3=48'sd120;  bias=8'sd10; activation=2'd0; run_one("none-bias-push-over");
        acc0=-48'sd120; acc1=-48'sd120; acc2=-48'sd120; acc3=-48'sd120; bias=-8'sd10; activation=2'd0; run_one("none-bias-push-under");
        acc0=-48'sd5;   acc1=-48'sd5;   acc2=-48'sd5;   acc3=-48'sd5;   bias=8'sd10; activation=2'd1; run_one("relu-bias-push-positive");
        // widest possible magnitude (stress the ACC_WIDTH=48 range itself)
        acc0={1'b0,{47{1'b1}}}; acc1={1'b1,{47{1'b0}}}; acc2=48'sd0; acc3=48'sd0; bias=8'sd127; activation=2'd0; run_one("none-extreme-acc-width");
        acc0={1'b0,{47{1'b1}}}; acc1={1'b1,{47{1'b0}}}; acc2=48'sd0; acc3=48'sd0; bias=-8'sd128; activation=2'd1; run_one("relu-extreme-acc-width");

        // ---- random trials, both activation modes, across the full
        // ACC_WIDTH range (not just small values near the boundary) ----
        for (k = 0; k < 3000; k = k + 1) begin
            acc0 = {$random, $random};
            acc1 = {$random, $random};
            acc2 = {$random, $random};
            acc3 = {$random, $random};
            bias = $random;
            activation = $random % 2;
            run_one("random");
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_winograd_f23_output_stage, bit-exact vs independent golden clamp)");
        $finish;
    end
endmodule
