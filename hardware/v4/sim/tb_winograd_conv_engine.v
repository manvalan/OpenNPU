// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- first end-to-end integration test:
// g_window_mover.v streaming directly into winograd_f23_neuron.v
// via winograd_conv_engine.v, over a WHOLE feature map. Golden
// model = independent direct convolution at every real output
// position, compared against the DUT's own streamed
// (out_row,out_col,y0..y3) tuples, in the order they arrive.
//
// This test exists specifically to catch integration/alignment
// bugs (e.g. the out_valid/y* one-cycle-misalignment bug already
// caught and fixed by inspection before this test even ran) that
// neither g_window_mover.v's own isolated test nor winograd_f23_
// neuron.v's own isolated test could ever see, since each tested
// its own piece alone.
// ============================================================
module tb;
    localparam W    = 8;
    localparam H    = 8;
    localparam CIN  = 2;
    localparam ROWBYTES = W*CIN;
    localparam ADDRW = $clog2(W*H*CIN);

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst, start;

    wire [ADDRW-1:0] mem_addr;
    wire signed [7:0] mem_rdata;

    reg signed [15:0] u_flat [0:CIN-1][0:15];
    reg signed [16*16*CIN-1:0] u_flat_bus;
    reg signed [7:0] bias;
    reg [1:0] activation;

    wire out_valid;
    wire [7:0] out_row, out_col;
    wire signed [7:0] y0, y1, y2, y3;
    wire busy, done;

    localparam OUT_W = W-2;
    localparam OUT_H = H-2;
    localparam OUTN  = OUT_W*OUT_H;
    wire we0, we1, we2, we3;
    wire [$clog2(OUTN)-1:0] waddr0, waddr1, waddr2, waddr3;
    wire signed [7:0] wdata0, wdata1, wdata2, wdata3;

    winograd_conv_engine #(.W(W), .H(H), .CIN(CIN)) dut (
        .clk(clk), .rst(rst), .start(start),
        .mem_addr(mem_addr), .mem_rdata(mem_rdata),
        .u_flat(u_flat_bus), .bias(bias), .activation(activation),
        .out_valid(out_valid), .out_row(out_row), .out_col(out_col),
        .y0(y0), .y1(y1), .y2(y2), .y3(y3),
        .we0(we0), .we1(we1), .we2(we2), .we3(we3),
        .waddr0(waddr0), .waddr1(waddr1), .waddr2(waddr2), .waddr3(waddr3),
        .wdata0(wdata0), .wdata1(wdata1), .wdata2(wdata2), .wdata3(wdata3),
        .busy(busy), .done(done)
    );

    // ---- real output feature map memory, written via the engine's
    // own writeback-address outputs (not just checked tile-by-tile
    // as before -- this proves the FULL image comes out right, not
    // just each tile in isolation). ----
    reg signed [7:0] outmap [0:OUTN-1];
    integer outmap_write_count [0:OUTN-1];
    always @(posedge clk) begin
        if (we0) begin outmap[waddr0] <= wdata0; outmap_write_count[waddr0] = outmap_write_count[waddr0] + 1; end
        if (we1) begin outmap[waddr1] <= wdata1; outmap_write_count[waddr1] = outmap_write_count[waddr1] + 1; end
        if (we2) begin outmap[waddr2] <= wdata2; outmap_write_count[waddr2] = outmap_write_count[waddr2] + 1; end
        if (we3) begin outmap[waddr3] <= wdata3; outmap_write_count[waddr3] = outmap_write_count[waddr3] + 1; end
    end

    reg signed [7:0] fmap [0:W*H*CIN-1];   // d[row][col][ch] flattened
    reg signed [7:0] g    [0:CIN-1][0:8];  // kernel per channel
    assign mem_rdata = fmap[mem_addr];

    integer ci, vi;
    task automatic pack_u_bus;
        begin
            for (ci = 0; ci < CIN; ci = ci + 1)
                for (vi = 0; vi < 16; vi = vi + 1)
                    u_flat_bus[ci*256 + vi*16 +: 16] = u_flat[ci][vi];
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
                u_flat[c][i*4+0] = 2*u1row[i][0];
                u_flat[c][i*4+1] = u1row[i][0] + u1row[i][1] + u1row[i][2];
                u_flat[c][i*4+2] = u1row[i][0] - u1row[i][1] + u1row[i][2];
                u_flat[c][i*4+3] = 2*u1row[i][2];
            end
        end
    endtask

    // ---- golden: direct conv + bias + activation at a real
    // (row,col) output position, over all Cin channels ----
    function automatic signed [63:0] golden_raw(input integer or_, input integer oc, input integer sub_r, input integer sub_c);
        integer kr, kc, c;
        reg signed [63:0] acc;
        begin
            acc = 0;
            for (c = 0; c < CIN; c = c + 1)
                for (kr = 0; kr < 3; kr = kr + 1)
                    for (kc = 0; kc < 3; kc = kc + 1)
                        acc = acc + fmap[(or_+sub_r+kr)*ROWBYTES + (oc+sub_c+kc)*CIN + c] * g[c][kr*3+kc];
            golden_raw = acc;
        end
    endfunction

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

    integer errors, tests, got_tiles;
    integer exp_seq_row, exp_seq_col;

    task automatic check_tile;
        reg signed [7:0] e0, e1, e2, e3;
        begin
            tests = tests + 1;
            got_tiles = got_tiles + 1;
            e0 = golden_sat(golden_raw(out_row, out_col, 0, 0), bias, activation);
            e1 = golden_sat(golden_raw(out_row, out_col, 0, 1), bias, activation);
            e2 = golden_sat(golden_raw(out_row, out_col, 1, 0), bias, activation);
            e3 = golden_sat(golden_raw(out_row, out_col, 1, 1), bias, activation);
            if (y0 !== e0 || y1 !== e1 || y2 !== e2 || y3 !== e3) begin
                errors = errors + 1;
                $display("FAIL tile(row=%0d,col=%0d): got=(%0d,%0d,%0d,%0d) expected=(%0d,%0d,%0d,%0d)",
                          out_row, out_col, y0,y1,y2,y3, e0,e1,e2,e3);
            end
            if (out_row !== exp_seq_row || out_col !== exp_seq_col) begin
                errors = errors + 1;
                $display("FAIL tile SEQUENCE at tile #%0d: got (row=%0d,col=%0d) expected (row=%0d,col=%0d)",
                          got_tiles, out_row, out_col, exp_seq_row, exp_seq_col);
            end
            if (exp_seq_col == (W-4)) begin
                exp_seq_col = 0;
                exp_seq_row = exp_seq_row + 2;
            end else begin
                exp_seq_col = exp_seq_col + 2;
            end
        end
    endtask

    integer i, k, c, wd;
    integer exp_total_tiles;
    initial begin
        errors = 0; tests = 0; got_tiles = 0;
        exp_total_tiles = (((H-4)/2)+1) * (((W-4)/2)+1);

        for (k = 0; k < 20; k = k + 1) begin
            // ---- fresh random feature map + kernel + bias + activation ----
            for (i = 0; i < W*H*CIN; i = i + 1) fmap[i] = $random;
            for (c = 0; c < CIN; c = c + 1)
                for (i = 0; i < 9; i = i + 1) g[c][i] = $random;
            bias = $random;
            activation = $random % 2;
            for (c = 0; c < CIN; c = c + 1) compute_kernel_transform(c);
            pack_u_bus;

            exp_seq_row = 0; exp_seq_col = 0; got_tiles = 0;
            for (i = 0; i < OUTN; i = i + 1) outmap_write_count[i] = 0;
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
                if (out_valid) check_tile;
                wd = wd + 1;
            end
            if (wd >= 100000) begin
                errors = errors + 1;
                $display("FAIL: WATCHDOG TIMEOUT on iteration %0d", k);
            end
            if (got_tiles !== exp_total_tiles) begin
                errors = errors + 1;
                tests = tests + 1;
                $display("FAIL: iteration %0d expected %0d tiles, got %0d", k, exp_total_tiles, got_tiles);
            end else begin
                tests = tests + 1;
            end

            // ---- full-image check: every output position written
            // exactly once, AND its final value matches an
            // independent golden full-feature-map convolution at
            // that (orow,ocol) real output position -- proves the
            // WHOLE image comes out right, not just each streamed
            // tile in isolation. ----
            begin : full_image_check
                integer orow, ocol, bad_cov;
                reg signed [7:0] exp_pixel;
                bad_cov = 0;
                for (orow = 0; orow < OUT_H; orow = orow + 1) begin
                    for (ocol = 0; ocol < OUT_W; ocol = ocol + 1) begin
                        if (outmap_write_count[orow*OUT_W+ocol] !== 1) bad_cov = bad_cov + 1;
                        exp_pixel = golden_sat(golden_raw(orow - (orow%2), ocol - (ocol%2), orow%2, ocol%2), bias, activation);
                        tests = tests + 1;
                        if (outmap[orow*OUT_W+ocol] !== exp_pixel) begin
                            errors = errors + 1;
                            $display("FAIL full-image pixel (orow=%0d,ocol=%0d): got=%0d expected=%0d",
                                      orow, ocol, outmap[orow*OUT_W+ocol], exp_pixel);
                        end
                    end
                end
                if (bad_cov != 0) begin
                    errors = errors + 1;
                    tests = tests + 1;
                    $display("FAIL: iteration %0d, %0d output positions NOT written exactly once", k, bad_cov);
                end else begin
                    tests = tests + 1;
                end
            end
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_winograd_conv_engine, full mover+neuron integration, %0d full-feature-map runs)", 20);
        $finish;
    end
endmodule
