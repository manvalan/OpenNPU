// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- isolated correctness test for
// winograd_writeback_addr_multicout.v. Same discipline as the
// single-channel version: drive the real tile-position sequence,
// check full coverage (every one of OUT_W*OUT_H*COUT output
// positions written exactly once) and an independent address
// formula, plus data pass-through.
// ============================================================
module tb;
    localparam W = 8;
    localparam H = 8;
    localparam COUT = 3;
    localparam OUT_W = W-2;
    localparam OUT_H = H-2;
    localparam OUTN = OUT_W*OUT_H*COUT;
    localparam ADDRW = $clog2(OUT_W*OUT_H*COUT);

    reg in_valid;
    reg [7:0] in_row, in_col;
    reg signed [8*4*COUT-1:0] y_flat;

    wire [4*COUT-1:0] we_flat;
    wire [4*COUT*ADDRW-1:0] addr_flat;
    wire signed [8*4*COUT-1:0] wdata_flat;

    winograd_writeback_addr_multicout #(.W(W), .H(H), .COUT(COUT)) dut (
        .in_valid(in_valid), .in_row(in_row), .in_col(in_col), .y_flat(y_flat),
        .we_flat(we_flat), .addr_flat(addr_flat), .wdata_flat(wdata_flat)
    );

    integer errors, tests;
    integer write_count [0:OUTN-1];

    integer row, col, p, c;
    reg [7:0] dr, dc;
    reg [ADDRW-1:0] a;
    reg signed [7:0] d, expd;
    reg we;

    initial begin
        errors = 0; tests = 0;
        for (p = 0; p < OUTN; p = p + 1) write_count[p] = 0;

        row = 0; col = 0;
        while (row <= (H-4)) begin
            in_valid = 1'b1;
            in_row = row; in_col = col;
            for (c = 0; c < COUT; c = c + 1)
                for (p = 0; p < 4; p = p + 1)
                    y_flat[c*32 + p*8 +: 8] = row*20 + col + c*4 + p;
            #1;
            for (p = 0; p < 4; p = p + 1) begin
                dr = (p < 2) ? 8'd0 : 8'd1;
                dc = (p % 2 == 0) ? 8'd0 : 8'd1;
                for (c = 0; c < COUT; c = c + 1) begin
                    tests = tests + 1;
                    we = we_flat[p*COUT+c];
                    a  = addr_flat[(p*COUT+c)*ADDRW +: ADDRW];
                    d  = wdata_flat[(p*COUT+c)*8 +: 8];
                    expd = row*20 + col + c*4 + p;
                    if (!we) begin
                        errors = errors + 1;
                        $display("FAIL: we not set for p=%0d c=%0d at row=%0d col=%0d", p, c, row, col);
                    end else begin
                        write_count[a] = write_count[a] + 1;
                        if (d !== expd) begin
                            errors = errors + 1;
                            $display("FAIL: data mismatch p=%0d c=%0d addr=%0d got=%0d expected=%0d", p, c, a, d, expd);
                        end
                        if (a !== (row+dr)*(OUT_W*COUT) + (col+dc)*COUT + c) begin
                            errors = errors + 1;
                            $display("FAIL: address formula mismatch p=%0d c=%0d row=%0d col=%0d got=%0d expected=%0d",
                                      p, c, row, col, a, (row+dr)*(OUT_W*COUT)+(col+dc)*COUT+c);
                        end
                    end
                end
            end

            if (col == (W-4)) begin
                col = 0; row = row + 2;
            end else begin
                col = col + 2;
            end
        end
        in_valid = 1'b0;

        tests = tests + 1;
        begin : cov
            integer bad;
            bad = 0;
            for (p = 0; p < OUTN; p = p + 1)
                if (write_count[p] !== 1) bad = bad + 1;
            if (bad != 0) begin
                errors = errors + 1;
                $display("FAIL: %0d of %0d output positions were NOT written exactly once", bad, OUTN);
            end else begin
                $display("PASS: all %0d output positions (OUT_W*OUT_H*COUT) written exactly once", OUTN);
            end
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_winograd_writeback_addr_multicout, COUT=%0d)", COUT);
        $finish;
    end
endmodule
