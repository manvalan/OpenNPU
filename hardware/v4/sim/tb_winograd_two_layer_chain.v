// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- the real payoff test for this whole
// A.1 direction: TWO winograd_conv_engine_multicout.v instances
// chained -- layer 2's input memory IS layer 1's own output buffer
// directly (no DDR3 round-trip, no reshuffle -- exactly the real
// promise this session's own brainstorm made when it deliberately
// matched the input/output feature-map layout conventions).
//
// Real, deliberate scope for THIS test: SEQUENTIAL chaining (layer
// 2 starts only after layer 1's own `done` fires) -- true pipelined
// overlap between layers is real, disclosed later work, not
// attempted here. Golden model runs the same two convolutions in
// software, sequentially, over an explicit intermediate array, to
// stay an honest, independent cross-check (not re-deriving a closed
// form through both layers symbolically).
// ============================================================
module tb;
    // ---- layer 1: CIN0 -> COUT1, spatial W0xH0 -> (W0-2)x(H0-2) ----
    localparam W0    = 8;
    localparam H0    = 8;
    localparam CIN0  = 2;
    localparam COUT1 = 2;
    // ---- layer 2: COUT1 -> COUT2, spatial W1xH1 -> (W1-2)x(H1-2),
    // where W1=W0-2, H1=H0-2 (layer 1's own real output size) ----
    localparam W1    = W0-2;
    localparam H1    = H0-2;
    localparam COUT2 = 2;

    localparam ROWBYTES0 = W0*CIN0;
    localparam ADDRW0 = $clog2(W0*H0*CIN0);
    localparam OUT_W1 = W0-2, OUT_H1 = H0-2;
    localparam OUTADDRW1 = $clog2(OUT_W1*OUT_H1*COUT1);
    localparam OUTN1 = OUT_W1*OUT_H1*COUT1;

    localparam ADDRW1 = $clog2(W1*H1*COUT1); // layer2's own mem_addr width
    localparam OUT_W2 = W1-2, OUT_H2 = H1-2;
    localparam OUTADDRW2 = $clog2(OUT_W2*OUT_H2*COUT2);
    localparam OUTN2 = OUT_W2*OUT_H2*COUT2;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst, start1, start2;

    // ---- layer 1 ----
    wire [ADDRW0-1:0] mem_addr1;
    wire signed [7:0] mem_rdata1;
    reg  signed [7:0]  fmap0 [0:W0*H0*CIN0-1];
    assign mem_rdata1 = fmap0[mem_addr1];

    reg signed [7:0]  g1 [0:COUT1-1][0:CIN0-1][0:8];
    reg signed [15:0] u1 [0:COUT1-1][0:CIN0-1][0:15];
    reg signed [COUT1*16*16*CIN0-1:0] u_flat_mc1;
    reg signed [8*COUT1-1:0] bias_flat1;
    reg [1:0] activation1;

    wire out_valid1;
    wire [7:0] out_row1, out_col1;
    wire signed [8*4*COUT1-1:0] y_flat1;
    wire [4*COUT1-1:0] we_flat1;
    wire [4*COUT1*OUTADDRW1-1:0] waddr_flat1;
    wire signed [8*4*COUT1-1:0] wdata_flat1;
    wire busy1, done1;

    winograd_conv_engine_multicout #(.W(W0), .H(H0), .CIN(CIN0), .COUT(COUT1)) L1 (
        .clk(clk), .rst(rst), .start(start1),
        .mem_addr(mem_addr1), .mem_rdata(mem_rdata1),
        .u_flat_mc(u_flat_mc1), .bias_flat(bias_flat1), .activation(activation1),
        .out_valid(out_valid1), .out_row(out_row1), .out_col(out_col1), .y_flat(y_flat1),
        .we_flat(we_flat1), .waddr_flat(waddr_flat1), .wdata_flat(wdata_flat1),
        .busy(busy1), .done(done1)
    );

    // ---- layer 1's own output buffer -- this IS layer 2's input
    // memory, wired directly, no DDR3, no copy, no reshuffle. ----
    reg signed [7:0] mid [0:OUTN1-1];
    integer p, c;
    always @(posedge clk) begin
        for (p = 0; p < 4; p = p + 1)
            for (c = 0; c < COUT1; c = c + 1)
                if (we_flat1[p*COUT1+c])
                    mid[waddr_flat1[(p*COUT1+c)*OUTADDRW1 +: OUTADDRW1]] <= wdata_flat1[(p*COUT1+c)*8 +: 8];
    end

    // ---- layer 2 ----
    wire [ADDRW1-1:0] mem_addr2;
    wire signed [7:0] mem_rdata2;
    assign mem_rdata2 = mid[mem_addr2]; // <-- the whole point: direct, on-chip

    reg signed [7:0]  g2 [0:COUT2-1][0:COUT1-1][0:8];
    reg signed [15:0] u2 [0:COUT2-1][0:COUT1-1][0:15];
    reg signed [COUT2*16*16*COUT1-1:0] u_flat_mc2;
    reg signed [8*COUT2-1:0] bias_flat2;
    reg [1:0] activation2;

    wire out_valid2;
    wire [7:0] out_row2, out_col2;
    wire signed [8*4*COUT2-1:0] y_flat2;
    wire [4*COUT2-1:0] we_flat2;
    wire [4*COUT2*OUTADDRW2-1:0] waddr_flat2;
    wire signed [8*4*COUT2-1:0] wdata_flat2;
    wire busy2, done2;

    winograd_conv_engine_multicout #(.W(W1), .H(H1), .CIN(COUT1), .COUT(COUT2)) L2 (
        .clk(clk), .rst(rst), .start(start2),
        .mem_addr(mem_addr2), .mem_rdata(mem_rdata2),
        .u_flat_mc(u_flat_mc2), .bias_flat(bias_flat2), .activation(activation2),
        .out_valid(out_valid2), .out_row(out_row2), .out_col(out_col2), .y_flat(y_flat2),
        .we_flat(we_flat2), .waddr_flat(waddr_flat2), .wdata_flat(wdata_flat2),
        .busy(busy2), .done(done2)
    );

    reg signed [7:0] outmap2 [0:OUTN2-1];
    integer outmap2_write_count [0:OUTN2-1];
    always @(posedge clk) begin
        for (p = 0; p < 4; p = p + 1)
            for (c = 0; c < COUT2; c = c + 1)
                if (we_flat2[p*COUT2+c]) begin
                    outmap2[waddr_flat2[(p*COUT2+c)*OUTADDRW2 +: OUTADDRW2]] <= wdata_flat2[(p*COUT2+c)*8 +: 8];
                    outmap2_write_count[waddr_flat2[(p*COUT2+c)*OUTADDRW2 +: OUTADDRW2]] =
                        outmap2_write_count[waddr_flat2[(p*COUT2+c)*OUTADDRW2 +: OUTADDRW2]] + 1;
                end
    end

    // ---- kernel transform helper, generic over (nout,nin) ----
    task automatic xform1(input integer o, input integer c);
        integer col, i;
        reg signed [19:0] c0, c1, c2;
        reg signed [19:0] u1row [0:3][0:2];
        begin
            for (col = 0; col < 3; col = col + 1) begin
                c0 = g1[o][c][0*3+col]; c1 = g1[o][c][1*3+col]; c2 = g1[o][c][2*3+col];
                u1row[0][col] = 2*c0; u1row[1][col] = c0+c1+c2; u1row[2][col] = c0-c1+c2; u1row[3][col] = 2*c2;
            end
            for (i = 0; i < 4; i = i + 1) begin
                u1[o][c][i*4+0] = 2*u1row[i][0];
                u1[o][c][i*4+1] = u1row[i][0]+u1row[i][1]+u1row[i][2];
                u1[o][c][i*4+2] = u1row[i][0]-u1row[i][1]+u1row[i][2];
                u1[o][c][i*4+3] = 2*u1row[i][2];
            end
        end
    endtask
    task automatic xform2(input integer o, input integer c);
        integer col, i;
        reg signed [19:0] c0, c1, c2;
        reg signed [19:0] u1row [0:3][0:2];
        begin
            for (col = 0; col < 3; col = col + 1) begin
                c0 = g2[o][c][0*3+col]; c1 = g2[o][c][1*3+col]; c2 = g2[o][c][2*3+col];
                u1row[0][col] = 2*c0; u1row[1][col] = c0+c1+c2; u1row[2][col] = c0-c1+c2; u1row[3][col] = 2*c2;
            end
            for (i = 0; i < 4; i = i + 1) begin
                u2[o][c][i*4+0] = 2*u1row[i][0];
                u2[o][c][i*4+1] = u1row[i][0]+u1row[i][1]+u1row[i][2];
                u2[o][c][i*4+2] = u1row[i][0]-u1row[i][1]+u1row[i][2];
                u2[o][c][i*4+3] = 2*u1row[i][2];
            end
        end
    endtask

    integer oc, ci, vi;
    task automatic pack_u1; begin
        for (oc=0; oc<COUT1; oc=oc+1) for (ci=0; ci<CIN0; ci=ci+1) for (vi=0; vi<16; vi=vi+1)
            u_flat_mc1[oc*(16*16*CIN0) + ci*256 + vi*16 +: 16] = u1[oc][ci][vi];
    end endtask
    task automatic pack_u2; begin
        for (oc=0; oc<COUT2; oc=oc+1) for (ci=0; ci<COUT1; ci=ci+1) for (vi=0; vi<16; vi=vi+1)
            u_flat_mc2[oc*(16*16*COUT1) + ci*256 + vi*16 +: 16] = u2[oc][ci][vi];
    end endtask

    function automatic signed [7:0] sat(input signed [63:0] acc, input signed [7:0] b, input [1:0] act);
        reg signed [63:0] wide, v;
        begin
            wide = acc + b;
            if (act == 2'd0) begin
                if (wide > 127) v = 127; else if (wide < -128) v = -128; else v = wide;
            end else begin
                if (wide <= 0) v = 0; else if (wide > 127) v = 127; else v = wide;
            end
            sat = v[7:0];
        end
    endfunction

    // ---- golden: build the FULL intermediate feature map (layer1's
    // real conv+bias+act output, all OUT_W1 x OUT_H1 x COUT1 values)
    // independently, THEN run layer2's own conv over THAT array --
    // two honest, sequential software passes, mirroring the DUT. ----
    reg signed [7:0] gmid [0:OUTN1-1];
    integer gi;
    task automatic build_golden_mid;
        integer orow, ocol, o, cc, kr, kc;
        reg signed [63:0] acc;
        begin
            for (orow = 0; orow < OUT_H1; orow = orow + 1)
                for (ocol = 0; ocol < OUT_W1; ocol = ocol + 1)
                    for (o = 0; o < COUT1; o = o + 1) begin
                        acc = 0;
                        for (cc = 0; cc < CIN0; cc = cc + 1)
                            for (kr = 0; kr < 3; kr = kr + 1)
                                for (kc = 0; kc < 3; kc = kc + 1)
                                    acc = acc + fmap0[(orow+kr)*ROWBYTES0 + (ocol+kc)*CIN0 + cc] * g1[o][cc][kr*3+kc];
                        gmid[orow*(OUT_W1*COUT1) + ocol*COUT1 + o] = sat(acc, bias_flat1[o*8+:8], activation1);
                    end
        end
    endtask

    function automatic signed [7:0] golden_final(input integer orow, input integer ocol, input integer o);
        integer cc, kr, kc;
        reg signed [63:0] acc;
        begin
            acc = 0;
            for (cc = 0; cc < COUT1; cc = cc + 1)
                for (kr = 0; kr < 3; kr = kr + 1)
                    for (kc = 0; kc < 3; kc = kc + 1)
                        acc = acc + gmid[(orow+kr)*(OUT_W1*COUT1) + (ocol+kc)*COUT1 + cc] * g2[o][cc][kr*3+kc];
            golden_final = sat(acc, bias_flat2[o*8+:8], activation2);
        end
    endfunction

    integer errors, tests, wd, i, k, o, orow, ocol;
    initial begin
        errors = 0; tests = 0;

        for (k = 0; k < 10; k = k + 1) begin
            for (i = 0; i < W0*H0*CIN0; i = i + 1) fmap0[i] = $random;
            for (o = 0; o < COUT1; o = o + 1) begin
                for (c = 0; c < CIN0; c = c + 1) for (i = 0; i < 9; i = i + 1) g1[o][c][i] = $random;
                bias_flat1[o*8+:8] = $random;
                for (c = 0; c < CIN0; c = c + 1) xform1(o,c);
            end
            for (o = 0; o < COUT2; o = o + 1) begin
                for (c = 0; c < COUT1; c = c + 1) for (i = 0; i < 9; i = i + 1) g2[o][c][i] = $random;
                bias_flat2[o*8+:8] = $random;
                for (c = 0; c < COUT1; c = c + 1) xform2(o,c);
            end
            activation1 = $random % 2;
            activation2 = $random % 2;
            pack_u1; pack_u2;
            build_golden_mid;

            for (i = 0; i < OUTN2; i = i + 1) outmap2_write_count[i] = 0;
            rst = 1; start1 = 0; start2 = 0;
            repeat (5) @(posedge clk);
            rst = 0;
            @(posedge clk);
            start1 <= 1'b1;
            @(posedge clk);
            start1 <= 1'b0;

            wd = 0;
            while (!done1 && wd < 100000) begin @(posedge clk); wd = wd + 1; end
            if (wd >= 100000) begin errors=errors+1; tests=tests+1; $display("FAIL: layer1 watchdog, iter %0d", k); end

            @(posedge clk);
            start2 <= 1'b1;
            @(posedge clk);
            start2 <= 1'b0;

            wd = 0;
            while (!done2 && wd < 100000) begin @(posedge clk); wd = wd + 1; end
            if (wd >= 100000) begin errors=errors+1; tests=tests+1; $display("FAIL: layer2 watchdog, iter %0d", k); end

            begin : chk
                integer bad_cov;
                reg signed [7:0] exp_pixel;
                bad_cov = 0;
                for (orow = 0; orow < OUT_H2; orow = orow + 1) begin
                    for (ocol = 0; ocol < OUT_W2; ocol = ocol + 1) begin
                        for (o = 0; o < COUT2; o = o + 1) begin
                            if (outmap2_write_count[orow*(OUT_W2*COUT2)+ocol*COUT2+o] !== 1) bad_cov = bad_cov + 1;
                            exp_pixel = golden_final(orow, ocol, o);
                            tests = tests + 1;
                            if (outmap2[orow*(OUT_W2*COUT2)+ocol*COUT2+o] !== exp_pixel) begin
                                errors = errors + 1;
                                $display("FAIL iter=%0d final pixel(orow=%0d,ocol=%0d,ch=%0d): got=%0d expected=%0d",
                                          k, orow, ocol, o, outmap2[orow*(OUT_W2*COUT2)+ocol*COUT2+o], exp_pixel);
                            end
                        end
                    end
                end
                tests = tests + 1;
                if (bad_cov != 0) begin
                    errors = errors + 1;
                    $display("FAIL: iter %0d, %0d final output positions not written exactly once", k, bad_cov);
                end
            end
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_winograd_two_layer_chain, real layer1->layer2 direct handoff, no DDR3 round-trip, %0d runs)", 10);
        $finish;
    end
endmodule
