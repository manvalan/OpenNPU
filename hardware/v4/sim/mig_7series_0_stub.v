// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps
// ============================================================
// v4 -- behavioral stand-in for the MIG IP (mig_7series_0) for Icarus
// top-level simulation of v4_board_top.v. NOT the real controller:
// same app-port ports/semantics (in-order reads, 2 x 128-bit beats per
// command, write data after the command), 155.039 MHz ui_clk, random
// app_rdy/wdf_rdy, a fixed read latency and an optional sustained-rate
// limit. Memory = 128-bit words, burst b = words 2b, 2b+1, app_addr =
// 8*b (32-bit DDR word units, like mig_native_adapter.v assumes).
// The real MIG + Micron ddr3_model are used in the xsim bench instead.
// ============================================================
module mig_7series_0 (
    inout  wire [31:0] ddr3_dq, inout wire [3:0] ddr3_dqs_n, inout wire [3:0] ddr3_dqs_p,
    output wire [13:0] ddr3_addr, output wire [2:0] ddr3_ba,
    output wire ddr3_ras_n, output wire ddr3_cas_n, output wire ddr3_we_n, output wire ddr3_reset_n,
    output wire [0:0] ddr3_ck_p, output wire [0:0] ddr3_ck_n, output wire [0:0] ddr3_cke,
    output wire [0:0] ddr3_cs_n, output wire [3:0] ddr3_dm, output wire [0:0] ddr3_odt,
    input  wire sys_clk_i, input wire clk_ref_i,     // NO_BUFFER clocks (board MMCM), unused by the stub
    input  wire [27:0] app_addr, input wire [2:0] app_cmd, input wire app_en,
    input  wire [127:0] app_wdf_data, input wire app_wdf_end, input wire [15:0] app_wdf_mask, input wire app_wdf_wren,
    output reg  [127:0] app_rd_data, output reg app_rd_data_end, output reg app_rd_data_valid,
    output reg  app_rdy, output reg app_wdf_rdy,
    input  wire app_sr_req, input wire app_ref_req, input wire app_zq_req,
    output wire app_sr_active, output wire app_ref_ack, output wire app_zq_ack,
    output reg  ui_clk, output reg ui_clk_sync_rst, output reg init_calib_complete,
    output wire [11:0] device_temp,
    input  wire sys_rst
);
`ifndef STUB_LAT
    `define STUB_LAT 20
`endif
    initial ui_clk = 0;
    always #3.2250 ui_clk = ~ui_clk;          // 155.039 MHz

    reg [127:0] mem [0:1048575];      // 16 MB (networks with large parameter images)

    integer rst_cnt = 0;
    initial begin ui_clk_sync_rst = 1; init_calib_complete = 0; end
    always @(posedge ui_clk) begin
        if (sys_rst) begin rst_cnt = 0; ui_clk_sync_rst <= 1; init_calib_complete <= 0; end
        else begin
            rst_cnt = rst_cnt + 1;
            if (rst_cnt == 20) ui_clk_sync_rst <= 0;
            if (rst_cnt == 200) init_calib_complete <= 1;
        end
    end

    integer rq_b [0:1023]; integer rq_t [0:1023]; integer rq_w = 0, rq_r = 0;
    integer wq_b [0:1023]; integer wq_w = 0, wq_r = 0, wbeat = 0;
    integer cyc = 0, rbeat = 0, k;
    always @(posedge ui_clk) begin
        cyc = cyc + 1;
        app_rd_data_valid <= 1'b0; app_rd_data_end <= 1'b0;
        if (!ui_clk_sync_rst) begin
            if (app_en && app_rdy) begin
                if (app_cmd == 3'b001) begin rq_b[rq_w % 1024] = app_addr / 8; rq_t[rq_w % 1024] = cyc + `STUB_LAT; rq_w = rq_w + 1; end
                else begin wq_b[wq_w % 1024] = app_addr / 8; wq_w = wq_w + 1; end
            end
            if (app_wdf_wren && app_wdf_rdy) begin
                for (k = 0; k < 16; k = k + 1)
                    if (!app_wdf_mask[k]) mem[2*wq_b[wq_r % 1024] + wbeat][k*8 +: 8] = app_wdf_data[k*8 +: 8];
                if (wbeat == 1) begin wbeat = 0; wq_r = wq_r + 1; end else wbeat = 1;
            end
            if (rq_r < rq_w && cyc >= rq_t[rq_r % 1024] && (($random & 15) != 0)) begin
                app_rd_data_valid <= 1'b1;
                app_rd_data <= mem[2*rq_b[rq_r % 1024] + rbeat];
                app_rd_data_end <= (rbeat == 1);
                if (rbeat == 1) begin rbeat = 0; rq_r = rq_r + 1; end else rbeat = 1;
            end
        end
    end
    always @(negedge ui_clk) begin app_rdy <= (($random & 15) != 0); app_wdf_rdy <= (($random & 7) != 0); end
    assign app_sr_active = 1'b0; assign app_ref_ack = 1'b0; assign app_zq_ack = 1'b0;
    assign device_temp = 12'd0;
endmodule
