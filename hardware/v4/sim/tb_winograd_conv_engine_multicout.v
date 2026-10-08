// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- end-to-end test for
// winograd_conv_engine_multicout.v: ONE shared G mover, COUT
// parallel neuron instances, full output feature map (all COUT
// channels) checked pixel-by-pixel against an independent golden
// full multi-channel-output convolution.
// ============================================================
module tb;
    localparam W    = 8;
    localparam H    = 8;
    localparam CIN  = 2;
    localparam COUT = 3;
    localparam ROWBYTES = W*CIN;
    localparam ADDRW = $clog2(W*H*CIN);
    localparam OUT_W = W-2;
    localparam OUT_H = H-2;
    localparam OUTADDRW = $clog2(OUT_W*OUT_H*COUT);
    localparam OUTN = OUT_W*OUT_H*COUT;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst, start;

    wire [ADDRW-1:0] mem_addr;
    wire signed [7:0] mem_rdata;

    // u[oc][ci][16], g[oc][ci][9] -- COUT output channels, each with
    // its own CIN-channel 3x3 kernel
    reg signed [7:0]  g [0:COUT-1][0:CIN-1][0:8];
    reg signed [15:0] u [0:COUT-1][0:CIN-1][0:15];
    reg signed [COUT*16*16*CIN-1:0] u_flat_mc;
    reg signed [8*COUT-1:0] bias_flat;
    reg [1:0] activation;

    wire out_valid;
    wire [7:0] out_row, out_col;
    wire signed [8*4*COUT-1:0] y_flat;
    wire [4*COUT-1:0] we_flat;
    wire [4*COUT*OUTADDRW-1:0] waddr_flat;
    wire signed [8*4*COUT-1:0] wdata_flat;
    wire busy, done;

    winograd_conv_engine_multicout #(.W(W), .H(H), .CIN(CIN), .COUT(COUT)) dut (
        .clk(clk), .rst(rst), .start(start),
        .mem_addr(mem_addr), .mem_rdata(mem_rdata),
        .u_flat_mc(u_flat_mc), .bias_flat(bias_flat), .activation(activation),
        .out_valid(out_valid), .out_row(out_row), .out_col(out_col), .y_flat(y_flat),
        .we_flat(we_flat), .waddr_flat(waddr_flat), .wdata_flat(wdata_flat),
        .busy(busy), .done(done)
    );

    reg signed [7:0] fmap [0:W*H*CIN-1];
    assign mem_rdata = fmap[mem_addr];

    reg signed [7:0] outmap [0:OUTN-1];
    integer outmap_write_count [0:OUTN-1];
    integer p, c;
    always @(posedge clk) begin
        for (p = 0; p < 4; p = p + 1) begin
            for (c = 0; c < COUT; c = c + 1) begin
                if (we_flat[p*COUT+c]) begin
                    outmap[waddr_flat[(p*COUT+c)*OUTADDRW +: OUTADDRW]] <= wdata_flat[(p*COUT+c)*8 +: 8];
                    outmap_write_count[waddr_flat[(p*COUT+c)*OUTADDRW +: OUTADDRW]] =
                        outmap_write_count[waddr_flat[(p*COUT+c)*OUTADDRW +: OUTADDRW]] + 1;
                end
            end
        end
    end

    integer oc, ci, vi;
    task automatic pack_u_bus;
        begin
            for (oc = 0; oc < COUT; oc = oc + 1)
                for (ci = 0; ci < CIN; ci = ci + 1)
                    for (vi = 0; vi < 16; vi = vi + 1)
                        u_flat_mc[oc*(16*16*CIN) + ci*256 + vi*16 +: 16] = u[oc][ci][vi];
        end
    endtask

    task automatic compute_kernel_transform(input integer o, input integer c);
        integer col, i;
        reg signed [19:0] c0, c1, c2;
        reg signed [19:0] u1row [0:3][0:2];
        begin
            for (col = 0; col < 3; col = col + 1) begin
                c0 = g[o][c][0*3+col];
                c1 = g[o][c][1*3+col];
                c2 = g[o][c][2*3+col];
                u1row[0][col] = 2*c0;
                u1row[1][col] = c0 + c1 + c2;
                u1row[2][col] = c0 - c1 + c2;
                u1row[3][col] = 2*c2;
            end
            for (i = 0; i < 4; i = i + 1) begin
                u[o][c][i*4+0] = 2*u1row[i][0];
                u[o][c][i*4+1] = u1row[i][0] + u1row[i][1] + u1row[i][2];
                u[o][c][i*4+2] = u1row[i][0] - u1row[i][1] + u1row[i][2];
                u[o][c][i*4+3] = 2*u1row[i][2];
            end
        end
    endtask

    function automatic signed [63:0] golden_raw(input integer o, input integer or_, input integer oc_, input integer sub_r, input integer sub_c);
        integer kr, kc, c;
        reg signed [63:0] acc;
        begin
            acc = 0;
            for (c = 0; c < CIN; c = c + 1)
                for (kr = 0; kr < 3; kr = kr + 1)
                    for (kc = 0; kc < 3; kc = kc + 1)
                        acc = acc + fmap[(or_+sub_r+kr)*ROWBYTES + (oc_+sub_c+kc)*CIN + c] * g[o][c][kr*3+kc];
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

    integer errors, tests, wd, i, k, o;
    initial begin
        errors = 0; tests = 0;

        for (k = 0; k < 15; k = k + 1) begin
            for (i = 0; i < W*H*CIN; i = i + 1) fmap[i] = $random;
            for (o = 0; o < COUT; o = o + 1) begin
                for (c = 0; c < CIN; c = c + 1)
                    for (i = 0; i < 9; i = i + 1) g[o][c][i] = $random;
                bias_flat[o*8 +: 8] = $random;
                compute_kernel_transform(o, 0);
                for (c = 0; c < CIN; c = c + 1) compute_kernel_transform(o, c);
            end
            activation = $random % 2;
            pack_u_bus;

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
                wd = wd + 1;
            end
            if (wd >= 100000) begin
                errors = errors + 1;
                tests = tests + 1;
                $display("FAIL: WATCHDOG TIMEOUT on iteration %0d", k);
            end

            begin : full_check
                integer orow, ocol, bad_cov;
                reg signed [7:0] exp_pixel;
                bad_cov = 0;
                for (orow = 0; orow < OUT_H; orow = orow + 1) begin
                    for (ocol = 0; ocol < OUT_W; ocol = ocol + 1) begin
                        for (o = 0; o < COUT; o = o + 1) begin
                            if (outmap_write_count[orow*(OUT_W*COUT)+ocol*COUT+o] !== 1) bad_cov = bad_cov + 1;
                            exp_pixel = golden_sat(golden_raw(o, orow-(orow%2), ocol-(ocol%2), orow%2, ocol%2), bias_flat[o*8 +: 8], activation);
                            tests = tests + 1;
                            if (outmap[orow*(OUT_W*COUT)+ocol*COUT+o] !== exp_pixel) begin
                                errors = errors + 1;
                                $display("FAIL iter=%0d pixel(orow=%0d,ocol=%0d,ch=%0d): got=%0d expected=%0d",
                                          k, orow, ocol, o, outmap[orow*(OUT_W*COUT)+ocol*COUT+o], exp_pixel);
                            end
                        end
                    end
                end
                tests = tests + 1;
                if (bad_cov != 0) begin
                    errors = errors + 1;
                    $display("FAIL: iteration %0d, %0d output positions NOT written exactly once", k, bad_cov);
                end
            end
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_winograd_conv_engine_multicout, COUT=%0d, %0d full-feature-map runs)", COUT, 15);
        $finish;
    end
endmodule
