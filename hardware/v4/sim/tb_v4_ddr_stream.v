// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps
// ============================================================
// v4 -- v4_ddr_stream.v against a behavioral MIG app model (pipelined,
// in-order reads, 2 beats per burst, random app_rdy / wdf_rdy, random
// read latency) with the REAL v3 mig_native_adapter.v as the competing
// host master. Checks: every read job returns exactly its words in
// order (odd/even starts, 1..300 words), streamer writes land with the
// other half-burst untouched, host adapter writes/reads interleaved
// between streamer jobs are correct, and the achieved read bandwidth.
// ============================================================
module tb;
    reg clk = 0; always #3.225 clk = ~clk;   // ui_clk 155 MHz
    reg rst = 1;

    // ---- memory: 128-bit words ----
    reg [127:0] mem [0:8191];
    reg [127:0] mem_snap [0:8191];

    // ---- MIG app model ----
    wire [27:0]  app_addr;  wire [2:0] app_cmd; wire app_en; reg app_rdy;
    wire [127:0] app_wdf_data; wire app_wdf_end; wire [15:0] app_wdf_mask; wire app_wdf_wren; reg app_wdf_rdy;
    reg  [127:0] app_rd_data; reg app_rd_data_end, app_rd_data_valid;

    // read queue: burst index + ready time
    integer rq_b [0:1023]; integer rq_t [0:1023]; integer rq_w = 0, rq_r = 0;
    integer wq_b [0:1023]; integer wq_w = 0, wq_r = 0, wbeat = 0;
    integer cyc = 0, rbeat = 0, k;
    always @(posedge clk) begin
        cyc = cyc + 1;
        app_rd_data_valid <= 1'b0; app_rd_data_end <= 1'b0;
        if (!rst) begin
            if (app_en && app_rdy) begin
                if (app_cmd == 3'b001) begin rq_b[rq_w % 1024] = app_addr / 8; rq_t[rq_w % 1024] = cyc + 18 + ($random & 7); rq_w = rq_w + 1; end
                else begin wq_b[wq_w % 1024] = app_addr / 8; wq_w = wq_w + 1; end
            end
            if (app_wdf_wren && app_wdf_rdy) begin
                if (wq_r >= wq_w) begin $display("FAIL: write data before command"); end
                for (k = 0; k < 16; k = k + 1)
                    if (!app_wdf_mask[k]) mem[2*wq_b[wq_r % 1024] + wbeat][k*8 +: 8] = app_wdf_data[k*8 +: 8];
                if (wbeat == 1) begin
                    if (!app_wdf_end) $display("FAIL: wdf_end missing");
                    wbeat = 0; wq_r = wq_r + 1;
                end else wbeat = 1;
            end
            if (rq_r < rq_w && cyc >= rq_t[rq_r % 1024] && (($random & 7) != 0)) begin
                app_rd_data_valid <= 1'b1;
                app_rd_data <= mem[2*rq_b[rq_r % 1024] + rbeat];
                app_rd_data_end <= (rbeat == 1);
                if (rbeat == 1) begin rbeat = 0; rq_r = rq_r + 1; end else rbeat = 1;
            end
        end
    end
    always @(negedge clk) begin app_rdy <= (($random & 7) != 0); app_wdf_rdy <= (($random & 3) != 0); end

    // ---- host adapter (real v3) ----
    reg h_req = 0, h_wr = 0; reg [24:0] h_addr; reg [255:0] h_wdata; reg [31:0] h_wmask;
    wire [255:0] h_rdata; wire h_ready, h_busy;
    wire [27:0] h_app_addr; wire [2:0] h_app_cmd; wire h_app_en, h_app_rdy;
    wire [127:0] h_app_wdf_data; wire h_app_wdf_end; wire [15:0] h_app_wdf_mask; wire h_app_wdf_wren, h_app_wdf_rdy, h_app_rd_data_valid;
    mig_native_adapter #(.BURST_LEN(8), .ADDR_WIDTH(25)) u_ad (
        .clk(clk), .rst(rst), .req(h_req), .wr(h_wr), .addr(h_addr), .wdata(h_wdata), .wmask(h_wmask),
        .rdata(h_rdata), .ready(h_ready), .busy(h_busy),
        .app_addr(h_app_addr), .app_cmd(h_app_cmd), .app_en(h_app_en), .app_rdy(h_app_rdy),
        .app_wdf_data(h_app_wdf_data), .app_wdf_end(h_app_wdf_end), .app_wdf_mask(h_app_wdf_mask),
        .app_wdf_wren(h_app_wdf_wren), .app_wdf_rdy(h_app_wdf_rdy),
        .app_rd_data(app_rd_data), .app_rd_data_end(app_rd_data_end), .app_rd_data_valid(h_app_rd_data_valid));

    // ---- DUT ----
    reg rc_valid = 0; wire rc_pop; reg [24:0] rc_addr; reg [15:0] rc_len;
    reg wc_valid = 0; wire wc_pop; reg [24:0] wc_addr; reg [127:0] wc_data;
    wire rd_push; wire [127:0] rd_word; reg [6:0] rd_cnt = 0;
    wire idle;
    v4_ddr_stream #(.RD_FIFO_DEPTH(64)) dut (
        .clk(clk), .rst(rst),
        .rc_valid(rc_valid), .rc_pop(rc_pop), .rc_addr(rc_addr), .rc_len(rc_len),
        .wc_valid(wc_valid), .wc_pop(wc_pop), .wc_addr(wc_addr), .wc_data(wc_data),
        .rd_push(rd_push), .rd_word(rd_word), .rd_fifo_count(rd_cnt),
        .h_app_addr(h_app_addr), .h_app_cmd(h_app_cmd), .h_app_en(h_app_en), .h_app_rdy(h_app_rdy),
        .h_app_wdf_data(h_app_wdf_data), .h_app_wdf_end(h_app_wdf_end), .h_app_wdf_mask(h_app_wdf_mask),
        .h_app_wdf_wren(h_app_wdf_wren), .h_app_wdf_rdy(h_app_wdf_rdy), .h_app_rd_data_valid(h_app_rd_data_valid),
        .h_busy(h_busy),
        .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en), .app_rdy(app_rdy),
        .app_wdf_data(app_wdf_data), .app_wdf_end(app_wdf_end), .app_wdf_mask(app_wdf_mask), .app_wdf_wren(app_wdf_wren),
        .app_wdf_rdy(app_wdf_rdy), .app_rd_data(app_rd_data), .app_rd_data_end(app_rd_data_end),
        .app_rd_data_valid(app_rd_data_valid), .idle(idle));

    // read FIFO model: occupancy drained by a consumer at random rate
    integer got, exp_w, errors = 0, job, i, len, w0, t0, tot_words = 0, tot_cyc = 0;
    reg drain;
    always @(posedge clk) begin
        drain = ($random & 3) != 0;
        if (rst) rd_cnt <= 0;
        else begin
            if (rd_push && rd_cnt >= 64) begin errors = errors + 1; $display("FAIL: read FIFO overflow"); end
            rd_cnt <= rd_cnt + rd_push - ((rd_cnt != 0 && drain) ? 1 : 0);
        end
        if (!rst && rd_push) begin
            if (rd_word !== mem_snap[exp_w]) begin errors = errors + 1; if (errors < 10) $display("FAIL job %0d word %0d: got %h exp %h", job, got, rd_word, mem_snap[exp_w]); end
            got = got + 1; exp_w = exp_w + 1;
        end
    end
    initial begin
        for (i = 0; i < 8192; i = i + 1) mem[i] = {$random, $random, $random, $random};
        repeat (5) @(posedge clk); @(negedge clk) rst = 0;
        for (job = 0; job < 300; job = job + 1) begin
            // streamer read job
            w0 = ($random & 32'h7fffffff) % 7000; len = 1 + ($random & 32'h7fffffff) % 300;
            if (job % 10 == 0) len = 1;
            for (i = 0; i < 8192; i = i + 1) mem_snap[i] = mem[i];
            got = 0; exp_w = w0;
            @(negedge clk) rc_valid <= 1; rc_addr <= w0; rc_len <= len;
            @(posedge clk); while (!rc_pop) @(posedge clk);
            t0 = cyc;
            @(negedge clk) rc_valid <= 0;
            i = 0; while (got < len && i < 20000) begin @(posedge clk); i = i + 1; end
            if (got != len) begin errors = errors + 1; $display("FAIL job %0d: %0d of %0d words", job, got, len); end
            if (len > 100) begin tot_words = tot_words + len; tot_cyc = tot_cyc + (cyc - t0); end
            repeat (20) @(posedge clk);
            // streamer write job
            if (job % 3 == 0) begin
                w0 = ($random & 32'h7fffffff) % 8000;
                @(negedge clk) wc_valid <= 1; wc_addr <= w0; wc_data <= {$random, $random, $random, $random};
                @(posedge clk); while (!wc_pop) @(posedge clk);
                @(negedge clk) wc_valid <= 0;
                mem_snap[w0 ^ 1] = mem[w0 ^ 1];
                i = 0; while (!idle || i < 30) begin @(posedge clk); i = i + 1; end
                if (mem[w0] !== wc_data) begin errors = errors + 1; $display("FAIL write %0d", w0); end
                if (mem[w0 ^ 1] !== mem_snap[w0 ^ 1]) begin errors = errors + 1; $display("FAIL write clobbered neighbour %0d", w0 ^ 1); end
            end
            // host adapter burst write + read back, while the streamer is idle
            if (job % 4 == 1) begin
                h_addr = 8 * (($random & 32'h7fffffff) % 4000); h_wdata = {8{$random}}; h_wmask = 0;
                @(negedge clk) h_req <= 1; h_wr <= 1;
                @(negedge clk) h_req <= 0;
                i = 0; while (!h_ready && i < 5000) begin @(posedge clk); i = i + 1; end
                @(negedge clk) h_req <= 1; h_wr <= 0;
                @(negedge clk) h_req <= 0;
                i = 0; while (!h_ready && i < 5000) begin @(posedge clk); i = i + 1; end
                @(negedge clk);
                if (h_rdata !== h_wdata) begin errors = errors + 1; $display("FAIL host read-back at %0d", h_addr); end
            end
        end
        $display("=== 300 read jobs, %0d errors; sustained read: %0d words in %0d ui_clk cycles = %0.2f word/cycle (%0.2f GB/s at 155 MHz) ===",
                 errors, tot_words, tot_cyc, tot_words * 1.0 / tot_cyc, tot_words * 16.0 * 155.0e6 / tot_cyc / 1.0e9);
        if (errors == 0) $display("ALL TESTS PASSED (tb_v4_ddr_stream)");
        $finish;
    end
endmodule
