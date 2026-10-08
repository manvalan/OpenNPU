// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- isolated correctness test for
// g_window_mover_depthwise.v ("G-esteso"). Golden model: independent
// direct depthwise 3x3 conv, per channel, at every real output
// position -- checked against the DUT's own streamed
// (out_row,out_col,dw_flat) tuples, in order, with a full-coverage
// check (classic tiling-bug class).
// ============================================================
module tb;
    localparam W   = 10;
    localparam H   = 9;
    localparam CIN = 3;
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

    wire out_valid;
    wire [7:0] out_row, out_col;
    wire signed [20*CIN-1:0] dw_flat;
    wire busy, done;

    g_window_mover_depthwise #(.W(W), .H(H), .CIN(CIN)) dut (
        .clk(clk), .rst(rst), .start(start),
        .mem_addr(mem_addr), .mem_rdata(mem_rdata),
        .wd_flat(wd_flat),
        .out_valid(out_valid), .out_row(out_row), .out_col(out_col), .dw_flat(dw_flat),
        .busy(busy), .done(done)
    );

    integer c, i;
    task automatic pack_wd; begin
        for (c = 0; c < CIN; c = c + 1)
            for (i = 0; i < 9; i = i + 1)
                wd_flat[c*72 + i*8 +: 8] = wd[c][i];
    end endtask

    function automatic signed [19:0] golden(input integer row, input integer col, input integer ch);
        integer kr, kc;
        reg signed [19:0] acc;
        begin
            acc = 0;
            for (kr = 0; kr < 3; kr = kr + 1)
                for (kc = 0; kc < 3; kc = kc + 1)
                    acc = acc + fmap[(row+kr)*ROWBYTES + (col+kc)*CIN + ch] * wd[ch][kr*3+kc];
            golden = acc;
        end
    endfunction

    integer errors, tests, got_tiles;
    integer exp_seq_row, exp_seq_col;

    task automatic check_pos;
        reg signed [19:0] got, exp;
        begin
            tests = tests + 1;
            got_tiles = got_tiles + 1;
            for (c = 0; c < CIN; c = c + 1) begin
                got = dw_flat[c*20 +: 20];
                exp = golden(out_row, out_col, c);
                if (got !== exp) begin
                    errors = errors + 1;
                    $display("FAIL pos(row=%0d,col=%0d) ch=%0d: got=%0d expected=%0d", out_row, out_col, c, got, exp);
                end
            end
            if (out_row !== exp_seq_row || out_col !== exp_seq_col) begin
                errors = errors + 1;
                $display("FAIL SEQUENCE at #%0d: got (row=%0d,col=%0d) expected (row=%0d,col=%0d)",
                          got_tiles, out_row, out_col, exp_seq_row, exp_seq_col);
            end
            if (exp_seq_col == (W-3)) begin
                exp_seq_col = 0; exp_seq_row = exp_seq_row + 1;
            end else begin
                exp_seq_col = exp_seq_col + 1;
            end
        end
    endtask

    integer wd_iter, k;
    integer exp_total;
    initial begin
        errors = 0; tests = 0;
        exp_total = OUT_W*OUT_H;

        for (k = 0; k < 15; k = k + 1) begin
            for (i = 0; i < W*H*CIN; i = i + 1) fmap[i] = $random;
            for (c = 0; c < CIN; c = c + 1)
                for (i = 0; i < 9; i = i + 1) wd[c][i] = $random;
            pack_wd;

            got_tiles = 0; exp_seq_row = 0; exp_seq_col = 0;
            rst = 1; start = 0;
            repeat (5) @(posedge clk);
            rst = 0;
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;

            wd_iter = 0;
            while (!done && wd_iter < 100000) begin
                @(posedge clk);
                if (out_valid) check_pos;
                wd_iter = wd_iter + 1;
            end
            if (wd_iter >= 100000) begin
                errors = errors + 1; tests = tests + 1;
                $display("FAIL: watchdog timeout iter %0d", k);
            end
            tests = tests + 1;
            if (got_tiles !== exp_total) begin
                errors = errors + 1;
                $display("FAIL: iter %0d expected %0d positions, got %0d", k, exp_total, got_tiles);
            end
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_g_window_mover_depthwise, W=%0d H=%0d CIN=%0d, %0d runs)", W, H, CIN, 15);
        $finish;
    end
endmodule
