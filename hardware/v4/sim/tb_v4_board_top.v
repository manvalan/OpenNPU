// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps
// ============================================================
// v4 -- whole-board simulation of v4_board_top.v (Icarus): Quad-SPI
// host port + mig_native_adapter + v4_ddr_stream + CDC FIFOs + v4_boot +
// v4_core + flash master, two unrelated clocks (ui_clk 155.039 MHz,
// core ~199.34 MHz), the MIG replaced by sim/mig_7series_0_stub.v
// (behavioral app port; the real MIG runs in the xsim bench).
//
// The DDR3 image (header, descriptors, raw image, parameters) is
// preloaded into the stub's memory, except the image. Over the one
// Quad-SPI link this bench does what the ESP32 does per inference:
// WRITE the image, REG_WRITE NETWORK_BASE, REG_WRITE CONTROL.start,
// wait for data_ready_n, read STATUS, READ the result. The output and
// the statistics word are compared with the C golden. Then a
// FLASH_XFER / FLASH_READ round trip with flash_miso looped back to
// flash_mosi (every response byte = the byte sent).
// ============================================================
module tb;
`ifndef MFN_DIR
    `define MFN_DIR "/tmp/claude-1000/mfn2"
`endif
    localparam HDR_W = 16;
    integer RESULT_W, NOUT;     // from the header in ddr_full.hex (any network)
    integer IMG_A, IMG_N;       // image address and words, from the header

    reg sys_rst = 1;
    reg qsclk = 0, qcs_n = 1;
    reg [3:0] qmo = 0; reg qdrive = 0;
    wire [3:0] qio = qdrive ? qmo : 4'bzzzz;
    wire data_ready_n;
    wire init_calib_complete = dut.init_calib_complete;
    wire flash_cs_n, flash_mosi;
    wire [31:0] ddr3_dq; wire [3:0] ddr3_dqs_n, ddr3_dqs_p;

    v4_board_top dut (
        .sys_clk_p(1'b0), .sys_clk_n(1'b1), .sys_rst(sys_rst),
        .ddr3_dq(ddr3_dq), .ddr3_dqs_n(ddr3_dqs_n), .ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_addr(), .ddr3_ba(), .ddr3_ras_n(), .ddr3_cas_n(), .ddr3_we_n(), .ddr3_reset_n(),
        .ddr3_ck_p(), .ddr3_ck_n(), .ddr3_cke(), .ddr3_cs_n(), .ddr3_dm(), .ddr3_odt(),
        .qsclk(qsclk), .qcs_n(qcs_n), .qio(qio),
        .flash_cs_n(flash_cs_n), .flash_mosi(flash_mosi), .flash_miso(flash_mosi),
        .data_ready_n(data_ready_n)
    );

    // ---- Quad-SPI data-port master (ESP32 SPI2 in QIO, 80 MHz) ----
    task automatic qclk_out(input [3:0] n);
        begin qmo = n; #6.25; qsclk = 1; #6.25; qsclk = 0; end
    endtask
    task automatic qheader(input [7:0] cmd, input [31:0] W, input [15:0] len);
        integer i; reg [55:0] h;
        begin
            h = {cmd, W, len}; qdrive = 1; qcs_n = 0; #10;
            for (i = 13; i >= 0; i = i - 1) qclk_out(h[i*4 +: 4]);
        end
    endtask
    reg [127:0] qbuf [0:16383];
    task automatic qwrite(input [31:0] W, input integer n);
        integer i, j;
        begin
            qheader(8'h1A, W, n);
            for (i = 0; i < n; i = i + 1)
                for (j = 0; j < 16; j = j + 1) begin qclk_out(qbuf[i][j*8+4 +: 4]); qclk_out(qbuf[i][j*8 +: 4]); end
            #10 qcs_n = 1; qdrive = 0; #30;
        end
    endtask
    task automatic qread(input [31:0] W, input integer n);
        qread_cmd(8'h2A, W, n);
    endtask
    task automatic qread_cmd(input [7:0] cmd, input [31:0] W, input integer n);
        integer i, j;
        begin
            qheader(cmd, W, n);
            qdrive = 0;
            for (i = 0; i < 64; i = i + 1) begin #6.25; qsclk = 1; #6.25; qsclk = 0; end
            for (i = 0; i < n; i = i + 1)
                for (j = 0; j < 16; j = j + 1) begin
                    #6.25; qsclk = 1; qbuf[i][j*8+4 +: 4] = qio; #6.25; qsclk = 0;
                    #6.25; qsclk = 1; qbuf[i][j*8 +: 4] = qio; #6.25; qsclk = 0;
                end
            #10 qcs_n = 1; #30;
        end
    endtask
    // header-only command (REG_WRITE): CS rises right after the header
    task automatic qreg_write(input [15:0] r, input [31:0] v);
        begin qheader(8'h3A, v, r); #10 qcs_n = 1; qdrive = 0; #30; end
    endtask
    task automatic qstatus(output [127:0] s);
        begin qread_cmd(8'h4A, 0, 1); s = qbuf[0]; end
    endtask

    // expected output: the last region of expect.txt (written by the last
    // pass: any network's output, up to 16384 words)
    reg [127:0] exp_out [0:16383];
    integer fexp, rc, p, base, nw, i, errors, polls;
    reg [8*16-1:0] tag;
    reg [127:0] w;
    reg [127:0] st;
    reg [127:0] ftx [0:1];
    integer fn, k;
    time t_start, t_done;

    initial begin
        errors = 0;
        $readmemh({`MFN_DIR, "/ddr_full.hex"}, dut.u_mig.mem);
        fexp = $fopen({`MFN_DIR, "/expect.txt"}, "r");
        while (!$feof(fexp)) begin
            rc = $fscanf(fexp, "%s %d %d %d\n", tag, p, base, nw);
            for (i = 0; i < nw; i = i + 1) begin
                rc = $fscanf(fexp, "%h\n", w);
                if (i < 16384) exp_out[i] = w;
            end
        end
        w = dut.u_mig.mem[HDR_W + 1];
        RESULT_W = w[31:0];
        NOUT = w[63:48];
        w = dut.u_mig.mem[HDR_W];
        IMG_A = w[79:48];
        IMG_N = w[95:80];
        $display("  header: image @%0d, %0d words; result @%0d, %0d output words", IMG_A, IMG_N, RESULT_W, NOUT);
        // the image goes over the Quad-SPI data port, like the ESP32 will
        // send it per inference: clear it in the preloaded DDR3 first
        for (i = 0; i < IMG_N; i = i + 1) begin qbuf[i] = dut.u_mig.mem[IMG_A + i]; dut.u_mig.mem[IMG_A + i] = 128'd0; end
        #100 sys_rst = 0;
        wait (init_calib_complete);
        #500;
        t_start = $time;
        qwrite(IMG_A, IMG_N);
        $display("  image (%0d words, %0d bytes) written over Quad-SPI in %0t ns", IMG_N, IMG_N * 16, $time - t_start);
        qreg_write(16'h0004, HDR_W * 4);        // header: 32-bit-word address
        qstatus(st);
        if (st[31:0] !== 32'h4E505604) begin errors = errors + 1; $display("FAIL STATUS ID %h", st[31:0]); end
        if (st[63:32] !== HDR_W * 4) begin errors = errors + 1; $display("FAIL NETWORK_BASE readback %h", st[63:32]); end
        if (st[64] !== 1'b1 || st[67:65] !== 3'b000) begin errors = errors + 1; $display("FAIL STATUS flags before start %h", st[68:64]); end
        if (data_ready_n !== 1'b1) begin errors = errors + 1; $display("FAIL data_ready_n low before start"); end
        t_start = $time;
        qreg_write(16'h0001, 32'h2);            // CONTROL.start
        #1000;
        qstatus(st);
        if (st[66] !== 1'b1) begin errors = errors + 1; $display("FAIL busy not set after start (STATUS %h)", st[68:64]); end
        polls = 0;
        while (data_ready_n && polls < 4000000) begin #100; polls = polls + 1; end
        t_done = $time;
        qstatus(st);
        if (!st[67]) begin errors = errors + 1; $display("FAIL: no done (STATUS %h)", st[68:64]); end
        if (st[65])  begin errors = errors + 1; $display("FAIL: error flag in STATUS %h", st[68:64]); end
        #200;
        if (data_ready_n !== 1'b1) begin errors = errors + 1; $display("FAIL data_ready_n still low after STATUS read"); end
        $display("  data_ready_n low %0t ns after start; STATUS flags %b", t_done - t_start, st[68:64]);

        for (i = 0; i < NOUT; i = i + 1) begin
            if (dut.u_mig.mem[RESULT_W + i] !== exp_out[i]) begin
                errors = errors + 1;
                $display("FAIL output word %0d: got %h exp %h", i, dut.u_mig.mem[RESULT_W + i], exp_out[i]);
            end
        end
        w = dut.u_mig.mem[RESULT_W + NOUT];
        $display("  stats word: cycles %0d, waiting for parameters %0d, error %0d, magic %h",
                 w[31:0], w[63:32], w[64], w[127:96]);
        if (w[127:96] !== 32'h344E4E56) begin errors = errors + 1; $display("FAIL stats magic"); end
        // the embedding + stats back over the Quad-SPI data port
        qread(RESULT_W, NOUT + 1);
        for (i = 0; i < NOUT; i = i + 1)
            if (qbuf[i] !== exp_out[i]) begin errors = errors + 1; $display("FAIL QSPI read word %0d: %h", i, qbuf[i]); end
        if (qbuf[NOUT] !== w) begin errors = errors + 1; $display("FAIL QSPI stats word"); end
        // configuration-flash pass-through: 20 bytes in one transaction
        // (flash_miso = flash_mosi: each response byte is the byte sent)
        fn = 20;
        ftx[0] = 128'h0F1E2D3C4B5A69788796A5B4C3D2E1F0;
        ftx[1] = 128'h0;
        ftx[1][31:0] = 32'hDEADBEEF;
        qbuf[0] = ftx[0]; qbuf[1] = ftx[1];
        qheader(8'h5A, 0, fn);
        for (i = 0; i < 2; i = i + 1)
            for (k = 0; k < 16; k = k + 1) begin qclk_out(qbuf[i][k*8+4 +: 4]); qclk_out(qbuf[i][k*8 +: 4]); end
        #10 qcs_n = 1; qdrive = 0; #30;
        qstatus(st);
        if (st[68] !== 1'b1) begin errors = errors + 1; $display("FAIL flash busy not set"); end
        if (flash_cs_n !== 1'b0) begin errors = errors + 1; $display("FAIL flash_cs_n high during the transaction"); end
        polls = 0;
        while (st[68] && polls < 1000) begin #1000; qstatus(st); polls = polls + 1; end
        if (st[68]) begin errors = errors + 1; $display("FAIL flash transaction never ended"); end
        if (flash_cs_n !== 1'b1) begin errors = errors + 1; $display("FAIL flash_cs_n low after the transaction"); end
        qread_cmd(8'h6A, 0, 2);
        if (qbuf[0] !== ftx[0] || qbuf[1] !== ftx[1]) begin
            errors = errors + 1; $display("FAIL FLASH_READ %h %h", qbuf[0], qbuf[1]);
        end else $display("  FLASH_XFER 20 bytes + FLASH_READ: loopback bytes back in order (%0d status polls)", polls);
        $display("=== v4 board top: output %s, %0d errors; core cycles %0d at 199.34 MHz = %0d us ===",
                 errors ? "MISMATCH" : "bit-exact", errors, w[31:0], (w[31:0] * 64'd5017) / 1000000);
        if (errors == 0) $display("ALL TESTS PASSED (tb_v4_board_top)");
        $finish;
    end
endmodule
