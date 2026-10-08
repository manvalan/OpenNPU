// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ps/100fs
// ============================================================
// v4 -- board-level xsim bench with the REAL MIG IP (mig_7series_0, as
// generated for the board) and two Micron DDR3 models (x16, ganged to
// 32 bits), same structure as v3's tb_n16_system_ddr3_chained_writemem.v.
//
// Purpose: measure the core's cycle count with the REAL DDR3 controller
// behind the parameter streamer, and exercise the real-MIG path of the
// v4 streamer (pipelined reads) and of the boot controller.
//
// The whole DDR3 image of gen_mfn.c (parameters, image) is preloaded
// straight into the two Micron models' storage (loading ~1 MB over the
// simulated SPI would take days); the mapping (MIG BANK_ROW_COLUMN,
// burst = 128-bit words 2P and 2P+1 at app_addr 8P, chip 0 = DQ[15:0])
// is checked by reading two preloaded words back over Quad-SPI. The boot
// header and the descriptor table then go over a Quad-SPI WRITE.
// N_PASS (default all 40) limits the network: the last descriptor sent
// gets its `last` bit set; with 40 passes the embedding read back over
// Quad-SPI is compared with the golden model.
// Then: REG_WRITE NETWORK_BASE, REG_WRITE start, poll STATUS, READ the
// statistics word -- all over the Quad-SPI port, the only host link.
// ============================================================
module tb;
`ifndef MFN_DIR
    `define MFN_DIR "/tmp/claude-1000/mfn2"
`endif
`ifndef N_PASS
    `define N_PASS 40
`endif
    localparam real OSC_HALF = 2500.0;  // ps: the board's single 200 MHz oscillator (MMCM -> MIG 310 MHz)
    localparam RESET_PERIOD = 200000;
    localparam HDR_W = 16, DESC_W = 64, IMG_W = 256, PARAM_W = 4096, RESULT_W = 80000;

    reg sys_rst_n;
    wire sys_rst = sys_rst_n;          // same polarity convention as the v3 bench
    reg osc = 1'b0;
    always #OSC_HALF osc = ~osc;
    initial begin sys_rst_n = 1'b0; #RESET_PERIOD sys_rst_n = 1'b1; end

    wire        ddr3_reset_n;
    wire [31:0] ddr3_dq_fpga;
    wire [3:0]  ddr3_dqs_p_fpga, ddr3_dqs_n_fpga;
    wire [13:0] ddr3_addr_fpga;
    wire [2:0]  ddr3_ba_fpga;
    wire        ddr3_ras_n_fpga, ddr3_cas_n_fpga, ddr3_we_n_fpga;
    wire [0:0]  ddr3_cke_fpga, ddr3_ck_p_fpga, ddr3_ck_n_fpga, ddr3_cs_n_fpga;
    wire [3:0]  ddr3_dm_fpga;
    wire [0:0]  ddr3_odt_fpga;
    wire [31:0] ddr3_dq_sdram;
    wire [3:0]  ddr3_dqs_p_sdram, ddr3_dqs_n_sdram;

    genvar dq;
    generate
        for (dq = 0; dq < 32; dq = dq + 1) begin : dq_delay
            WireDelay #(.Delay_g(0.00), .Delay_rd(0.00), .ERR_INSERT("OFF")) u_delay_dq (
                .A(ddr3_dq_fpga[dq]), .B(ddr3_dq_sdram[dq]), .reset(sys_rst_n), .phy_init_done(dut.init_calib_complete));
        end
        for (dq = 0; dq < 4; dq = dq + 1) begin : dqs_delay
            WireDelay #(.Delay_g(0.00), .Delay_rd(0.00), .ERR_INSERT("OFF")) u_delay_dqs_p (
                .A(ddr3_dqs_p_fpga[dq]), .B(ddr3_dqs_p_sdram[dq]), .reset(sys_rst_n), .phy_init_done(dut.init_calib_complete));
            WireDelay #(.Delay_g(0.00), .Delay_rd(0.00), .ERR_INSERT("OFF")) u_delay_dqs_n (
                .A(ddr3_dqs_n_fpga[dq]), .B(ddr3_dqs_n_sdram[dq]), .reset(sys_rst_n), .phy_init_done(dut.init_calib_complete));
        end
        for (dq = 0; dq < 2; dq = dq + 1) begin : gen_mem
            ddr3_model #(.DEBUG(0), .MEM_BITS(17)) u_comp_ddr3 (
                .rst_n(ddr3_reset_n), .ck(ddr3_ck_p_fpga), .ck_n(ddr3_ck_n_fpga),
                .cke(ddr3_cke_fpga[0]), .cs_n(ddr3_cs_n_fpga[0]),
                .ras_n(ddr3_ras_n_fpga), .cas_n(ddr3_cas_n_fpga), .we_n(ddr3_we_n_fpga),
                .dm_tdqs(ddr3_dm_fpga[2*dq +: 2]), .ba(ddr3_ba_fpga), .addr(ddr3_addr_fpga),
                .dq(ddr3_dq_sdram[16*dq +: 16]),
                .dqs(ddr3_dqs_p_sdram[2*dq +: 2]), .dqs_n(ddr3_dqs_n_sdram[2*dq +: 2]),
                .tdqs_n(), .odt(ddr3_odt_fpga[0]));
        end
    endgenerate

    reg qsclk = 0, qcs_n = 1;
    reg [3:0] qmo = 0; reg qdrive = 0;
    wire [3:0] qio = qdrive ? qmo : 4'bzzzz;
    wire data_ready_n, flash_cs_n, flash_mosi;

    v4_board_top dut (
        .sys_clk_p(osc), .sys_clk_n(~osc), .sys_rst(sys_rst),
        .ddr3_dq(ddr3_dq_fpga), .ddr3_dqs_n(ddr3_dqs_n_fpga), .ddr3_dqs_p(ddr3_dqs_p_fpga),
        .ddr3_addr(ddr3_addr_fpga), .ddr3_ba(ddr3_ba_fpga),
        .ddr3_ras_n(ddr3_ras_n_fpga), .ddr3_cas_n(ddr3_cas_n_fpga), .ddr3_we_n(ddr3_we_n_fpga),
        .ddr3_reset_n(ddr3_reset_n),
        .ddr3_ck_p(ddr3_ck_p_fpga), .ddr3_ck_n(ddr3_ck_n_fpga),
        .ddr3_cke(ddr3_cke_fpga), .ddr3_cs_n(ddr3_cs_n_fpga),
        .ddr3_dm(ddr3_dm_fpga), .ddr3_odt(ddr3_odt_fpga),
        .qsclk(qsclk), .qcs_n(qcs_n), .qio(qio),
        .flash_cs_n(flash_cs_n), .flash_mosi(flash_mosi), .flash_miso(1'b0),
        .data_ready_n(data_ready_n)
    );

    // ---- Quad-SPI master, 80 MHz (ps units), as tb_v4_board_top.v ----
    task automatic qclk_out(input [3:0] n);
        begin qmo = n; #6250; qsclk = 1; #6250; qsclk = 0; end
    endtask
    task automatic qheader(input [7:0] cmd, input [31:0] W, input [15:0] len);
        integer i; reg [55:0] h;
        begin
            h = {cmd, W, len}; qdrive = 1; qcs_n = 0; #10000;
            for (i = 13; i >= 0; i = i - 1) qclk_out(h[i*4 +: 4]);
        end
    endtask
    reg [127:0] wbuf [0:255];
    task automatic qwrite_words(input integer W, input integer n);
        integer k, j;
        begin
            qheader(8'h1A, W, n);
            for (k = 0; k < n; k = k + 1)
                for (j = 0; j < 16; j = j + 1) begin qclk_out(wbuf[k][j*8+4 +: 4]); qclk_out(wbuf[k][j*8 +: 4]); end
            #10000 qcs_n = 1; qdrive = 0; #30000;
        end
    endtask
    // READ (0x2A) / STATUS (0x4A): 64 dummy clocks, then n words
    task automatic qread_cmd(input [7:0] cmd, input integer W, input integer n);
        integer k, j;
        begin
            qheader(cmd, W, n);
            qdrive = 0;
            for (k = 0; k < 64; k = k + 1) begin #6250; qsclk = 1; #6250; qsclk = 0; end
            for (k = 0; k < n; k = k + 1)
                for (j = 0; j < 16; j = j + 1) begin
                    #6250; qsclk = 1; wbuf[k][j*8+4 +: 4] = qio; #6250; qsclk = 0;
                    #6250; qsclk = 1; wbuf[k][j*8 +: 4] = qio; #6250; qsclk = 0;
                end
            #10000 qcs_n = 1; #30000;
        end
    endtask
    task automatic q_read_word128(input integer W, output [127:0] v);
        begin qread_cmd(8'h2A, W, 1); v = wbuf[0]; end
    endtask
    task automatic qreg_write(input [15:0] r, input [31:0] v);
        begin qheader(8'h3A, v, r); #10000 qcs_n = 1; qdrive = 0; #30000; end
    endtask
    task automatic qstatus(output [127:0] s);
        begin qread_cmd(8'h4A, 0, 1); s = wbuf[0]; end
    endtask

    // images from gen_mfn.c's ddr_full.hex (header @16, descriptors @64)
    reg [127:0] img [0:131071];
    integer i, polls, errors;
    // expected embedding (pass 39 of expect.txt), checked when N_PASS == 40
    reg [127:0] exp_out [0:7];
    integer fexp, rc, p, nw, base;
    reg [8*16-1:0] tag;
    reg [127:0] ew;
    // preload (after the models' RESET_N erase): every non-zero 256-bit burst into both models'
    // storage arrays (the model's own memory_write does a linear search
    // per call; filling the arrays directly is O(n))
    task automatic preload_ddr3;
        integer pp, k, n;
        reg [255:0] d;
        reg [27:0]  a;
        reg [127:0] c0, c1;
        begin
            n = gen_mem[0].u_comp_ddr3.memory_used;   // append (normally 0)
            for (pp = 0; pp < 65536; pp = pp + 1) begin
                d = {img[2*pp + 1], img[2*pp]};
                if (d !== 256'd0 && (^d !== 1'bx)) begin
                    a = 8 * pp;                       // app_addr = {bank[26:24], row[23:10], col[9:0]}
                    for (k = 0; k < 8; k = k + 1) begin
                        c0[16*k +: 16] = d[32*k      +: 16];
                        c1[16*k +: 16] = d[32*k + 16 +: 16];
                    end
                    gen_mem[0].u_comp_ddr3.address[n] = a[26:3];
                    gen_mem[0].u_comp_ddr3.memory[n]  = c0;
                    gen_mem[1].u_comp_ddr3.address[n] = a[26:3];
                    gen_mem[1].u_comp_ddr3.memory[n]  = c1;
                    n = n + 1;
                end
            end
            gen_mem[0].u_comp_ddr3.memory_used = n;
            gen_mem[1].u_comp_ddr3.memory_used = n;
            $display("  DDR3 preload: %0d bursts per chip", n);
        end
    endtask
    reg [127:0] st;
    reg [127:0] w;
    time t0, t1;
    initial begin
        errors = 0;
        $readmemh({`MFN_DIR, "/ddr_full.hex"}, img);
        fexp = $fopen({`MFN_DIR, "/expect.txt"}, "r");
        while (!$feof(fexp)) begin
            rc = $fscanf(fexp, "%s %d %d %d\n", tag, p, base, nw);
            for (i = 0; i < nw; i = i + 1) begin
                rc = $fscanf(fexp, "%h\n", ew);
                if (p == 39) exp_out[i] = ew;
            end
        end
        $fclose(fexp);
        wait (sys_rst_n);
        // the models erase their storage when RESET_N rises: preload after
        wait (ddr3_reset_n === 1'b1);
        #100000;
        preload_ddr3;
        wait (dut.init_calib_complete);
        $display("[%0t] calibration complete", $time);
        #1000000;
        // backdoor mapping check: two preloaded words read back over Quad-SPI
        q_read_word128(PARAM_W + 1, ew);
        if (ew !== img[PARAM_W + 1]) begin errors = errors + 1; $display("FAIL preload W=%0d: got %h exp %h", PARAM_W + 1, ew, img[PARAM_W + 1]); end
        q_read_word128(IMG_W + 2, ew);
        if (ew !== img[IMG_W + 2]) begin errors = errors + 1; $display("FAIL preload W=%0d: got %h exp %h", IMG_W + 2, ew, img[IMG_W + 2]); end
        if (errors) begin $display("=== preload mapping wrong, stopping ==="); $finish; end
        $display("  DDR3 preload read back over Quad-SPI: OK");
        // header, with n_pass = N_PASS
        wbuf[0] = img[HDR_W]; wbuf[0][15:0] = `N_PASS;
        wbuf[1] = img[HDR_W + 1];
        qwrite_words(HDR_W, 2);
        // descriptor table (3 words per pass), last flag on pass N_PASS-1
        for (i = 0; i < 3 * `N_PASS; i = i + 1) wbuf[i] = img[DESC_W + i];
        wbuf[3 * (`N_PASS - 1)][3] = 1'b1;
        qwrite_words(DESC_W, 3 * `N_PASS);
        $display("[%0t] header + %0d descriptors written over Quad-SPI", $time, `N_PASS);

        qreg_write(16'h0004, HDR_W * 4);
        t0 = $time;
        qreg_write(16'h0001, 32'h2);
        st = 0; polls = 0;
        while (!st[67] && polls < 100000) begin
            #20000000;
            qstatus(st);
            polls = polls + 1;
        end
        t1 = $time;
        if (!st[67]) begin errors = errors + 1; $display("FAIL: no done, STATUS flags %b", st[68:64]); end
        if (st[31:0] !== 32'h4E505604) begin errors = errors + 1; $display("FAIL: STATUS ID %h", st[31:0]); end
        q_read_word128(RESULT_W + 8, w);     // statistics word after the 8 output words
        $display("  STATUS flags %b; start->done seen by the host %0t ps", st[68:64], t1 - t0);
        $display("  stats (REAL MIG + DDR3 model): core cycles %0d, waiting for parameters %0d, error %0d, magic %h",
                 w[31:0], w[63:32], w[64], w[127:96]);
        if (w[127:96] !== 32'h344E4E56) begin errors = errors + 1; $display("FAIL: stats magic"); end
        if (`N_PASS == 40) begin
            // the embedding read back over Quad-SPI, compared with the C
            // golden model
            for (i = 0; i < 8; i = i + 1) begin
                q_read_word128(RESULT_W + i, ew);
                if (ew !== exp_out[i]) begin
                    errors = errors + 1;
                    $display("FAIL embedding word %0d: got %h exp %h", i, ew, exp_out[i]);
                end
            end
            $display("  embedding (8 words over Quad-SPI): %s", errors ? "MISMATCH" : "bit-exact");
        end
        $display("=== v4 board, real MIG: %0d passes, %0d core cycles (%0d waiting for DDR3), %0d errors ===",
                 `N_PASS, w[31:0], w[63:32], errors);
        $finish;
    end
endmodule
