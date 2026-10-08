// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- isolated correctness test for
// winograd_writeback_addr.v. Drives the SAME (row,col) tile
// sequence g_window_mover.v produces and checks: (a) every one of
// the (H-2)x(W-2) output positions is written EXACTLY ONCE (the
// classic tiling bug -- overlap or gap), (b) the address computed
// for each of the 4 positions matches an independent row-major
// formula, (c) the data passed through is unchanged.
// ============================================================
module tb;
    localparam W = 8;
    localparam H = 8;
    localparam OUT_W = W-2;
    localparam OUT_H = H-2;
    localparam OUTN = OUT_W*OUT_H;

    reg in_valid;
    reg [7:0] in_row, in_col;
    reg signed [7:0] y0, y1, y2, y3;

    wire we0, we1, we2, we3;
    wire [$clog2(OUTN)-1:0] addr0, addr1, addr2, addr3;
    wire signed [7:0] wdata0, wdata1, wdata2, wdata3;

    winograd_writeback_addr #(.W(W), .H(H)) dut (
        .in_valid(in_valid), .in_row(in_row), .in_col(in_col),
        .y0(y0), .y1(y1), .y2(y2), .y3(y3),
        .we0(we0), .we1(we1), .we2(we2), .we3(we3),
        .addr0(addr0), .addr1(addr1), .addr2(addr2), .addr3(addr3),
        .wdata0(wdata0), .wdata1(wdata1), .wdata2(wdata2), .wdata3(wdata3)
    );

    integer errors, tests;
    integer write_count [0:OUTN-1];
    reg signed [7:0] last_data [0:OUTN-1];

    task automatic check_one(input we, input [$clog2(OUTN)-1:0] a, input signed [7:0] d, input signed [7:0] exp_d);
        begin
            tests = tests + 1;
            if (!we) begin
                errors = errors + 1;
                $display("FAIL: we not asserted when in_valid=1");
            end else begin
                write_count[a] = write_count[a] + 1;
                last_data[a] = d;
                if (d !== exp_d) begin
                    errors = errors + 1;
                    $display("FAIL: addr=%0d got data=%0d expected=%0d", a, d, exp_d);
                end
            end
        end
    endtask

    integer row, col, i;
    initial begin
        errors = 0; tests = 0;
        for (i = 0; i < OUTN; i = i + 1) write_count[i] = 0;

        row = 0; col = 0;
        while (row <= (H-4)) begin
            in_valid = 1'b1;
            in_row = row; in_col = col;
            // deterministic, decodable data: value = 100 + tile index encoding
            y0 = row*10 + col + 1;
            y1 = row*10 + col + 2;
            y2 = row*10 + col + 3;
            y3 = row*10 + col + 4;
            #1;
            check_one(we0, addr0, wdata0, y0);
            check_one(we1, addr1, wdata1, y1);
            check_one(we2, addr2, wdata2, y2);
            check_one(we3, addr3, wdata3, y3);

            // independent address formula cross-check
            tests = tests + 1;
            if (addr0 !== (row)*OUT_W+col || addr1 !== (row)*OUT_W+(col+1) ||
                addr2 !== (row+1)*OUT_W+col || addr3 !== (row+1)*OUT_W+(col+1)) begin
                errors = errors + 1;
                $display("FAIL: address formula mismatch at row=%0d col=%0d: got (%0d,%0d,%0d,%0d)",
                          row, col, addr0, addr1, addr2, addr3);
            end

            if (col == (W-4)) begin
                col = 0; row = row + 2;
            end else begin
                col = col + 2;
            end
        end
        in_valid = 1'b0;

        // ---- coverage check: every output position written EXACTLY once ----
        tests = tests + 1;
        begin : cov
            integer bad;
            bad = 0;
            for (i = 0; i < OUTN; i = i + 1)
                if (write_count[i] !== 1) bad = bad + 1;
            if (bad != 0) begin
                errors = errors + 1;
                $display("FAIL: %0d of %0d output positions were NOT written exactly once", bad, OUTN);
            end else begin
                $display("PASS: all %0d output positions written exactly once", OUTN);
            end
        end

        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_winograd_writeback_addr, full coverage, no overlap/gap)");
        $finish;
    end
endmodule
