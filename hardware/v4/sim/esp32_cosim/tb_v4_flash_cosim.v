// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps
// ============================================================
// v4 -- ESP32 config-flash driver <-> RTL co-simulation (Icarus).
// Fork of tb_v4_esp32_cosim.v (same pipe protocol, idf_cosim.c) with:
//   - a W25Q32JV model (sim/w25q32_model.v) on flash_cs_n / flash_mosi /
//     flash_miso, clocked by the flash master's CCLK (the STARTUPE2
//     USRCCLKO net, dut.u_flash.usr_cclk -- E9 on the board);
//   - PROGRAM_B / INIT_B / DONE as ESP32 GPIOs 17/18/19. The FPGA's own
//     configuration from flash is NOT simulated: after a PROGRAM_B pulse
//     the bench raises INIT_B after 5 us and DONE 50 us later only if the
//     flash starts like a 7-series bitstream (sync word 0xAA995566 in the
//     first 256 bytes); otherwise INIT_B goes low again (CRC-error look)
//     and DONE stays low. The RTL is not reset by the pulse.
// Flash bytes 0..0x2FFFF are preloaded with a pattern (garbage that must
// be erased or preserved), the rest erased. At the end the bench compares
// the flash array with $PIPE_DIR/flash_expect.hex written by the driver
// side (cosim_flash_main.c): an independent check of what the driver
// reads back through the RTL.
// ============================================================
module tb;
`ifndef MFN_DIR
    `define MFN_DIR "mfn"
`endif
`ifndef PIPE_DIR
    `define PIPE_DIR "."
`endif
    localparam PIN_SYS_RST = 15, PIN_DATA_READY = 16, PIN_PROGRAM_B = 17, PIN_INIT_B = 18, PIN_DONE = 19;
    reg init_b = 1'b1, done = 1'b1;

    reg rst_gpio = 1'b1;                    // pull-up on the board: released
    reg stub_rst = 1'b1;
    reg qsclk = 0, qcs_n = 1;
    reg [3:0] qmo = 0; reg qdrive = 0;
    wire [3:0] qio = qdrive ? qmo : 4'bzzzz;
    wire data_ready_n;
    wire flash_cs_n, flash_mosi, flash_miso;
    pullup (flash_miso);
    wire [31:0] ddr3_dq; wire [3:0] ddr3_dqs_n, ddr3_dqs_p;

    v4_board_top dut (
        .sys_clk_p(1'b0), .sys_clk_n(1'b1), .sys_rst(stub_rst),
        .ddr3_dq(ddr3_dq), .ddr3_dqs_n(ddr3_dqs_n), .ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_addr(), .ddr3_ba(), .ddr3_ras_n(), .ddr3_cas_n(), .ddr3_we_n(), .ddr3_reset_n(),
        .ddr3_ck_p(), .ddr3_ck_n(), .ddr3_cke(), .ddr3_cs_n(), .ddr3_dm(), .ddr3_odt(),
        .qsclk(qsclk), .qcs_n(qcs_n), .qio(qio),
        .flash_cs_n(flash_cs_n), .flash_mosi(flash_mosi), .flash_miso(flash_miso),
        .data_ready_n(data_ready_n)
    );

    w25q32_model u_fl (.clk(dut.u_flash.usr_cclk), .cs_n(flash_cs_n), .di(flash_mosi), .do_(flash_miso));

    // PROGRAM_B: the FPGA would reconfigure from the flash
    integer j, sync_found;
    task automatic program_b_released;
        begin
            #5000 init_b = 1'b1;
            sync_found = 0;
            for (j = 0; j < 253; j = j + 1)
                if (u_fl.mem[j] == 8'hAA && u_fl.mem[j+1] == 8'h99 && u_fl.mem[j+2] == 8'h55 && u_fl.mem[j+3] == 8'h66) sync_found = 1;
            #50000;
            if (sync_found) done = 1'b1; else init_b = 1'b0;
            $display("  [bench] PROGRAM_B released: flash %s, DONE %0d", sync_found ? "holds a bitstream" : "has no sync word", done);
        end
    endtask

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
    reg [7:0] exp_mem [0:'h2FFFF];
    integer nbad;

    // watchdog: the driver's own timeouts end a normal run well before this
    initial begin #3_000_000_000.0; $display("BENCH FAIL: watchdog (3 s simulated)"); $finish; end

    initial begin
        // flash: pattern in the first 192 KB (same formula as cosim_flash_main.c), rest erased
        for (i = 0; i < 4 * 1024 * 1024; i = i + 1) u_fl.mem[i] = 8'hFF;
        for (i = 0; i < 'h30000; i = i + 1) u_fl.mem[i] = ((i * 7 + 3) ^ (i >> 8)) & 8'hFF;
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
                $fflush(fv);
                if (pin == PIN_PROGRAM_B && lvl == 0) begin init_b = 1'b0; done = 1'b0; end
                if (pin == PIN_PROGRAM_B && lvl == 1 && !done) program_b_released;
            end else if (tok == "L") begin
                rc = $fscanf(fc, "%d", pin);
                $fwrite(fv, "%0d\n", pin == PIN_DATA_READY ? data_ready_n : pin == PIN_INIT_B ? init_b : pin == PIN_DONE ? done : 0);
            end else if (tok == "D") begin
                rc = $fscanf(fc, "%d", v);
                #(v * 1000.0);
                $fwrite(fv, "0\n");
            end else if (tok == "T") begin
                $fwrite(fv, "%0d\n", $time / 1000);
            end else if (tok == "X") begin
                rc = $fscanf(fc, "%d", code);
                $display("  driver finished (code %0d) at %0t ns: %0d Quad-SPI transactions (%0d bytes)", code, $time, n_q, bytes_q);
                $display("  flash model: %0d WREN, %0d sector erase, %0d block erase, %0d page program, %0d rejected, %0d bytes programmed over 0 bits",
                         u_fl.n_wren, u_fl.n_se, u_fl.n_be, u_fl.n_pp, u_fl.n_rejected, u_fl.n_pp_not_erased);
                $readmemh({`PIPE_DIR, "/flash_expect.hex"}, exp_mem);
                nbad = 0;
                for (i = 0; i < 'h30000; i = i + 1) if (u_fl.mem[i] !== exp_mem[i]) begin
                    if (nbad < 5) $display("  flash 0x%06x = %02x, expected %02x", i, u_fl.mem[i], exp_mem[i]);
                    nbad = nbad + 1;
                end
                if (code == 0 && nbad == 0) $display("BENCH PASS: flash array identical to the expected image (0x30000 bytes)");
                else $display("BENCH FAIL: driver code %0d, %0d flash bytes differ", code, nbad);
                $finish;
            end else begin
                $display("FAIL: unknown request %s", tok); $finish;
            end
            $fflush(fv);
        end
    end
endmodule
