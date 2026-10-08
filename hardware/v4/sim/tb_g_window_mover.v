// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- isolated correctness test for
// g_window_mover.v. Memory content is DETERMINISTIC and uniquely
// decodable (value = row*16 + col*2 + ch, fits INT8 non-negative
// range for W,H<=8, CIN<=2) rather than random -- for a control/
// addressing-logic test, an immediately-decodable value makes any
// misindexing failure obvious from the mismatch itself, which
// matters more here than raw value-range stress coverage (already
// covered separately for the arithmetic cores).
//
// Per this project's own standing testbench discipline: nonblocking-
// safe stimulus (posedge-driven, no tight back-to-back re-triggering
// here so risk is low regardless, but keeping the convention), and a
// real cycle-counted watchdog.
// ============================================================
module tb;
    localparam W   = 8;
    localparam H   = 8;
    localparam CIN = 2;
    localparam ROWBYTES = W*CIN;
    localparam ADDRW = $clog2(W*H*CIN);

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst;

    reg  [ADDRW-1:0] mem_addr;
    wire signed [7:0] mem_rdata;
    reg  start;

    wire tile_valid;
    wire [7:0] out_row, out_col;
    wire signed [8*16*CIN-1:0] d_flat;
    wire busy, done;

    g_window_mover #(.W(W), .H(H), .CIN(CIN)) dut (
        .clk(clk), .rst(rst), .start(start),
        .mem_addr(mem_addr), .mem_rdata(mem_rdata),
        .tile_valid(tile_valid), .out_row(out_row), .out_col(out_col), .d_flat(d_flat),
        .busy(busy), .done(done)
    );

    // ---- deterministic, uniquely-decodable feature map memory ----
    reg signed [7:0] mem [0:W*H*CIN-1];
    integer mi, mrow, mcol, mch;
    initial begin
        for (mrow = 0; mrow < H; mrow = mrow + 1)
            for (mcol = 0; mcol < W; mcol = mcol + 1)
                for (mch = 0; mch < CIN; mch = mch + 1)
                    mem[mrow*ROWBYTES + mcol*CIN + mch] = mrow*16 + mcol*2 + mch;
    end
    assign mem_rdata = mem[mem_addr];

    // ---- golden expected-tile check, decoded directly from
    // (row_top,col_top) via the SAME formula the memory was filled
    // with -- independent of g_window_mover's own internal indexing. ----
    integer errors, tests;
    integer exp_bands, exp_cols_per_band, exp_total_tiles;
    integer got_tiles;
    integer exp_seq_row, exp_seq_col;

    function automatic signed [7:0] expected_val(input integer r, input integer c, input integer ch);
        begin
            expected_val = r*16 + c*2 + ch;
        end
    endfunction

    task automatic check_tile;
        integer tr, tc, tch;
        reg signed [7:0] got, exp;
        begin
            tests = tests + 1;
            got_tiles = got_tiles + 1;
            for (tch = 0; tch < CIN; tch = tch + 1) begin
                for (tr = 0; tr < 4; tr = tr + 1) begin
                    for (tc = 0; tc < 4; tc = tc + 1) begin
                        got = d_flat[tch*128 + (tr*4+tc)*8 +: 8];
                        exp = expected_val(out_row+tr, out_col+tc, tch);
                        if (got !== exp) begin
                            errors = errors + 1;
                            $display("FAIL tile(row=%0d,col=%0d) ch=%0d tr=%0d tc=%0d: got=%0d expected=%0d",
                                      out_row, out_col, tch, tr, tc, got, exp);
                        end
                    end
                end
            end
            // also check the tile arrives at the CORRECT (row,col)
            // position, in the expected raster order -- a wrong
            // out_row/out_col would otherwise still "look right" if
            // the memory pattern happened to alias, so check the
            // running expected sequence explicitly too.
            if (out_row !== exp_seq_row || out_col !== exp_seq_col) begin
                errors = errors + 1;
                $display("FAIL tile SEQUENCE: got (row=%0d,col=%0d) expected (row=%0d,col=%0d) at tile #%0d",
                          out_row, out_col, exp_seq_row, exp_seq_col, got_tiles);
            end
            if (exp_seq_col == (W-4)) begin
                exp_seq_col = 0;
                exp_seq_row = exp_seq_row + 2;
            end else begin
                exp_seq_col = exp_seq_col + 2;
            end
        end
    endtask

    integer wd;
    initial begin
        errors = 0; tests = 0; got_tiles = 0;
        exp_seq_row = 0; exp_seq_col = 0;
        exp_bands = ((H-4)/2) + 1;
        exp_cols_per_band = ((W-4)/2) + 1;
        exp_total_tiles = exp_bands * exp_cols_per_band;

        rst = 1; start = 0;
        repeat (5) @(posedge clk);
        rst = 0;
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        wd = 0;
        while (!done && wd < 100000) begin
            @(posedge clk);
            if (tile_valid) check_tile;
            wd = wd + 1;
        end

        if (wd >= 100000) begin
            $display("FAIL: WATCHDOG TIMEOUT -- g_window_mover never asserted done");
            errors = errors + 1;
        end

        tests = tests + 1;
        if (got_tiles !== exp_total_tiles) begin
            errors = errors + 1;
            $display("FAIL: expected %0d total tiles, got %0d", exp_total_tiles, got_tiles);
        end else begin
            $display("PASS: correct total tile count (%0d)", got_tiles);
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_g_window_mover, W=%0d H=%0d CIN=%0d)", W, H, CIN);
        $finish;
    end
endmodule
