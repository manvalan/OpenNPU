// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps
// ============================================================
// v4 -- qspi_data_port.v against an ESP32-like QSPI master BFM (mode 0,
// 80 MHz, command + 48-bit address + [dummy] + data on 4 lines) and a
// memory model behind the v3 controller contract (random latency).
// Random WRITE transactions (odd/even start, 1..40 words), then READ
// transactions over the same ranges, every byte compared; also reads
// right after writes, back to back.
// ============================================================
module tb;
    reg clk = 0; always #3.225 clk = ~clk;      // ui_clk
    reg rst = 1;
    reg qsclk = 0, qcs_n = 1;
    reg [3:0] mo = 0; wire [3:0] qo; wire qoe;
    wire [3:0] qio_in = mo;

    wire active, m_req, m_wr; wire [24:0] m_addr; wire [255:0] m_wdata; wire [31:0] m_wmask;
    reg [255:0] m_rdata; reg m_ready = 0;
    wire [31:0] nw, nr;
    qspi_data_port #(.DUMMY(64)) dut (
        .qsclk(qsclk), .qcs_n(qcs_n), .qio_in(qio_in), .qio_out(qo), .qio_oe(qoe),
        .clk(clk), .rst(rst), .active(active), .m_grant(1'b1),
        .m_req(m_req), .m_wr(m_wr), .m_addr(m_addr), .m_wdata(m_wdata), .m_wmask(m_wmask),
        .m_rdata(m_rdata), .m_ready(m_ready), .n_write_words(nw), .n_read_words(nr));

    // memory model: 128-bit words, burst at m_addr/8 = words 2b, 2b+1
    reg [127:0] mem [0:8191];
    reg [127:0] refm [0:8191];
    integer lat, b, k;
    always @(posedge clk) begin
        m_ready <= 0;
        if (m_req) begin
            lat = 5 + ($random & 15);
            repeat (lat) @(posedge clk);
            b = m_addr / 8;
            if (m_wr) begin
                for (k = 0; k < 16; k = k + 1) begin
                    if (!m_wmask[k])      mem[2*b][k*8 +: 8]   = m_wdata[k*8 +: 8];
                    if (!m_wmask[16 + k]) mem[2*b+1][k*8 +: 8] = m_wdata[128 + k*8 +: 8];
                end
            end else m_rdata <= {mem[2*b+1], mem[2*b]};
            m_ready <= 1;
        end
    end

    // ---- QSPI master BFM, 80 MHz ----
    task automatic qclk_out(input [3:0] n);
        begin mo = n; #6.25; qsclk = 1; #6.25; qsclk = 0; end
    endtask
    task automatic header(input [7:0] cmd, input [31:0] W, input [15:0] len);
        integer i; reg [55:0] h;
        begin
            h = {cmd, W, len};
            qcs_n = 0; #10;
            for (i = 13; i >= 0; i = i - 1) qclk_out(h[i*4 +: 4]);
        end
    endtask
    reg [127:0] xbuf [0:63];
    task automatic qwrite(input [31:0] W, input integer n);
        integer i, j;
        begin
            header(8'h1A, W, n);
            for (i = 0; i < n; i = i + 1)
                for (j = 0; j < 16; j = j + 1) begin
                    qclk_out(xbuf[i][j*8+4 +: 4]);
                    qclk_out(xbuf[i][j*8 +: 4]);
                end
            #10 qcs_n = 1; #30;
        end
    endtask
    task automatic qread(input [31:0] W, input integer n);
        integer i, j;
        begin
            header(8'h2A, W, n);
            for (i = 0; i < 64; i = i + 1) qclk_out(4'h0);        // dummy
            for (i = 0; i < n; i = i + 1)
                for (j = 0; j < 16; j = j + 1) begin
                    mo = 0; #6.25; qsclk = 1; xbuf[i][j*8+4 +: 4] = qo; #6.25; qsclk = 0;
                    #6.25; qsclk = 1; xbuf[i][j*8 +: 4] = qo; #6.25; qsclk = 0;
                end
            #10 qcs_n = 1; #30;
        end
    endtask

    integer t, n, W, i, errors = 0, words = 0;
    time t0, twr = 0;
    initial begin
        for (i = 0; i < 8192; i = i + 1) begin mem[i] = {4{$random}}; refm[i] = mem[i]; end
        #50 rst = 0; #100;
        for (t = 0; t < 200; t = t + 1) begin
            n = 1 + ($random & 32'h7fffffff) % 40; W = ($random & 32'h7fffffff) % 8000;
            for (i = 0; i < n; i = i + 1) begin xbuf[i] = {$random, $random, $random, $random}; refm[W + i] = xbuf[i]; end
            t0 = $time;
            qwrite(W, n);
            twr = twr + ($time - t0); words = words + n;
            // wait until the port has drained the write to memory
            while (active || nw < words) #20;
            // read back a random range that overlaps it
            qread(W, n);
            for (i = 0; i < n; i = i + 1)
                if (xbuf[i] !== refm[W + i]) begin
                    errors = errors + 1;
                    if (errors < 10) $display("FAIL t%0d word %0d (W=%0d): got %h exp %h", t, i, W + i, xbuf[i], refm[W + i]);
                end
        end
        // whole-memory check of everything the writes touched
        for (i = 0; i < 8192; i = i + 1) if (mem[i] !== refm[i]) begin errors = errors + 1; if (errors < 20) $display("FAIL mem[%0d]", i); end
        $display("=== QSPI data port: 200 write+read transactions, %0d words, %0d errors; write rate on the wire %0.1f MB/s ===",
                 words, errors, words * 16.0 / (twr * 1.0e-9) / 1.0e6);
        if (errors == 0) $display("ALL TESTS PASSED (tb_qspi_data_port)");
        $finish;
    end
endmodule
