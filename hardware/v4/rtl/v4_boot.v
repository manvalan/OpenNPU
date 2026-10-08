// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- boot / run controller (core clock domain) for the board top.
//
// The ESP32 only talks to DDR3 (v3 SPI WRITE_MEM/READ_MEM) and to the
// v3 bridge's registers. One inference:
//   host: WRITE_MEM the image (and, once, weights + descriptors + header)
//   host: NETWORK_BASE = header address, CONTROL bit1 = start
//   FPGA (this block): read the header, copy the image into the core
//         (its host port), run the core (it reads the descriptor table
//         from DDR3 itself, pass by pass, at desc_base), copy
//         the output tensor and a statistics word back to DDR3, done
//   host: polls STATUS (seq_done), READ_MEMs the result
//
// Header (two 128-bit words at hdr_w, 128-bit-word addresses):
//   w0 [15:0]  n_pass        [47:16] desc_w     [79:48] img_w
//      [95:80] img_words     [111:96] img_fmap (feature-map word address)
//   w1 [31:0]  result_w      [47:32] out_fmap   [63:48] out_words
//      [95:64] param_w (DDR base of the parameter image, added to every
//              address the core's parameter loader asks for)
//      [127:96] magic = 0x344E4E56 ("VNN4")
// Descriptor table: 3 words per pass (desc chunks 0, 1, 2).
// Result: out_words words at result_w, then one statistics word:
//   [31:0] total cycles  [63:32] cycles waiting for parameters
//   [64] core error flag [95:65] 0  [127:96] magic
// ============================================================
module v4_boot (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,          // pulse
    input  wire [24:0]  hdr_w,
    output reg          busy,
    output reg          done,           // pulse
    output reg          error,          // sticky until next start

    // DDR read port (core-domain side of the CDC)
    output reg          rq_valid,
    input  wire         rq_ready,
    output reg  [24:0]  rq_addr,
    output reg  [15:0]  rq_len,
    input  wire         rd_valid,       // one word per cycle when valid, always consumed
    input  wire [127:0] rd_data,
    // DDR write port
    output reg          wq_valid,
    input  wire         wq_ready,
    output reg  [24:0]  wq_addr,
    output reg  [127:0] wq_data,

    // core control
    output reg          core_start,
    input  wire         core_done,
    input  wire [31:0]  core_cycles,
    input  wire [31:0]  core_stall,
    input  wire         core_error,
    output wire         run_phase,      // core owns the DDR read port
    output reg  [24:0]  param_w,
    output reg  [24:0]  desc_base,      // desc_w - param_w: the core's DDR addresses are param_w-relative

    // core host port
    output reg          host_we,
    output reg          host_re,
    output reg  [2:0]   host_sel,
    output reg  [15:0]  host_addr,
    output reg  [3:0]   host_chunk,
    output reg  [127:0] host_wdata,
    input  wire         host_rvalid,
    input  wire [127:0] host_rdata
);
    localparam MAGIC = 32'h344E4E56;
    localparam S_IDLE = 4'd0, S_HDR = 4'd1, S_DESC = 4'd2, S_IMG = 4'd3, S_RUN = 4'd4,
               S_OUT_RD = 4'd5, S_OUT_WAIT = 4'd6, S_OUT_WR = 4'd7, S_STAT = 4'd8,
               S_FIN = 4'd9, S_REQ = 4'd10, S_DATA = 4'd11;
    reg [3:0]  st, ret;           // ret: state after a read job completes
    reg [15:0] cnt, n;            // words received / expected
    reg [1:0]  phase;             // 0 header, 2 image

    reg [127:0] h0, h1;
    wire [15:0] n_pass    = h0[15:0];
    wire [31:0] desc_w    = h0[47:16];
    wire [31:0] img_w     = h0[79:48];
    wire [15:0] img_words = h0[95:80];
    wire [15:0] img_fmap  = h0[111:96];
    wire [31:0] result_w  = h1[31:0];
    wire [15:0] out_fmap  = h1[47:32];
    wire [15:0] out_words = h1[63:48];

    reg [15:0] oi;
    reg        core_seen_done;
    assign run_phase = (st == S_RUN);

    always @(posedge clk) begin
        host_we <= 1'b0; host_re <= 1'b0; core_start <= 1'b0; done <= 1'b0;
        if (rst) begin
            st <= S_IDLE; busy <= 1'b0; error <= 1'b0; rq_valid <= 1'b0; wq_valid <= 1'b0;
        end else case (st)
            S_IDLE: if (start) begin
                busy <= 1'b1; error <= 1'b0;
                phase <= 2'd0; rq_addr <= hdr_w; rq_len <= 16'd2; cnt <= 16'd0; n <= 16'd2;
                st <= S_REQ;
            end
            // generic read job: issue, then collect `n` words (handled per phase)
            S_REQ: begin
                rq_valid <= 1'b1;
                if (rq_valid && rq_ready) begin rq_valid <= 1'b0; st <= S_DATA; end
            end
            S_DATA: if (rd_valid) begin
                cnt <= cnt + 16'd1;
                case (phase)
                    2'd0: begin
                        if (cnt == 16'd0) h0 <= rd_data; else h1 <= rd_data;
                        if (cnt == 16'd1) st <= S_HDR;
                    end
                    default: begin  // image word -> feature map
                        host_we <= 1'b1; host_sel <= 3'd5; host_addr <= img_fmap + cnt;
                        host_chunk <= 4'd0; host_wdata <= rd_data;
                        if (cnt == n - 16'd1) st <= S_IMG;
                    end
                endcase
            end
            S_HDR: begin    // header in: check it, then fetch the image
                param_w   <= h1[88:64];
                desc_base <= desc_w[24:0] - h1[88:64];
                if (h1[127:96] != MAGIC || n_pass == 16'd0 || n_pass > 16'd256) begin
                    error <= 1'b1; st <= S_FIN;
                end else st <= S_DESC;
            end
            S_DESC: begin   // fetch the image
                phase <= 2'd2;
                rq_addr <= img_w[24:0]; rq_len <= img_words; n <= img_words; cnt <= 16'd0;
                st <= (img_words == 16'd0) ? S_IMG : S_REQ;
            end
            S_IMG: begin    // everything on chip: run
                core_start <= 1'b1;
                core_seen_done <= 1'b0;
                st <= S_RUN;
            end
            S_RUN: if (core_done && !core_start) begin
                if (core_error) error <= 1'b1;
                oi <= 16'd0;
                st <= (out_words == 16'd0) ? S_STAT : S_OUT_RD;
            end
            // copy the output tensor: feature-map read -> DDR write
            S_OUT_RD: begin
                host_re <= 1'b1; host_sel <= 3'd6; host_addr <= out_fmap + oi;
                st <= S_OUT_WAIT;
            end
            S_OUT_WAIT: if (host_rvalid) begin
                wq_valid <= 1'b1; wq_addr <= result_w[24:0] + oi; wq_data <= host_rdata;
                st <= S_OUT_WR;
            end
            S_OUT_WR: if (wq_valid && wq_ready) begin
                wq_valid <= 1'b0;
                oi <= oi + 16'd1;
                st <= (oi == out_words - 16'd1) ? S_STAT : S_OUT_RD;
            end
            S_STAT: begin
                if (!wq_valid) begin
                    wq_valid <= 1'b1;
                    wq_addr  <= result_w[24:0] + out_words;
                    wq_data  <= {MAGIC, 31'd0, core_error, core_stall, core_cycles};
                end else if (wq_ready) begin
                    wq_valid <= 1'b0;
                    st <= S_FIN;
                end
            end
            S_FIN: begin
                busy <= 1'b0; done <= 1'b1;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
    end
endmodule
