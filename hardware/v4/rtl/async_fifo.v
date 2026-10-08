// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- dual-clock FIFO (Cummings style): binary pointers with one
// extra wrap bit, Gray-coded copies crossed through 2-flop
// synchronizers, full/empty computed in their own domains.
// Distributed-RAM storage, registered-output-free read (first word
// fall-through: rd_data shows the head while !empty).
// Also reports, in the write domain, how many entries are in use
// (wr_count, conservative: based on the synchronized read pointer,
// registered once more).
// ============================================================
module async_fifo #(
    parameter DW = 128,
    parameter AW = 4           // depth = 2**AW
)(
    input  wire          wclk,
    input  wire          wrst,
    input  wire          wr_en,
    input  wire [DW-1:0] wr_data,
    output wire          full,
    output wire [AW:0]   wr_count,

    input  wire          rclk,
    input  wire          rrst,
    input  wire          rd_en,
    output wire [DW-1:0] rd_data,
    output wire          empty
);
    (* ram_style = "distributed" *) reg [DW-1:0] mem [0:(1<<AW)-1];

    function [AW:0] b2g(input [AW:0] b); b2g = b ^ (b >> 1); endfunction
    function [AW:0] g2b(input [AW:0] g);
        integer i;
        begin
            g2b[AW] = g[AW];
            for (i = AW-1; i >= 0; i = i - 1) g2b[i] = g2b[i+1] ^ g[i];
        end
    endfunction

    reg [AW:0] rbin, rgray;   // read-domain pointers (declared early)

    // ---------------- write domain ----------------
    reg [AW:0] wbin, wgray;
    (* ASYNC_REG = "TRUE" *) reg [AW:0] rg_s1, rg_s2;
    wire [AW:0] wbin_n = wbin + 1'b1;
    always @(posedge wclk) begin
        if (wrst) begin
            wbin <= 0; wgray <= 0; rg_s1 <= 0; rg_s2 <= 0;
        end else begin
            rg_s1 <= rgray; rg_s2 <= rg_s1;
            if (wr_en && !full) begin
                mem[wbin[AW-1:0]] <= wr_data;
                wbin  <= wbin_n;
                wgray <= b2g(wbin_n);
            end
        end
    end
    // the read pointer for wr_count is converted to binary and registered
    // once more (rg_s2 -> Gray decode -> subtract -> users was -0.22 ns
    // on ui_clk in the first generic-board P&R); an older read pointer
    // only makes the count larger, so it stays conservative
    reg  [AW:0] rbin_w;
    always @(posedge wclk) rbin_w <= wrst ? {(AW+1){1'b0}} : g2b(rg_s2);
    assign full     = (wgray == {~rg_s2[AW:AW-1], rg_s2[AW-2:0]});
    assign wr_count = wbin - rbin_w;

    // ---------------- read domain ----------------
    (* ASYNC_REG = "TRUE" *) reg [AW:0] wg_s1, wg_s2;
    wire [AW:0] rbin_n = rbin + 1'b1;
    always @(posedge rclk) begin
        if (rrst) begin
            rbin <= 0; rgray <= 0; wg_s1 <= 0; wg_s2 <= 0;
        end else begin
            wg_s1 <= wgray; wg_s2 <= wg_s1;
            if (rd_en && !empty) begin
                rbin  <= rbin_n;
                rgray <= b2g(rbin_n);
            end
        end
    end
    assign empty   = (rgray == wg_s2);
    assign rd_data = mem[rbin[AW-1:0]];
    // power-on values (flip-flop INIT on the FPGA): lets a side whose clock
    // only runs during transfers (e.g. a QSPI SCLK) work without a reset
    // memory INIT 0 (as on the FPGA): a read of a never-written entry
    // gives 0, not X, in simulation too
    integer mi;
    initial begin
        for (mi = 0; mi < (1<<AW); mi = mi + 1) mem[mi] = {DW{1'b0}};
        wbin = 0; wgray = 0; rbin = 0; rgray = 0;
        rg_s1 = 0; rg_s2 = 0; wg_s1 = 0; wg_s2 = 0; rbin_w = 0;
    end

endmodule
