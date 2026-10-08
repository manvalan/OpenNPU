// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- REAL board top for the G-esteso MobileFaceNet accelerator.
//
// Host link: ONE Quad-SPI port (qspi_data_port.v, 2026-10-07; the v3
// management SPI bridge and its 16-bit DDR3 path are gone). The ESP32
// writes the blob and the input, sets NETWORK_BASE and starts a run with
// REG_WRITE commands, polls STATUS (or waits for data_ready_n), reads
// the result, and reaches the configuration flash with FLASH_XFER /
// FLASH_READ. Behind it: the v3 mig_native_adapter.v raw DDR3 path, the
// MIG IP (mig_7series_0) and the flash master (flash_spi_master.v).
//
//   ui_clk (155.0 MHz, MIG)                   core clk (~199.29 MHz)
//   Quad-SPI port, adapter                     v4_core + v4_boot
//   v4_ddr_stream (pipelined MIG reader)  <==> async FIFOs (rd cmd,
//                                               rd data, wr cmd)
//
// Registers (qspi_data_port.v header): NETWORK_BASE = DDR3 32-bit-word
// address of the v4 boot header (multiple of 4); CONTROL bit1 = start;
// STATUS = calibrated / error / busy / done. Header format and results:
// v4_boot.v.
//
// Board clock (2026-10-06, branch v4-sysclk-200): ONE 200 MHz LVDS
// oscillator on N5/P5 (bank 34, LVDS_25 input, DIFF_TERM FALSE + 100 ohm
// on the board). IBUFDS -> BUFG = IDELAYCTRL reference (MIG clk_ref_i,
// NO_BUFFER, exactly 200 MHz); BUFG -> MMCM x31/5/4 = 310.0 MHz -> BUFG
// = MIG sys_clk_i (NO_BUFFER, tCK 3226 ps, ui_clk 155.0 MHz). The MIG
// cannot take 200 MHz directly at this memory clock (its PLL allows
// DIVCLK = 1 only: 200 MHz -> 300 or 350 MHz memory, and 300 MHz is below
// the DDR3 minimum). The MIG is held in reset until this MMCM locks.
//
// Core clock: MMCME2_BASE on ui_clk, M = 9, D = 1 (VCO 1395.35 MHz),
// O = 7.375 -> 189.20 MHz (5.285 ns). The core alone closed at 5.000 ns;
// inside the whole board (MIG, 98% BRAM) the fourth P&R reached -0.235 ns
// at 199.34 MHz (O = 7) and +0.033 ns at 189.20 MHz on the same routing.
// Tag v4-board-189 = the closed 189.20 MHz build; this revision targets
// O = 7 (199.34 MHz) again with the fifth-P&R fixes.
// ============================================================
module v4_board_top #(
    parameter MEM_ADDR_WIDTH = 25
)(
    input  wire sys_clk_p,      // 200 MHz LVDS oscillator
    input  wire sys_clk_n,
    input  wire sys_rst,

    inout  wire [31:0] ddr3_dq,
    inout  wire [3:0]  ddr3_dqs_n,
    inout  wire [3:0]  ddr3_dqs_p,
    output wire [13:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_reset_n,
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_cke,
    output wire [0:0]  ddr3_cs_n,
    output wire [3:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt,

    // Quad-SPI host port (qspi_data_port.v): the ESP32's only link --
    // DDR3 transfers, registers, status, configuration flash
    input  wire       qsclk,          // clock-capable pin (D15)
    input  wire       qcs_n,
    inout  wire [3:0] qio,

    output wire flash_cs_n,
    output wire flash_mosi,
    input  wire flash_miso,

    output wire data_ready_n
);
    // v3's chained top also had ui_clk_o / init_calib_complete ports, but
    // they have no package pin on the board (docs/PHYSICAL_REALIZATION.md
    // pin table): an unconstrained output would be placed on an arbitrary
    // pin of the real PCB. Both stay internal here; calibration status is
    // readable over Quad-SPI (STATUS bit 64).
    wire ui_clk_o, init_calib_complete;
    // =========================================================
    // MIG + host raw-access path (v3, unchanged)
    // =========================================================
    wire [27:0]  app_addr;  wire [2:0] app_cmd;  wire app_en, app_rdy;
    wire [127:0] app_wdf_data; wire app_wdf_end; wire [15:0] app_wdf_mask; wire app_wdf_wren, app_wdf_rdy;
    wire [127:0] app_rd_data; wire app_rd_data_end, app_rd_data_valid;
    wire ui_clk, ui_rst;
    assign ui_clk_o = ui_clk;

    // board clock: 200 MHz oscillator -> IDELAYCTRL reference + MIG system clock
    wire clk_ref_200, mig_sys_clk, osc_locked;
`ifdef V4_SIM_CLK
    // simulation without unisims: the stub MIG makes its own ui_clk
    assign clk_ref_200 = sys_clk_p;
    assign mig_sys_clk = sys_clk_p;
    assign osc_locked  = 1'b1;
`else
    wire osc_200, mig_sys_clk_unbuf, osc_fb;
    IBUFDS #(.DIFF_TERM("FALSE"), .IBUF_LOW_PWR("FALSE")) u_ibuf_osc (.I(sys_clk_p), .IB(sys_clk_n), .O(osc_200));
    BUFG u_bufg_ref (.I(osc_200), .O(clk_ref_200));
    MMCME2_BASE #(
        .CLKIN1_PERIOD(5.000), .CLKFBOUT_MULT_F(31.000), .DIVCLK_DIVIDE(5),   // VCO 1240 MHz, PFD 40 MHz
        .CLKOUT0_DIVIDE_F(4.000)                                              // 310.0 MHz
    ) u_mmcm_mig (
        .CLKIN1(clk_ref_200), .CLKFBIN(osc_fb), .CLKFBOUT(osc_fb),   // from the BUFG: the bank-34 CMT's MMCM belongs to the MIG
        .CLKOUT0(mig_sys_clk_unbuf), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKFBOUTB(),
        .LOCKED(osc_locked), .PWRDWN(1'b0), .RST(!sys_rst)
    );
    BUFG u_bufg_mig (.I(mig_sys_clk_unbuf), .O(mig_sys_clk));
`endif

    mig_7series_0 u_mig (
        .ddr3_dq(ddr3_dq), .ddr3_dqs_n(ddr3_dqs_n), .ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba),
        .ddr3_ras_n(ddr3_ras_n), .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_reset_n(ddr3_reset_n),
        .ddr3_ck_p(ddr3_ck_p), .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cke(ddr3_cke), .ddr3_cs_n(ddr3_cs_n),
        .ddr3_dm(ddr3_dm), .ddr3_odt(ddr3_odt),
        .sys_clk_i(mig_sys_clk), .clk_ref_i(clk_ref_200),
        .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en),
        .app_wdf_data(app_wdf_data), .app_wdf_end(app_wdf_end),
        .app_wdf_mask(app_wdf_mask), .app_wdf_wren(app_wdf_wren),
        .app_rd_data(app_rd_data), .app_rd_data_end(app_rd_data_end),
        .app_rd_data_valid(app_rd_data_valid), .app_rdy(app_rdy), .app_wdf_rdy(app_wdf_rdy),
        .app_sr_req(1'b0), .app_ref_req(1'b0), .app_zq_req(1'b0),
        .app_sr_active(), .app_ref_ack(), .app_zq_ack(),
        .ui_clk(ui_clk), .ui_clk_sync_rst(ui_rst),
        .init_calib_complete(init_calib_complete),
        .device_temp(),
        .sys_rst(sys_rst & osc_locked)   // active low: MIG in reset until the clock MMCM locks
    );

    // host adapter (sequential, v3) -> its app port goes through the
    // streamer's ownership mux
    wire         adp_req, adp_wr, adp_ready, adp_busy;
    wire [MEM_ADDR_WIDTH-1:0] adp_addr;
    wire [255:0] adp_wdata, adp_rdata;
    wire [31:0]  adp_wmask;
    wire [27:0]  h_app_addr; wire [2:0] h_app_cmd; wire h_app_en, h_app_rdy;
    wire [127:0] h_app_wdf_data; wire h_app_wdf_end; wire [15:0] h_app_wdf_mask;
    wire h_app_wdf_wren, h_app_wdf_rdy, h_app_rd_data_valid;

    mig_native_adapter #(.BURST_LEN(8), .ADDR_WIDTH(MEM_ADDR_WIDTH)) u_adapter (
        .clk(ui_clk), .rst(ui_rst),
        .req(adp_req), .wr(adp_wr), .addr(adp_addr), .wdata(adp_wdata), .wmask(adp_wmask),
        .rdata(adp_rdata), .ready(adp_ready), .busy(adp_busy),
        .app_addr(h_app_addr), .app_cmd(h_app_cmd), .app_en(h_app_en), .app_rdy(h_app_rdy),
        .app_wdf_data(h_app_wdf_data), .app_wdf_end(h_app_wdf_end), .app_wdf_mask(h_app_wdf_mask),
        .app_wdf_wren(h_app_wdf_wren), .app_wdf_rdy(h_app_wdf_rdy),
        .app_rd_data(app_rd_data), .app_rd_data_end(app_rd_data_end), .app_rd_data_valid(h_app_rd_data_valid)
    );

    // control signals (ui_clk) between the Quad-SPI port and the run logic
    wire net_start_ui;
    wire [MEM_ADDR_WIDTH-1:0] net_base_ui;
    wire busy_ui, done_ui, error_ui;
    wire flash_xfer_active, flash_byte_req, flash_byte_done;
    wire [7:0] flash_byte_wdata, flash_byte_rdata;

    flash_spi_master u_flash (
        .clk(ui_clk), .rst(ui_rst),
        .xfer_active(flash_xfer_active), .byte_req(flash_byte_req),
        .byte_wdata(flash_byte_wdata), .byte_rdata(flash_byte_rdata), .byte_done(flash_byte_done), .busy(),
        .flash_cs_n(flash_cs_n), .flash_mosi(flash_mosi), .flash_miso(flash_miso)
    );

    // the Quad-SPI port is the adapter's only master
    wire         q_active;
    wire         q_req, q_wr;    wire [MEM_ADDR_WIDTH-1:0] q_addr;  wire [255:0] q_wdata;  wire [31:0] q_wmask;
    assign adp_req   = q_req;
    assign adp_wr    = q_wr;
    assign adp_addr  = q_addr;
    assign adp_wdata = q_wdata;
    assign adp_wmask = q_wmask;

    // Quad-SPI data port
    wire [3:0] qio_in, qio_out;
    wire       qio_oe, qsclk_g;
    wire [3:0] qio_t;
`ifdef V4_SIM_CLK
    assign qsclk_g = qsclk;
    assign qio_in  = qio;
    assign qio     = qio_oe ? qio_out : 4'bzzzz;
`else
    BUFG u_bufg_qsclk (.I(qsclk), .O(qsclk_g));
    genvar qi;
    generate for (qi = 0; qi < 4; qi = qi + 1) begin : GEN_QIO
        IOBUF u_iob (.I(qio_out[qi]), .O(qio_in[qi]), .T(qio_t[qi]), .IO(qio[qi]));
    end endgenerate
`endif
    wire [31:0] q_nw, q_nr;
    qspi_data_port #(.DUMMY(64), .AW(MEM_ADDR_WIDTH)) u_qspi (
        .qsclk(qsclk_g), .qcs_n(qcs_n), .qio_in(qio_in), .qio_out(qio_out), .qio_oe(qio_oe), .qio_t(qio_t),
        .clk(ui_clk), .rst(ui_rst), .active(q_active), .m_grant(1'b1),
        .m_req(q_req), .m_wr(q_wr), .m_addr(q_addr), .m_wdata(q_wdata), .m_wmask(q_wmask),
        .m_rdata(adp_rdata), .m_ready(adp_ready),
        .n_write_words(q_nw), .n_read_words(q_nr),
        .calib_done(init_calib_complete), .run_busy(busy_ui), .run_done(done_ui), .run_error(error_ui),
        .net_start(net_start_ui), .net_base(net_base_ui), .data_ready_n(data_ready_n),
        .f_active(flash_xfer_active), .f_req(flash_byte_req), .f_wdata(flash_byte_wdata),
        .f_rdata(flash_byte_rdata), .f_done(flash_byte_done)
    );

    // =========================================================
    // core clock: MMCM on ui_clk
    // =========================================================
    wire core_clk, mmcm_fb, mmcm_locked, core_clk_unbuf;
`ifdef V4_SIM_CLK
    // simulation without unisims: ideal 5.017 ns clock
    reg sim_cclk = 0; always #2.5083 sim_cclk = ~sim_cclk;
    assign core_clk = sim_cclk;
    assign mmcm_locked = !ui_rst;
`else
    MMCME2_BASE #(
        .CLKIN1_PERIOD(6.452), .CLKFBOUT_MULT_F(9.000), .DIVCLK_DIVIDE(1),   // ui_clk 155.0 MHz -> 199.29 MHz
        .CLKOUT0_DIVIDE_F(7.000)
    ) u_mmcm (
        .CLKIN1(ui_clk), .CLKFBIN(mmcm_fb), .CLKFBOUT(mmcm_fb),
        .CLKOUT0(core_clk_unbuf), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKFBOUTB(),
        .LOCKED(mmcm_locked), .PWRDWN(1'b0), .RST(ui_rst)
    );
    BUFG u_bufg_core (.I(core_clk_unbuf), .O(core_clk));
`endif

    // core reset: held while the MMCM is unlocked or ui_clk is in reset
    (* ASYNC_REG = "TRUE" *) reg [3:0] crst_sync;
    always @(posedge core_clk or negedge mmcm_locked) begin
        if (!mmcm_locked) crst_sync <= 4'hF;
        else              crst_sync <= {crst_sync[2:0], 1'b0};
    end
    // two more register stages to spread the core reset (fanout in the
    // tens of thousands: the first board P&R had crst_sync -> core flops
    // among the failing paths); replicated by synthesis (max_fanout)
    reg core_rst_p = 1'b1;
    (* max_fanout = 64 *) reg core_rst = 1'b1;
    always @(posedge core_clk) begin
        core_rst_p <= crst_sync[3];
        core_rst   <= core_rst_p;
    end

    // =========================================================
    // clock-domain crossings
    // =========================================================
    // start: toggle ui -> core
    reg start_tgl_ui;
    always @(posedge ui_clk) if (ui_rst) start_tgl_ui <= 1'b0; else if (net_start_ui) start_tgl_ui <= ~start_tgl_ui;
    (* ASYNC_REG = "TRUE" *) reg [2:0] start_s;
    always @(posedge core_clk) start_s <= {start_s[1:0], start_tgl_ui};
    wire start_core = start_s[2] ^ start_s[1];
    // header address: quasi-static (written well before start)
    (* ASYNC_REG = "TRUE" *) reg [MEM_ADDR_WIDTH-1:0] base_s1, base_s2;
    always @(posedge core_clk) begin base_s1 <= net_base_ui; base_s2 <= base_s1; end

    // status: core -> ui
    wire boot_busy, boot_done, boot_error;
    reg  done_tgl_c;
    always @(posedge core_clk) if (core_rst) done_tgl_c <= 1'b0; else if (boot_done) done_tgl_c <= ~done_tgl_c;
    (* ASYNC_REG = "TRUE" *) reg [2:0] done_s;
    (* ASYNC_REG = "TRUE" *) reg [1:0] busy_s, err_s;
    always @(posedge ui_clk) begin
        done_s <= {done_s[1:0], done_tgl_c};
        busy_s <= {busy_s[0], boot_busy};
        err_s  <= {err_s[0], boot_error};
    end
    assign done_ui  = done_s[2] ^ done_s[1];
    assign busy_ui  = busy_s[1];
    assign error_ui = err_s[1];

    // DDR: read commands core -> ui, read data ui -> core, writes core -> ui
    wire        c_rq_valid, c_rq_full;
    wire [24:0] c_rq_addr;  wire [15:0] c_rq_len;
    wire        u_rc_valid_n, u_rc_pop;  wire [40:0] u_rc;
    async_fifo #(.DW(41), .AW(2)) u_rcf (
        .wclk(core_clk), .wrst(core_rst), .wr_en(c_rq_valid), .wr_data({c_rq_addr, c_rq_len}),
        .full(c_rq_full), .wr_count(),
        .rclk(ui_clk), .rrst(ui_rst), .rd_en(u_rc_pop), .rd_data(u_rc), .empty(u_rc_valid_n));

    wire         u_rd_push;  wire [127:0] u_rd_word;  wire [6:0] u_rd_cnt;
    wire         c_rd_empty; wire [127:0] c_rd_data;
    async_fifo #(.DW(128), .AW(6)) u_rdf (
        .wclk(ui_clk), .wrst(ui_rst), .wr_en(u_rd_push), .wr_data(u_rd_word),
        .full(), .wr_count(u_rd_cnt),
        .rclk(core_clk), .rrst(core_rst), .rd_en(!c_rd_empty), .rd_data(c_rd_data), .empty(c_rd_empty));
    // one register stage after the read-data FIFO (it always pops, no
    // backpressure): the fourth board P&R had the Gray-pointer compare ->
    // empty -> boot header-register enables at -0.1 ns. The boot/core
    // routing decision is registered with the word, as before.
    wire         run_phase;
    reg          c_rv_boot, c_rv_core;
    reg  [127:0] c_rd_q;
    always @(posedge core_clk) begin
        c_rv_boot <= !core_rst && !c_rd_empty && !run_phase;
        c_rv_core <= !core_rst && !c_rd_empty &&  run_phase;
        c_rd_q    <= c_rd_data;
    end

    wire         c_wq_valid, c_wq_full;  wire [24:0] c_wq_addr;  wire [127:0] c_wq_data;
    wire         u_wc_valid_n, u_wc_pop; wire [152:0] u_wc;
    async_fifo #(.DW(153), .AW(2)) u_wcf (
        .wclk(core_clk), .wrst(core_rst), .wr_en(c_wq_valid), .wr_data({c_wq_addr, c_wq_data}),
        .full(c_wq_full), .wr_count(),
        .rclk(ui_clk), .rrst(ui_rst), .rd_en(u_wc_pop), .rd_data(u_wc), .empty(u_wc_valid_n));

    v4_ddr_stream #(.RD_FIFO_DEPTH(64)) u_stream (
        .clk(ui_clk), .rst(ui_rst),
        .rc_valid(!u_rc_valid_n), .rc_pop(u_rc_pop), .rc_addr(u_rc[40:16]), .rc_len(u_rc[15:0]),
        .wc_valid(!u_wc_valid_n), .wc_pop(u_wc_pop), .wc_addr(u_wc[152:128]), .wc_data(u_wc[127:0]),
        .rd_push(u_rd_push), .rd_word(u_rd_word), .rd_fifo_count(u_rd_cnt),
        .h_app_addr(h_app_addr), .h_app_cmd(h_app_cmd), .h_app_en(h_app_en), .h_app_rdy(h_app_rdy),
        .h_app_wdf_data(h_app_wdf_data), .h_app_wdf_end(h_app_wdf_end), .h_app_wdf_mask(h_app_wdf_mask),
        .h_app_wdf_wren(h_app_wdf_wren), .h_app_wdf_rdy(h_app_wdf_rdy), .h_app_rd_data_valid(h_app_rd_data_valid),
        .h_busy(adp_busy),
        .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en), .app_rdy(app_rdy),
        .app_wdf_data(app_wdf_data), .app_wdf_end(app_wdf_end), .app_wdf_mask(app_wdf_mask),
        .app_wdf_wren(app_wdf_wren), .app_wdf_rdy(app_wdf_rdy),
        .app_rd_data(app_rd_data), .app_rd_data_end(app_rd_data_end), .app_rd_data_valid(app_rd_data_valid),
        .idle()
    );

    // =========================================================
    // core domain: boot controller + core, sharing the DDR read port
    // =========================================================
    wire        b_rq_valid;  wire [24:0] b_rq_addr;  wire [15:0] b_rq_len;
    wire        k_rq_valid;  wire [24:0] k_rq_addr;  wire [15:0] k_rq_len;
    wire [24:0] param_w;
    wire [24:0] desc_base;
    assign c_rq_valid = run_phase ? k_rq_valid : b_rq_valid;
    assign c_rq_addr  = run_phase ? (k_rq_addr + param_w) : b_rq_addr;
    assign c_rq_len   = run_phase ? k_rq_len : b_rq_len;
    // a request is taken the cycle it is written into the FIFO
    wire rq_ready = !c_rq_full;

    wire b_host_we, b_host_re, b_host_rvalid;
    wire [2:0] b_host_sel; wire [15:0] b_host_addr; wire [3:0] b_host_chunk;
    wire [127:0] b_host_wdata, b_host_rdata;
    wire core_start, core_done, core_error;
    wire [31:0] core_cycles, core_stall;

    v4_boot u_boot (
        .clk(core_clk), .rst(core_rst),
        .start(start_core), .hdr_w(base_s2 >> 2),
        .busy(boot_busy), .done(boot_done), .error(boot_error),
        .rq_valid(b_rq_valid), .rq_ready(rq_ready && !run_phase), .rq_addr(b_rq_addr), .rq_len(b_rq_len),
        .rd_valid(c_rv_boot), .rd_data(c_rd_q),
        .wq_valid(c_wq_valid), .wq_ready(!c_wq_full), .wq_addr(c_wq_addr), .wq_data(c_wq_data),
        .core_start(core_start), .core_done(core_done), .core_cycles(core_cycles),
        .core_stall(core_stall), .core_error(core_error),
        .run_phase(run_phase), .param_w(param_w), .desc_base(desc_base),
        .host_we(b_host_we), .host_re(b_host_re), .host_sel(b_host_sel), .host_addr(b_host_addr),
        .host_chunk(b_host_chunk), .host_wdata(b_host_wdata),
        .host_rvalid(b_host_rvalid), .host_rdata(b_host_rdata)
    );

    v4_core #(.NDESC(256), .WDEPTH(512), .DWDEPTH(64), .PWDEPTH(64),
              .N_DSP_COLS(14), .MAXW(64), .MAXNG(32), .MAXNCO(32)) u_core (
        .clk(core_clk), .rst(core_rst), .start(core_start), .done(core_done),
        .cycles(core_cycles), .stall_cycles(core_stall), .error(core_error),
        .host_we_i(b_host_we), .host_re_i(b_host_re), .host_sel_i(b_host_sel), .host_addr_i(b_host_addr),
        .host_chunk_i(b_host_chunk), .host_wdata_i(b_host_wdata),
        .host_rvalid(b_host_rvalid), .host_rdata(b_host_rdata),
        .desc_base(desc_base),
        .ddr_req_valid(k_rq_valid), .ddr_req_ready(rq_ready && run_phase),
        .ddr_req_addr(k_rq_addr), .ddr_req_len(k_rq_len),
        .ddr_rvalid(c_rv_core), .ddr_rdata(c_rd_q)
    );
endmodule
