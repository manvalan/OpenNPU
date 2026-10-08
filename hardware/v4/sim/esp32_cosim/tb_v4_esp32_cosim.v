// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps
// ============================================================
// v4 -- ESP32 driver <-> RTL co-simulation (Icarus).
//
// v4_board_top (MIG replaced by sim/mig_7series_0_stub.v, as in
// tb_v4_board_top.v) driven by the REAL ESP32 driver code
// (firmware/esp32/components/fpga_neural, compiled for the host with
// idf_cosim.c): every SPI transaction the driver issues arrives here
// over a named pipe and is played on the pins bit by bit -- Quad-SPI at
// 80 MHz, the board's only host link -- and what the RTL drives on QIO
// goes back to the driver. Request format: idf_cosim.c.
//
// The parameter image (~1 MB) is preloaded into the stub DDR3 to keep
// the run short; header, descriptors and the input image (words
// 0..4095) are cleared, so the driver must load them itself.
//
// sys_rst: the real MIG reset is active low (ESP32 GPIO level 0 =
// reset); the behavioral stub's is active high, hence the inversion.
// ============================================================
module tb;
`ifndef MFN_DIR
    `define MFN_DIR "mfn"
`endif
`ifndef PIPE_DIR
    `define PIPE_DIR "."
`endif
    localparam PIN_SYS_RST = 15, PIN_DATA_READY = 16;

    reg rst_gpio = 1'b1;                    // pull-up on the board: released
    reg stub_rst = 1'b1;
    reg qsclk = 0, qcs_n = 1;
    reg [3:0] qmo = 0; reg qdrive = 0;
    wire [3:0] qio = qdrive ? qmo : 4'bzzzz;
    wire data_ready_n;
    wire flash_cs_n, flash_mosi;
    wire [31:0] ddr3_dq; wire [3:0] ddr3_dqs_n, ddr3_dqs_p;

    v4_board_top dut (
        .sys_clk_p(1'b0), .sys_clk_n(1'b1), .sys_rst(stub_rst),
        .ddr3_dq(ddr3_dq), .ddr3_dqs_n(ddr3_dqs_n), .ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_addr(), .ddr3_ba(), .ddr3_ras_n(), .ddr3_cas_n(), .ddr3_we_n(), .ddr3_reset_n(),
        .ddr3_ck_p(), .ddr3_ck_n(), .ddr3_cke(), .ddr3_cs_n(), .ddr3_dm(), .ddr3_odt(),
        .qsclk(qsclk), .qcs_n(qcs_n), .qio(qio),
        .flash_cs_n(flash_cs_n), .flash_mosi(flash_mosi), .flash_miso(1'b0),
        .data_ready_n(data_ready_n)
    );

    // ---- Quad-SPI, 80 MHz: drive on the falling edge, sample on the rising edge ----
    task automatic qclk_out(input [3:0] n);
        begin qmo = n; #6.25; qsclk = 1; #6.25; qsclk = 0; end
    endtask

    integer fc, fv, rc, n, i, k, nout, nd, nin, v, pin, lvl, code;
    integer n_q, bytes_q, res_w;
    reg [8*8:1] tok;
    reg [7:0] buf_tx [0:65535];
    reg [7:0] rb;
    reg [3:0] nib [0:65535];

    initial begin
        // DDR3: parameters preloaded; header, descriptors, image and the
        // scratch area cleared
        $readmemh({`MFN_DIR, "/ddr_full.hex"}, dut.u_mig.mem);
        res_w = dut.u_mig.mem[17][31:0];        // result address from the boot header
        for (i = 0; i < 4096; i = i + 1) dut.u_mig.mem[i] = 128'd0;
        for (i = res_w; i < res_w + 33; i = i + 1) dut.u_mig.mem[i] = 128'd0;   // up to 32 output words + statistics
        for (i = 96000; i < 96016; i = i + 1) dut.u_mig.mem[i] = 128'd0;
        n_q = 0; bytes_q = 0;
        #100 stub_rst = 1'b0;
        fc = $fopen({`PIPE_DIR, "/cosim_c2v"}, "r");
        fv = $fopen({`PIPE_DIR, "/cosim_v2c"}, "w");
        forever begin
            rc = $fscanf(fc, "%s", tok);
            if (rc != 1) begin $display("FAIL: driver pipe closed"); $finish; end
            if (tok == "Q") begin
                rc = $fscanf(fc, "%d %d", k, nout);
                for (i = 0; i < nout; i = i + 1) begin rc = $fscanf(fc, "%h", v); nib[i] = v; end
                rc = $fscanf(fc, "%d %d", nd, nin);
                if (nout || nd || nin) begin
                    if (qcs_n) begin qcs_n = 0; #10; end
                    if (nout) begin
                        qdrive = 1;
                        for (i = 0; i < nout; i = i + 1) qclk_out(nib[i]);
                    end
                    if (nd || nin) qdrive = 0;          // ESP32 lines switch to input
                    for (i = 0; i < nd; i = i + 1) begin #6.25; qsclk = 1; #6.25; qsclk = 0; end
                    $fwrite(fv, "%0d\n", nin);
                    for (i = 0; i < nin; i = i + 1) begin
                        #6.25; qsclk = 1; $fwrite(fv, "%0d\n", qio); #6.25; qsclk = 0;
                    end
                    n_q = n_q + 1; bytes_q = bytes_q + (nout + nin) / 2;
                end else
                    $fwrite(fv, "0\n");
                if (!k) begin #10; qcs_n = 1; qdrive = 0; #30; end
            end else if (tok == "G") begin
                rc = $fscanf(fc, "%d %d", pin, lvl);
                if (pin == PIN_SYS_RST) begin rst_gpio = lvl; stub_rst = !lvl; end
                $fwrite(fv, "0\n");
            end else if (tok == "L") begin
                rc = $fscanf(fc, "%d", pin);
                $fwrite(fv, "%0d\n", pin == PIN_DATA_READY ? data_ready_n : 0);
            end else if (tok == "D") begin
                rc = $fscanf(fc, "%d", v);
                #(v * 1000.0);
                $fwrite(fv, "0\n");
            end else if (tok == "T") begin
                $fwrite(fv, "%0d\n", $time / 1000);
            end else if (tok == "X") begin
                rc = $fscanf(fc, "%d", code);
                $display("  driver finished (code %0d) at %0t ns: %0d Quad-SPI transactions (%0d bytes)",
                         code, $time, n_q, bytes_q);
                $finish;
            end else begin
                $display("FAIL: unknown request %s", tok); $finish;
            end
            $fflush(fv);
        end
    end
endmodule
