// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- pipelined DDR3 streamer on the MIG native app interface (ui_clk
// domain), plus the app-port ownership mux with the v3 host adapter.
//
// Why not mig_native_adapter.v: it is fully sequential (one 256-bit
// burst per request, command -> data -> done), fine for the host's
// 16-bit WRITE_MEM/READ_MEM, far too slow for ~1 MB of parameters per
// inference. Here read commands are issued back to back while MIG
// returns data in order, limited only by the space left in the output
// FIFO (credit).
//
// Addressing: core side uses 128-bit words (W). MIG app_addr is in
// 32-bit DDR words and one command moves one burst of 8 of them = 256
// bits = two 128-bit words (same convention as mig_native_adapter.v):
// word W lives in burst W>>1 at app_addr 8*(W>>1), beat W[0].
//
// Read job (rc_*): W, len -> exactly len words pushed to the read-data
// FIFO in order (a leading/trailing half burst is dropped).
// Write job (wc_*): one 128-bit word to W (other beat masked).
//
// Ownership of the MIG app port: the host adapter (SPI WRITE_MEM /
// READ_MEM path, v3) gets it only while the streamer is idle, and keeps
// it until its own transaction is over (adapter `busy`); the streamer
// takes it back only between adapter transactions.
// ============================================================
module v4_ddr_stream #(
    parameter RD_FIFO_DEPTH = 64       // words of space in the read FIFO (credit)
)(
    input  wire clk,          // ui_clk
    input  wire rst,          // ui_clk_sync_rst

    // read jobs (from the core domain, FWFT async FIFO read side)
    input  wire         rc_valid,
    output wire         rc_pop,
    input  wire [24:0]  rc_addr,
    input  wire [15:0]  rc_len,
    // write jobs
    input  wire         wc_valid,
    output wire         wc_pop,
    input  wire [24:0]  wc_addr,
    input  wire [127:0] wc_data,
    // read data out (async FIFO write side)
    output reg          rd_push,
    output reg  [127:0] rd_word,
    input  wire [6:0]   rd_fifo_count,

    // host adapter's app master port (mig_native_adapter.v)
    input  wire [27:0]  h_app_addr,
    input  wire [2:0]   h_app_cmd,
    input  wire         h_app_en,
    output wire         h_app_rdy,
    input  wire [127:0] h_app_wdf_data,
    input  wire         h_app_wdf_end,
    input  wire [15:0]  h_app_wdf_mask,
    input  wire         h_app_wdf_wren,
    output wire         h_app_wdf_rdy,
    output wire         h_app_rd_data_valid,
    input  wire         h_busy,

    // MIG app port
    output wire [27:0]  app_addr,
    output wire [2:0]   app_cmd,
    output wire         app_en,
    input  wire         app_rdy,
    output wire [127:0] app_wdf_data,
    output wire         app_wdf_end,
    output wire [15:0]  app_wdf_mask,
    output wire         app_wdf_wren,
    input  wire         app_wdf_rdy,
    input  wire [127:0] app_rd_data,
    input  wire         app_rd_data_end,
    input  wire         app_rd_data_valid,

    output wire         idle
);
    localparam CMD_WRITE = 3'b000, CMD_READ = 3'b001;

    // ---------------- ownership ----------------
    reg host_owns;
    wire s_idle;
    always @(posedge clk) begin
        if (rst) host_owns <= 1'b0;
        else if (!host_owns && s_idle && h_app_en)        host_owns <= 1'b1;
        else if ( host_owns && !h_busy && !h_app_en)      host_owns <= 1'b0;
    end

    // ---------------- read job ----------------
    reg         rd_act;
    reg [24:0]  b_next, b_last;     // next burst to issue, last burst
    reg [15:0]  words_left;         // words still to push
    reg         skip_first;         // drop the first beat returned
    reg [7:0]   outstanding;        // bursts issued, data not all back
    reg         beat_hi;            // next returned beat is the second of its burst

    // ---------------- write job ----------------
    reg         wr_act;             // command issued, data beats pending
    reg [1:0]   wr_beat;
    reg [127:0] wr_data_q;
    reg         wr_odd;

    // command issue
    reg         s_en;
    reg [27:0]  s_addr;
    reg [2:0]   s_cmd;
    // +4: one burst being issued plus up to two words still in the push register
    wire credit_ok = ({2'b0, rd_fifo_count} + {1'b0, outstanding, 1'b0} + 10'd4) <= RD_FIFO_DEPTH;
    wire rd_acc  = s_en && app_rdy && !host_owns && (s_cmd == CMD_READ);
    wire rd_done = app_rd_data_valid && !host_owns && beat_hi;

    assign rc_pop = !host_owns && !rd_act && !wr_act && !s_en && rc_valid && (outstanding == 0);
    assign wc_pop = !host_owns && !rd_act && !wr_act && !s_en && !rc_valid && wc_valid && (outstanding == 0);
    assign s_idle = !rd_act && !wr_act && !s_en && (outstanding == 0) && !rc_valid && !wc_valid;
    assign idle = s_idle && !host_owns;

    always @(posedge clk) begin
        rd_push <= 1'b0;
        if (rst) begin
            rd_act <= 1'b0; wr_act <= 1'b0; s_en <= 1'b0; outstanding <= 8'd0; beat_hi <= 1'b0;
        end else begin
            // accept a new job
            if (rc_pop) begin
                rd_act     <= 1'b1;
                b_next     <= rc_addr >> 1;
                b_last     <= (rc_addr + rc_len - 25'd1) >> 1;
                words_left <= rc_len;
                skip_first <= rc_addr[0];
                beat_hi    <= 1'b0;
            end else if (wc_pop) begin
                wr_act    <= 1'b1;
                wr_beat   <= 2'd0;
                wr_data_q <= wc_data;
                wr_odd    <= wc_addr[0];
                s_en      <= 1'b1;
                s_cmd     <= CMD_WRITE;
                s_addr    <= {wc_addr[24:1], 3'b000} ;   // 8 * (W >> 1)
            end

            // issue read commands back to back (credit permitting)
            if (rd_act && !s_en && credit_ok && (b_next <= b_last)) begin
                s_en   <= 1'b1;
                s_cmd  <= CMD_READ;
                s_addr <= {b_next, 3'b000};
                b_next <= b_next + 25'd1;
            end
            if (s_en && app_rdy && !host_owns) s_en <= 1'b0;
            outstanding <= outstanding + (rd_acc ? 8'd1 : 8'd0) - (rd_done ? 8'd1 : 8'd0);

            // returned read data (in order, 2 beats per burst)
            if (app_rd_data_valid && !host_owns) begin
                beat_hi <= ~beat_hi;
                if (skip_first) skip_first <= 1'b0;
                else if (words_left != 16'd0) begin
                    rd_push <= 1'b1;
                    rd_word <= app_rd_data;
                    words_left <= words_left - 16'd1;
                end
            end
            if (rd_act && (b_next > b_last) && (outstanding == 0) && !s_en && !app_rd_data_valid)
                rd_act <= 1'b0;

            // write data beats (after the command was accepted)
            if (wr_act && !s_en && app_wdf_rdy) begin
                wr_beat <= wr_beat + 2'd1;
                if (wr_beat == 2'd1) wr_act <= 1'b0;
            end
        end
    end

    // write data channel
    wire        s_wdf_wren = wr_act && !s_en;
    wire [127:0] s_wdf_data = wr_data_q;
    wire [15:0] s_wdf_mask = (wr_beat[0] == wr_odd) ? 16'h0000 : 16'hFFFF;   // 1 = byte masked
    wire        s_wdf_end  = (wr_beat == 2'd1);

    // ---------------- app port mux ----------------
    assign app_addr     = host_owns ? h_app_addr     : s_addr;
    assign app_cmd      = host_owns ? h_app_cmd      : s_cmd;
    assign app_en       = host_owns ? h_app_en       : s_en;
    assign app_wdf_data = host_owns ? h_app_wdf_data : s_wdf_data;
    assign app_wdf_end  = host_owns ? h_app_wdf_end  : s_wdf_end;
    assign app_wdf_mask = host_owns ? h_app_wdf_mask : s_wdf_mask;
    assign app_wdf_wren = host_owns ? h_app_wdf_wren : s_wdf_wren;
    assign h_app_rdy           = host_owns && app_rdy;
    assign h_app_wdf_rdy       = host_owns && app_wdf_rdy;
    assign h_app_rd_data_valid = host_owns && app_rd_data_valid;
endmodule
