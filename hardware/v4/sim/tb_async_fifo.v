// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps
// v4 -- async_fifo.v: two unrelated clocks (5.0 ns / 6.45 ns, both
// directions tested by swapping), random write/read enables, every word
// checked in order, no loss / duplication, full/empty never violated.
module tb;
    localparam DW = 32;
    localparam AW = `ifdef TB_AW `TB_AW `else 4 `endif;
    localparam N = 20000;
    reg wclk = 0, rclk = 0;
    real WP, RP;
    initial begin WP = `ifdef TB_SWAP 3.225 `else 2.5 `endif; RP = `ifdef TB_SWAP 2.5 `else 3.225 `endif; end
    always #(WP) wclk = ~wclk;
    always #(RP) rclk = ~rclk;
    reg wrst = 1, rrst = 1;
    reg wr_en = 0, rd_en = 0;
    reg [DW-1:0] wr_data = 0;
    wire full, empty; wire [AW:0] wc; wire [DW-1:0] rd_data;
    async_fifo #(.DW(DW), .AW(AW)) dut (.wclk(wclk), .wrst(wrst), .wr_en(wr_en), .wr_data(wr_data), .full(full), .wr_count(wc),
        .rclk(rclk), .rrst(rrst), .rd_en(rd_en), .rd_data(rd_data), .empty(empty));
    integer wn = 0, rn = 0, errors = 0, maxc = 0;
    always @(posedge wclk) if (!wrst && wr_en && !full) wn = wn + 1;
    always @(negedge wclk) if (!wrst) begin
        wr_en <= (wn < N) && (($random & 3) != 0);
        wr_data <= wn;          // value = index of the word being offered
        if (wc > maxc) maxc = wc;
    end
    always @(posedge rclk) if (!rrst && rd_en && !empty) begin
        if (rd_data !== rn) begin errors = errors + 1; if (errors < 10) $display("FAIL got %0d exp %0d", rd_data, rn); end
        rn = rn + 1;
    end
    always @(negedge rclk) if (!rrst) rd_en <= (($random & 3) != 0);
    initial begin
        #50 wrst = 0; rrst = 0;
        wait (rn == N);
        #200;
        if (wc > (1<<AW)) begin errors = errors + 1; $display("FAIL count overflow"); end
        $display("=== AW=%0d: %0d words, %0d errors, max count %0d ===", AW, rn, errors, maxc);
        if (errors == 0) $display("ALL TESTS PASSED (tb_async_fifo)");
        $finish;
    end
    initial begin #20000000; $display("FAIL: timeout rn=%0d", rn); $finish; end
endmodule
