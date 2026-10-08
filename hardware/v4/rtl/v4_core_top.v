// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- implementation top for the G-esteso compute core (P&R only).
//
// v4_core has a 128-bit host port; a real package cannot pin that out,
// so this wrapper narrows it to an 8-bit bus: the host shifts 16 bytes
// into a staging register, then strobes a command. Read data comes back
// one byte at a time. Everything inside v4_core (engine, all memories,
// sequencer) is placed and routed exactly as it will be in the system;
// what is NOT here yet: MIG DDR3, SPI bridge, clocking (MMCM).
//
// Memory sizes are the on-chip plan: pw weight double buffer 2 x 256
// words x 2048 bit (32 RAMB36), dw/pw parameter double buffers 2 x 32
// rows (distributed RAM), feature map 3 x 128 KB.
// ============================================================
module v4_core_top (
    input  wire       clk,
    input  wire       rst,
    input  wire       start,
    output wire       done,
    output wire       error,

    input  wire [7:0] hb_data,     // byte into the staging register
    input  wire       hb_shift,    // shift hb_data in (16 shifts = 1 word)
    input  wire       hb_cmd_we,   // write staging word to (sel, addr, chunk)
    input  wire       hb_cmd_re,   // read feature-map word at addr
    input  wire [2:0] hb_sel,
    input  wire [15:0] hb_addr,
    input  wire [3:0] hb_chunk,
    input  wire [3:0] hb_rbyte,    // which byte of the last read word to show
    output reg  [7:0] hb_rdata,
    output reg        hb_rvalid,
    output wire [7:0] cycles_lo,

    // DDR3 read port stand-in for P&R only (the MIG replaces it): a
    // 128-bit word is shifted in 8 bits at a time; requests come out on
    // a few pins
    input  wire [7:0] dd_data,
    input  wire       dd_shift,
    input  wire       dd_rvalid,
    input  wire       dd_req_ready,
    output reg        dd_req_valid,
    output reg  [7:0] dd_req_info
);
    reg [127:0] stage;
    always @(posedge clk) if (hb_shift) stage <= {stage[119:0], hb_data};

    // register every host input once (they come from pins). Host protocol:
    // hb_sel/addr/chunk and the staging word are held stable for >= 3
    // cycles around a command, and hb_cmd_we/re are held >= 2 cycles
    // (a repeated write of the same word is harmless); the write/read strobe reaches the core one
    // cycle AFTER the registered address/data (we_rr/re_rr), so address/
    // data paths into the core's memories are 2-cycle paths
    // (set_multicycle_path in the XDC).
    reg        we_rr, re_rr;
    reg        we_r, re_r;
    reg [2:0]  sel_r;
    reg [15:0] addr_r;
    reg [3:0]  chunk_r;
    reg        start_r;
    always @(posedge clk) begin
        we_r <= hb_cmd_we; re_r <= hb_cmd_re; sel_r <= hb_sel;
        we_rr <= we_r;     re_rr <= re_r;
        addr_r <= hb_addr; chunk_r <= hb_chunk; start_r <= start;
    end

    wire         rvalid;
    wire [127:0] rdata;
    wire [31:0]  cycles;
    reg  [127:0] dd_word;
    reg          dd_rv, dd_rr;
    always @(posedge clk) begin
        if (dd_shift) dd_word <= {dd_word[119:0], dd_data};
        dd_rv <= dd_rvalid; dd_rr <= dd_req_ready;
    end
    wire        c_req_valid;
    wire [24:0] c_req_addr;
    wire [15:0] c_req_len;
    always @(posedge clk) begin
        dd_req_valid <= c_req_valid;
        dd_req_info  <= c_req_addr[7:0] ^ c_req_addr[15:8] ^ c_req_addr[23:16] ^ c_req_len[7:0] ^ c_req_len[15:8];
    end

    v4_core #(.NDESC(256), .WDEPTH(512), .DWDEPTH(64), .PWDEPTH(64),
              .N_DSP_COLS(14), .MAXW(64), .MAXNG(32), .MAXNCO(32)) u_core (
        .clk(clk), .rst(rst), .start(start_r), .done(done), .cycles(cycles), .error(error),
        .host_we_i(we_rr), .host_re_i(re_rr), .host_sel_i(sel_r), .host_addr_i(addr_r),
        .host_chunk_i(chunk_r), .host_wdata_i(stage),
        .host_rvalid(rvalid), .host_rdata(rdata),
        .desc_base(25'd0),   // core-only P&R wrapper: no real DDR behind it
        .ddr_req_valid(c_req_valid), .ddr_req_ready(dd_rr),
        .ddr_req_addr(c_req_addr), .ddr_req_len(c_req_len),
        .ddr_rvalid(dd_rv), .ddr_rdata(dd_word)
    );

    reg [127:0] rword;
    always @(posedge clk) begin
        if (rvalid) rword <= rdata;
        hb_rvalid <= rvalid;
        hb_rdata  <= rword[hb_rbyte*8 +: 8];
    end
    assign cycles_lo = cycles[7:0];
endmodule
