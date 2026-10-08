// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- whole MobileFaceNet on v4_core.v, checked against the C golden
// (hardware/v4/model/gen_mfn.c). Loads the descriptor list, all
// weights/params and the conv1 input, runs every engine pass back to
// back, and when each pass finishes compares its whole output tensor
// in the feature-map memory word by word against the golden. Reports
// the measured cycle count per pass and in total.
//
// +define+MFN_DIR="\"<dir>\"" points at gen_mfn's output directory.
// ============================================================
module tb;
`ifndef MFN_DIR
    `define MFN_DIR "/tmp/claude-1000/mfn"
`endif
    reg clk = 0;
    always #2.5 clk = ~clk;      // 200 MHz nominal (cycle counts do not depend on it)
    reg rst, start;
    wire done, error;
    wire [31:0] cycles;

    reg          host_we, host_re;
    reg  [2:0]   host_sel;
    reg  [15:0]  host_addr;
    reg  [3:0]   host_chunk;
    reg  [127:0] host_wdata;
    wire         host_rvalid;
    wire [127:0] host_rdata;

    wire         ddr_req_valid, ddr_rvalid;
    reg          ddr_req_ready;
    wire [24:0]  ddr_req_addr;
    wire [15:0]  ddr_req_len;
    reg  [127:0] ddr_rdata;
    reg          ddr_rvalid_r;
    assign ddr_rvalid = ddr_rvalid_r;

    // on-chip sizes of the real plan: weight ring 2 x 256 words, param
    // buffers 2 x 32 rows (double-buffered by pass)
    // descriptor table in the DDR3 model (3 words per pass), above the parameters
`ifndef DESC_BASE
    `define DESC_BASE 1044480
`endif
    v4_core #(.NDESC(64), .WDEPTH(512), .DWDEPTH(64), .PWDEPTH(64)) dut (
        .clk(clk), .rst(rst), .start(start), .done(done), .cycles(cycles), .error(error),
        .host_we_i(host_we), .host_re_i(host_re), .host_sel_i(host_sel), .host_addr_i(host_addr),
        .host_chunk_i(host_chunk), .host_wdata_i(host_wdata),
        .host_rvalid(host_rvalid), .host_rdata(host_rdata),
        .desc_base(25'd`DESC_BASE),
        .ddr_req_valid(ddr_req_valid), .ddr_req_ready(ddr_req_ready),
        .ddr_req_addr(ddr_req_addr), .ddr_req_len(ddr_req_len),
        .ddr_rvalid(ddr_rvalid), .ddr_rdata(ddr_rdata)
    );

    // ---- DDR3 model: first word LAT cycles after a request, then a
    // sustained rate of RN/RD 128-bit words per core cycle (token bucket).
    // Default 5/8 word/cycle = 2.0 GB/s at 200 MHz: 80 % of the board's
    // 32-bit DDR3-620 channel peak (2.48 GB/s). This is a MODEL of the
    // memory, not a measurement: the MIG is not in this simulation.
`ifndef DDR_RN
    `define DDR_RN 5
`endif
`ifndef DDR_RD
    `define DDR_RD 8
`endif
`ifndef DDR_LAT
    `define DDR_LAT 60
`endif
    reg [127:0] ddr [0:1048575];
    integer dm_left, dm_addr, dm_wait, dm_tok, ddr_words;
    always @(posedge clk) begin
        ddr_rvalid_r <= 1'b0;
        if (rst) begin
            dm_left = 0; ddr_req_ready <= 1'b1; ddr_words = 0;
        end else begin
            if (ddr_req_valid && ddr_req_ready) begin
                dm_left = ddr_req_len; dm_addr = ddr_req_addr; dm_wait = `DDR_LAT; dm_tok = 0;
                ddr_req_ready <= 1'b0;
            end else if (dm_left > 0) begin
                if (dm_wait > 0) dm_wait = dm_wait - 1;
                else begin
                    dm_tok = dm_tok + `DDR_RN;
                    if (dm_tok >= `DDR_RD) begin
                        dm_tok = dm_tok - `DDR_RD;
                        ddr_rvalid_r <= 1'b1;
                        ddr_rdata <= ddr[dm_addr];
                        dm_addr = dm_addr + 1; dm_left = dm_left - 1; ddr_words = ddr_words + 1;
                        if (dm_left == 0) ddr_req_ready <= 1'b1;
                    end
                end
            end
        end
    end

    // images loaded through the real host port
    reg [255:0]  i_desc  [0:255];
    reg [127:0]  i_ldesc [0:255];
    reg [2047:0] i_w     [0:8191];
    reg [1151:0] i_dww   [0:255];
    reg [639:0]  i_dwq   [0:255];
    reg [639:0]  i_pwq   [0:511];
    task hwrite(input [2:0] sel, input integer a, input integer ch, input [127:0] dat);
        begin
            @(negedge clk);
            host_we <= 1; host_sel <= sel; host_addr <= a; host_chunk <= ch; host_wdata <= dat;
            @(negedge clk);
            host_we <= 0;
        end
    endtask

    reg [127:0] init [0:24575];
    integer i, errors, checked_words, passes_checked, rb_addr;

    // read one feature-map word through the bank arrays
    function [127:0] fm(input integer a);
        begin
            // each bank = two 4K halves (fmap_mem.v)
            case (a / 4096)
                0: fm = dut.u_fmap.GEN_BANK[0].mem_l[a % 4096];
                1: fm = dut.u_fmap.GEN_BANK[0].mem_h[a % 4096];
                2: fm = dut.u_fmap.GEN_BANK[1].mem_l[a % 4096];
                3: fm = dut.u_fmap.GEN_BANK[1].mem_h[a % 4096];
                4: fm = dut.u_fmap.GEN_BANK[2].mem_l[a % 4096];
                default: fm = dut.u_fmap.GEN_BANK[2].mem_h[a % 4096];
            endcase
        end
    endfunction

    // expected-output file, consumed pass by pass
    integer fexp, rc, e_pass, e_base, e_words, k;
    reg [127:0] ew;
    reg have_hdr;
    reg [8*16-1:0] tag;

    task read_hdr;
        begin
            rc = $fscanf(fexp, "%s %d %d %d\n", tag, e_pass, e_base, e_words);
            have_hdr = (rc == 4);
        end
    endtask

    // compare after each pass (sequencer state S_NEXT)
    integer bad;
    always @(posedge clk) begin
        if (!rst && dut.state == 3'd4) begin
            if (have_hdr && e_pass == dut.li) begin
                bad = 0;
                for (k = 0; k < e_words; k = k + 1) begin
                    rc = $fscanf(fexp, "%h\n", ew);
                    if (fm(e_base + k) !== ew) begin
                        bad = bad + 1;
                        if (bad <= 5) $display("  FAIL pass %0d word %0d (addr %0d): got %h exp %h",
                                               e_pass, k, e_base + k, fm(e_base + k), ew);
                    end
                end
                checked_words = checked_words + e_words;
                passes_checked = passes_checked + 1;
                errors = errors + bad;
                $display("  pass %0d: output tensor %0d words %s", e_pass, e_words, bad ? "MISMATCH" : "bit-exact");
                read_hdr;
            end
        end
    end

    integer wd;
    initial begin
        errors = 0; checked_words = 0; passes_checked = 0;
        host_we = 0; host_re = 0; host_sel = 0; host_addr = 0; host_chunk = 0; host_wdata = 0;
        for (i = 0; i < 256; i = i + 1)  i_desc[i] = 0;
        for (i = 0; i < 8192; i = i + 1) i_w[i] = {2048{1'bx}};
        $readmemh({`MFN_DIR, "/desc.hex"},   i_desc);
        for (i = 0; i < 256; i = i + 1) i_ldesc[i] = 0;
        $readmemh({`MFN_DIR, "/ldesc.hex"},  i_ldesc);
        $readmemh({`MFN_DIR, "/ddr.hex"},    ddr);
        $readmemh({`MFN_DIR, "/wmem.hex"},   i_w);
        $readmemh({`MFN_DIR, "/dwwmem.hex"}, i_dww);
        $readmemh({`MFN_DIR, "/dwqmem.hex"}, i_dwq);
        $readmemh({`MFN_DIR, "/pwqmem.hex"}, i_pwq);
        for (i = 0; i < 24576; i = i + 1) init[i] = 128'd0;
        $readmemh({`MFN_DIR, "/fmap_init.hex"}, init);
        rst = 1; start = 0;
        repeat (5) @(posedge clk);
        @(negedge clk) rst = 0;
        // descriptors stay in DDR3: the core reads them pass by pass
        for (i = 0; i < 256; i = i + 1) begin
            if (ddr[`DESC_BASE + 3*i] !== 128'bx || ddr[`DESC_BASE + 3*i + 2] !== 128'bx) begin
                $display("FAIL: DDR model already holds data at the descriptor table"); $finish;
            end
            ddr[`DESC_BASE + 3*i]     = i_desc[i][127:0];
            ddr[`DESC_BASE + 3*i + 1] = i_desc[i][255:128];
            ddr[`DESC_BASE + 3*i + 2] = i_ldesc[i];
        end
        // weights / params are NOT written on chip: the core streams them
        // from the DDR3 model pass by pass (param_loader.v)
        for (i = 0; i < 24576; i = i + 1)
            if (init[i] !== 128'd0) hwrite(3'd5, i, 0, init[i]);
        // host read-back check of one input word through the read port
        // (the sixth word of the image, wherever the generator put it)
        rb_addr = -1;
        for (i = 0; i < 24576; i = i + 1)
            if (rb_addr < 0 && init[i] !== 128'd0) rb_addr = i + 5;
        @(negedge clk); host_re <= 1; host_sel <= 3'd6; host_addr <= rb_addr;
        @(negedge clk); host_re <= 0;
        while (!host_rvalid) @(negedge clk);
        if (host_rdata !== init[rb_addr]) begin errors = errors + 1; $display("FAIL host read-back"); end
        else $display("  host port: images loaded, read-back OK");
        fexp = $fopen({`MFN_DIR, "/expect.txt"}, "r");
        read_hdr;

        @(negedge clk) start = 1;
        @(negedge clk) start = 0;
        wd = 0;
        while (!done && wd < 20000000) begin @(negedge clk); wd = wd + 1; end
        if (!done) begin errors = errors + 1; $display("FAIL: watchdog, no done"); end
        if (error) begin errors = errors + 1; $display("FAIL: core error flag (bank conflict / writer overflow)"); end
        $display("=== network on v4_core: %0d passes checked, %0d words, %0d errors; TOTAL %0d cycles (DDR model %0d/%0d word/cycle, latency %0d; %0d words streamed) ===",
                 passes_checked, checked_words, errors, cycles, `DDR_RN, `DDR_RD, `DDR_LAT, ddr_words);
        if (errors == 0) $display("ALL TESTS PASSED (tb_v4_core_mfn)");
        $finish;
    end
endmodule
