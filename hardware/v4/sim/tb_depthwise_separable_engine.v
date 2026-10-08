// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- first full end-to-end test of
// "G-esteso": g_window_mover_depthwise.v -> pointwise_engine.v,
// fused, no memory round-trip. Golden model: independent depthwise
// (per channel) then pointwise (across channels) convolution,
// computed directly from the same real math as
// hardware/v4/docs/DEPTHWISE_SEPARABLE_PIPELINE.md §2 -- not a
// closed-form single-pass derivation, two honest sequential stages,
// mirroring the DUT's own real pipeline.
// ============================================================
module tb;
    localparam W    = 10;
    localparam H    = 9;
    localparam CIN  = 4;
    localparam COUT = 3;
    localparam ROWBYTES = W*CIN;
    localparam ADDRW = $clog2(W*H*CIN);
    localparam OUT_W = W-2, OUT_H = H-2;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst, start;

    wire [ADDRW-1:0] mem_addr;
    wire signed [7:0] mem_rdata;
    reg signed [7:0] fmap [0:W*H*CIN-1];
    assign mem_rdata = fmap[mem_addr];

    reg signed [7:0] wd [0:CIN-1][0:8];
    reg signed [72*CIN-1:0] wd_flat;
    reg signed [7:0] wp [0:COUT-1][0:CIN-1];
    reg signed [8*CIN*COUT-1:0] wp_flat;
    reg signed [7:0] bias [0:COUT-1];
    reg signed [8*COUT-1:0] bias_flat;
    reg [1:0] activation;

    wire out_valid;
    wire [7:0] out_row, out_col;
    wire signed [8*COUT-1:0] y_flat;
    wire busy, done;

    depthwise_separable_engine #(.W(W), .H(H), .CIN(CIN), .COUT(COUT)) dut (
        .clk(clk), .rst(rst), .start(start),
        .mem_addr(mem_addr), .mem_rdata(mem_rdata),
        .wd_flat(wd_flat), .wp_flat(wp_flat), .bias_flat(bias_flat), .activation(activation),
        .out_valid(out_valid), .out_row(out_row), .out_col(out_col), .y_flat(y_flat),
        .busy(busy), .done(done)
    );

    integer c, i, co;
    task automatic pack_all; begin
        for (c = 0; c < CIN; c = c + 1)
            for (i = 0; i < 9; i = i + 1)
                wd_flat[c*72 + i*8 +: 8] = wd[c][i];
        for (co = 0; co < COUT; co = co + 1) begin
            bias_flat[co*8 +: 8] = bias[co];
            for (c = 0; c < CIN; c = c + 1)
                wp_flat[(co*CIN+c)*8 +: 8] = wp[co][c];
        end
    end endtask

    function automatic signed [19:0] golden_dw(input integer row, input integer col, input integer ch);
        integer kr, kc;
        reg signed [19:0] acc;
        begin
            acc = 0;
            for (kr = 0; kr < 3; kr = kr + 1)
                for (kc = 0; kc < 3; kc = kc + 1)
                    acc = acc + fmap[(row+kr)*ROWBYTES + (col+kc)*CIN + ch] * wd[ch][kr*3+kc];
            golden_dw = acc;
        end
    endfunction

    function automatic signed [7:0] golden_final(input integer row, input integer col, input integer o);
        integer k;
        reg signed [63:0] acc, wide, v;
        begin
            acc = 0;
            for (k = 0; k < CIN; k = k + 1) acc = acc + golden_dw(row,col,k) * wp[o][k];
            wide = acc + bias[o];
            if (activation == 2'd0) begin
                if (wide > 127) v = 127; else if (wide < -128) v = -128; else v = wide;
            end else begin
                if (wide <= 0) v = 0; else if (wide > 127) v = 127; else v = wide;
            end
            golden_final = v[7:0];
        end
    endfunction

    integer errors, tests, got_tiles, exp_seq_row, exp_seq_col;

    task automatic check_pos;
        reg signed [7:0] got, exp;
        begin
            tests = tests + 1;
            got_tiles = got_tiles + 1;
            for (co = 0; co < COUT; co = co + 1) begin
                got = y_flat[co*8 +: 8];
                exp = golden_final(out_row, out_col, co);
                if (got !== exp) begin
                    errors = errors + 1;
                    $display("FAIL pos(row=%0d,col=%0d) co=%0d: got=%0d expected=%0d", out_row, out_col, co, got, exp);
                end
            end
            if (out_row !== exp_seq_row || out_col !== exp_seq_col) begin
                errors = errors + 1;
                $display("FAIL SEQUENCE #%0d: got (row=%0d,col=%0d) expected (row=%0d,col=%0d)",
                          got_tiles, out_row, out_col, exp_seq_row, exp_seq_col);
            end
            if (exp_seq_col == (W-3)) begin exp_seq_col=0; exp_seq_row=exp_seq_row+1; end
            else exp_seq_col = exp_seq_col + 1;
        end
    endtask

    integer wdg, k, exp_total;
    initial begin
        errors = 0; tests = 0;
        exp_total = OUT_W*OUT_H;

        for (k = 0; k < 12; k = k + 1) begin
            for (i = 0; i < W*H*CIN; i = i + 1) fmap[i] = $random;
            for (c = 0; c < CIN; c = c + 1)
                for (i = 0; i < 9; i = i + 1) wd[c][i] = $random;
            for (co = 0; co < COUT; co = co + 1) begin
                bias[co] = $random;
                for (c = 0; c < CIN; c = c + 1) wp[co][c] = $random;
            end
            activation = $random % 2;
            pack_all;

            got_tiles = 0; exp_seq_row = 0; exp_seq_col = 0;
            rst = 1; start = 0;
            repeat (5) @(posedge clk);
            rst = 0;
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;

            wdg = 0;
            while (!done && wdg < 200000) begin
                @(posedge clk);
                if (out_valid) check_pos;
                wdg = wdg + 1;
            end
            if (wdg >= 200000) begin errors=errors+1; tests=tests+1; $display("FAIL: watchdog iter %0d", k); end
            tests = tests + 1;
            if (got_tiles !== exp_total) begin
                errors = errors + 1;
                $display("FAIL: iter %0d expected %0d positions, got %0d", k, exp_total, got_tiles);
            end
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_depthwise_separable_engine, full mover+depthwise+pointwise fusion, %0d runs)", 12);
        $finish;
    end
endmodule
