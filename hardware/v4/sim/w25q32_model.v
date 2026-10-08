// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps
// ============================================================
// Minimal behavioral model of the Winbond W25Q32JV (4 MB SPI NOR),
// written from the datasheet (rev G, 2018-03-27), single-line SPI mode 0
// only: what the v4 config-flash path uses through flash_spi_master.v.
//
//   9Fh JEDEC ID (EF 40 16)     05h Read Status-1 (BUSY bit0, WEL bit1)
//   06h Write Enable            04h Write Disable
//   03h Read Data               02h Page Program (wraps inside the page)
//   20h Sector Erase 4 KB       D8h Block Erase 64 KB
//
// DI sampled on the rising CLK edge, DO driven on the falling edge, hi-Z
// with /CS high. While BUSY only 05h is answered. Strict on /CS framing,
// as the datasheet requires for write-type commands ("/CS must be driven
// high after the eighth bit of the last byte"): /CS rising off a byte
// boundary cancels the command; Write Enable needs exactly 1 byte and the
// erases exactly 4 (the datasheet does not say that extra bytes are
// ignored, so the model refuses them); Page Program needs >= 1 data byte.
// Busy times are shortened (TPP/TSE/TBE, ns) to keep simulations short.
//
// Counters for the testbench: n_wren, n_se, n_be, n_pp, n_rejected,
// n_pp_not_erased (bytes programmed over bits that were already 0).
// ============================================================
module w25q32_model #(
    parameter TPP = 50_000, parameter TSE = 300_000, parameter TBE = 500_000
) (
    input  wire clk,
    input  wire cs_n,
    input  wire di,
    output wire do_
);
    localparam SIZE = 4 * 1024 * 1024;
    reg [7:0] mem [0:SIZE-1];

    reg busy = 0, wel = 0;
    reg [7:0] in_sr, cmd, out_sr;
    reg [2:0] bitc;
    integer nbytes;
    reg [23:0] addr;
    reg do_en = 0, do_r = 1'b1;
    reg [7:0] pbuf [0:255];
    integer pcount;
    integer n_wren = 0, n_se = 0, n_be = 0, n_pp = 0, n_rejected = 0, n_pp_not_erased = 0;
    integer i;
    // busy timer outside the /CS block, so that /CS edges during BUSY are seen
    event ev_busy;
    integer bdur;
    always @(ev_busy) begin #(bdur) busy = 0; end

    assign do_ = do_en ? do_r : 1'bz;

    wire [7:0] sr1 = {6'b0, wel, busy};

    always @(negedge cs_n) begin
        bitc = 0; nbytes = 0; cmd = 8'h00; pcount = 0; out_sr = 8'hFF;
    end

    // next byte to shift out, decided when a byte has been received
    task next_out;
        begin
            if (busy) out_sr = (cmd == 8'h05) ? sr1 : 8'hFF;
            else case (cmd)
                8'h9F: out_sr = (nbytes == 1) ? 8'hEF : (nbytes == 2) ? 8'h40 : (nbytes == 3) ? 8'h16 : 8'hFF;
                8'h05: out_sr = sr1;
                8'h03: if (nbytes >= 4) begin out_sr = mem[addr]; addr = (addr + 1) % SIZE; end
                       else out_sr = 8'hFF;
                default: out_sr = 8'hFF;
            endcase
        end
    endtask

    always @(posedge clk) if (!cs_n) begin
        in_sr = {in_sr[6:0], di};
        bitc = bitc + 1;
        if (bitc == 0) begin                 // a whole byte
            if (nbytes == 0) cmd = in_sr;
            else if (nbytes <= 3) addr = {addr[15:0], in_sr};
            else if (cmd == 8'h02 && !busy) begin
                pbuf[pcount % 256] = in_sr;   // more than 256 bytes overwrite (wrap)
                pcount = pcount + 1;
            end
            nbytes = nbytes + 1;
            next_out;
        end
    end

    always @(negedge clk) if (!cs_n) begin
        do_en <= 1'b1;
        do_r  <= out_sr[7];
        out_sr = {out_sr[6:0], 1'b1};
    end

    always @(posedge cs_n) begin
        do_en <= 1'b0;
        if (bitc != 0 && nbytes > 0) begin
            if (cmd == 8'h06 || cmd == 8'h20 || cmd == 8'hD8 || cmd == 8'h02) n_rejected = n_rejected + 1;
        end else if (!busy) begin
            case (cmd)
                8'h06: if (nbytes == 1) begin wel = 1; n_wren = n_wren + 1; end
                       else n_rejected = n_rejected + 1;
                8'h04: wel = 0;
                8'h20, 8'hD8: if (nbytes == 4 && wel) begin
                           if (cmd == 8'h20) begin
                               for (i = 0; i < 4096; i = i + 1) mem[{addr[23:12], 12'h000} + i] = 8'hFF;
                               n_se = n_se + 1;
                           end else begin
                               for (i = 0; i < 65536; i = i + 1) mem[{addr[23:16], 16'h0000} + i] = 8'hFF;
                               n_be = n_be + 1;
                           end
                           wel = 0; busy = 1; bdur = (cmd == 8'h20) ? TSE : TBE; -> ev_busy;
                       end else n_rejected = n_rejected + 1;
                8'h02: if (nbytes >= 5 && wel) begin
                           for (i = 0; i < (pcount > 256 ? 256 : pcount); i = i + 1) begin
                               if (((mem[{addr[23:8], 8'h00} + ((addr[7:0] + i) % 256)]) & pbuf[i]) != pbuf[i])
                                   n_pp_not_erased = n_pp_not_erased + 1;
                               mem[{addr[23:8], 8'h00} + ((addr[7:0] + i) % 256)] =
                                   mem[{addr[23:8], 8'h00} + ((addr[7:0] + i) % 256)] & pbuf[i];
                           end
                           n_pp = n_pp + 1;
                           wel = 0; busy = 1; bdur = TPP; -> ev_busy;
                       end else n_rejected = n_rejected + 1;
                default: ;
            endcase
        end
    end
endmodule
