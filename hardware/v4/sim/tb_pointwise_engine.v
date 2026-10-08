// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- isolated correctness test for
// pointwise_engine.v. Golden model: independent direct multiply-
// accumulate + clamp (not a copy of the RTL's own bit-trick
// saturation), including deliberately adversarial edge cases at the
// DW_WIDTH=20 accumulator's own extremes (the exact class that found
// a real bug in winograd_f23_output_stage.v earlier this session).
// ============================================================
module tb;
    localparam CIN = 8;
    localparam COUT = 5;
    localparam DW_WIDTH = 20;

    reg signed [DW_WIDTH*CIN-1:0] dw_flat;
    reg signed [8*CIN*COUT-1:0]   wp_flat;
    reg signed [8*COUT-1:0]       bias_flat;
    reg [1:0] activation;
    wire signed [8*COUT-1:0] y_flat;

    pointwise_engine #(.CIN(CIN), .COUT(COUT), .DW_WIDTH(DW_WIDTH)) dut (
        .dw_flat(dw_flat), .wp_flat(wp_flat), .bias_flat(bias_flat), .activation(activation),
        .y_flat(y_flat)
    );

    reg signed [DW_WIDTH-1:0] dw [0:CIN-1];
    reg signed [7:0] wp [0:COUT-1][0:CIN-1];
    reg signed [7:0] bias [0:COUT-1];

    integer ci, co;
    task automatic pack; begin
        for (ci = 0; ci < CIN; ci = ci + 1) dw_flat[ci*DW_WIDTH +: DW_WIDTH] = dw[ci];
        for (co = 0; co < COUT; co = co + 1) begin
            bias_flat[co*8 +: 8] = bias[co];
            for (ci = 0; ci < CIN; ci = ci + 1)
                wp_flat[(co*CIN+ci)*8 +: 8] = wp[co][ci];
        end
    end endtask

    function automatic signed [7:0] golden(input integer o);
        integer k;
        reg signed [63:0] acc, wide, v;
        begin
            acc = 0;
            for (k = 0; k < CIN; k = k + 1) acc = acc + dw[k]*wp[o][k];
            wide = acc + bias[o];
            if (activation == 2'd0) begin
                if (wide > 127) v = 127; else if (wide < -128) v = -128; else v = wide;
            end else begin
                if (wide <= 0) v = 0; else if (wide > 127) v = 127; else v = wide;
            end
            golden = v[7:0];
        end
    endfunction

    integer errors, tests, k;
    reg signed [7:0] got, exp;

    task automatic check_all(input [200:0] label);
        begin
            pack; #1;
            for (co = 0; co < COUT; co = co + 1) begin
                tests = tests + 1;
                got = y_flat[co*8 +: 8];
                exp = golden(co);
                if (got !== exp) begin
                    errors = errors + 1;
                    $display("FAIL [%0s] co=%0d: got=%0d expected=%0d", label, co, got, exp);
                end
            end
        end
    endtask

    initial begin
        errors = 0; tests = 0;

        // edge: max DW_WIDTH magnitude values (as if fed from a
        // real depthwise result at its own extreme) x max weight
        for (ci=0;ci<CIN;ci=ci+1) dw[ci] = {1'b0,{(DW_WIDTH-1){1'b1}}};
        for (co=0;co<COUT;co=co+1) begin bias[co]=8'sd127; for(ci=0;ci<CIN;ci=ci+1) wp[co][ci]=8'sd127; end
        activation = 2'd0; check_all("none-max-pos");
        activation = 2'd1; check_all("relu-max-pos");

        for (ci=0;ci<CIN;ci=ci+1) dw[ci] = {1'b1,{(DW_WIDTH-1){1'b0}}};
        for (co=0;co<COUT;co=co+1) begin bias[co]=-8'sd128; for(ci=0;ci<CIN;ci=ci+1) wp[co][ci]=-8'sd128; end
        activation = 2'd0; check_all("none-max-neg");
        activation = 2'd1; check_all("relu-max-neg");

        // bias pushing a borderline sum across the clamp boundary
        for (ci=0;ci<CIN;ci=ci+1) dw[ci]=20'sd0;
        for (co=0;co<COUT;co=co+1) begin for(ci=0;ci<CIN;ci=ci+1) wp[co][ci]=8'sd0; end
        dw[0] = 20'sd1;
        for (co=0;co<COUT;co=co+1) wp[co][0] = 8'sd120;
        for (co=0;co<COUT;co=co+1) bias[co] = 8'sd10;
        activation = 2'd0; check_all("none-bias-push-over");
        for (co=0;co<COUT;co=co+1) wp[co][0] = -8'sd120;
        for (co=0;co<COUT;co=co+1) bias[co] = -8'sd10;
        activation = 2'd0; check_all("none-bias-push-under");

        for (k = 0; k < 3000; k = k + 1) begin
            for (ci=0;ci<CIN;ci=ci+1) dw[ci] = {$random} % (1<<DW_WIDTH);
            for (co=0;co<COUT;co=co+1) begin
                bias[co] = $random;
                for (ci=0;ci<CIN;ci=ci+1) wp[co][ci] = $random;
            end
            activation = $random % 2;
            check_all("random");
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_pointwise_engine, CIN=%0d COUT=%0d)", CIN, COUT);
        $finish;
    end
endmodule
