// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- Quad-SPI host port: the ESP32's only link to the FPGA (DDR3
// bulk write/read, registers, status, configuration-flash access).
//
// Front end clocked DIRECTLY by QSCLK (a clock-capable pin, D15), SPI
// mode 0, everything on 4 lines (ESP-IDF: SPI_TRANS_MULTILINE_CMD |
// SPI_TRANS_MULTILINE_ADDR, QIO):
//
//   cmd  8 bit   0x1A = WRITE, 0x2A = READ
//   addr 48 bit  [47:16] W (128-bit DDR3 word address), [15:0] len (words)
//   READ only:   DUMMY clocks (lines released, FPGA fetches)
//   data 16*len bytes, byte k of a word = bits [8k+7:8k], each byte high
//        nibble first
//
// Control commands (same 56-bit header, no DDR3 access):
//   0x3A REG_WRITE  [47:16] value, [15:0] register; no data phase
//        reg 0x01 CONTROL: bit1 = start one inference (clears DONE)
//        reg 0x04 NETWORK_BASE: DDR3 32-bit-word address of the header
//   0x4A STATUS     a read (DUMMY clocks, then ONE 16-byte word):
//        [31:0] ID 0x4E505604  [63:32] NETWORK_BASE
//        [64] DDR3 calibrated [65] error [66] busy [67] done (sticky,
//        cleared by start) [68] flash transaction running
//        [127:69] 0. Reading it releases data_ready_n (done IRQ).
//   0x5A FLASH_XFER [15:0] n = 1..512 bytes; data phase ceil(n/16)
//        words: bytes 0..n-1 go to the configuration flash in ONE
//        transaction (CS low for all of them, ~19 MHz), each byte's
//        response replaces it in a 32-word buffer. The host polls
//        STATUS[68] until the transaction is over.
//   0x6A FLASH_READ [15:0] words (1..32): a read of the buffer, word 0
//        first (response of flash byte k = byte k%16 of word k/16)
//
// QCS_N high resets the front end (asynchronously). Header, write data
// and read data cross to ui_clk through async FIFOs; the ui_clk side
// (this module's lower half) moves the data with 256-bit bursts on the
// v3 memory-controller contract (req/wr/addr/wdata/wmask -> rdata/
// ready), i.e. behind mig_native_adapter.v.
//
// Read latency: after the address, the host gives DUMMY (default 64)
// clocks; the ui side starts fetching as soon as the header arrives and
// keeps a TX FIFO ahead of the host (DDR3 >> 40 MB/s).
// ============================================================
module qspi_data_port #(
    parameter DUMMY = 64,
    parameter AW    = 25
)(
    // ---- QSPI pins ----
    input  wire       qsclk,          // from a clock buffer
    input  wire       qcs_n,
    input  wire [3:0] qio_in,
    (* IOB = "TRUE" *) output reg [3:0] qio_out,
    output reg        qio_oe,
    (* IOB = "TRUE" *) output reg [3:0] qio_t,          // = !qio_oe per pin, for the IOBUF T pins (IOB flops)

    // ---- ui_clk side ----
    input  wire          clk,
    input  wire          rst,
    output wire          active,       // owns / wants the memory port
    input  wire          m_grant,      // arbiter: the memory port is ours
    output reg           m_req,
    output reg           m_wr,
    output reg  [AW-1:0] m_addr,       // 32-bit DDR word address, burst aligned
    output reg  [255:0]  m_wdata,
    output reg  [31:0]   m_wmask,      // 1 = byte masked
    input  wire [255:0]  m_rdata,
    input  wire          m_ready,

    output reg  [31:0]   n_write_words,   // statistics
    output reg  [31:0]   n_read_words,

    // ---- control (ui_clk) ----
    input  wire          calib_done,
    input  wire          run_busy,
    input  wire          run_done,     // pulse
    input  wire          run_error,
    output reg           net_start,    // pulse
    output reg  [AW-1:0] net_base,
    output wire          data_ready_n, // low: a run finished (until STATUS is read) or error

    // ---- configuration flash (flash_spi_master.v byte interface) ----
    output reg           f_active,     // flash CS (held for the whole transaction)
    output reg           f_req,
    output reg  [7:0]    f_wdata,
    input  wire [7:0]    f_rdata,
    input  wire          f_done
);
    // =========================================================
    // QSCLK domain
    // =========================================================
    reg [6:0]   nib;          // nibble counter within the header (0..13)
    reg [7:0]   cmd;
    reg [47:0]  addr;
    reg         hdr_done;
    reg [4:0]   dnib;         // nibble within a 128-bit word
    reg [127:0] word_sh;
    reg [15:0]  dummy_cnt;
    reg         is_read;

    // header FIFO (qsclk -> clk): {cmd[7:0], W[31:0], len[15:0]}.
    // Both qsclk -> clk FIFOs are written on the SAME edge that samples
    // the last nibble (combinational enable): QSCLK stops right after the
    // last data nibble, so a registered enable would never be seen by the
    // FIFO (found by the unit test: the last word of every write stayed
    // in the front end).
    wire        hf_we;
    wire [55:0] hf_wd;
    wire        hf_empty;
    wire [55:0] hf_rd;
    reg         hf_re;
    // write-data FIFO (qsclk -> clk)
    wire        wf_we;
    wire [127:0] wf_wd;
    wire        wf_empty;
    wire [127:0] wf_rd;
    reg         wf_re;
    // read-data FIFO (clk -> qsclk)
    reg         tf_we;
    reg [127:0] tf_wd;
    wire        tf_full;
    wire [5:0]  tf_cnt;
    wire        tf_empty;
    wire [127:0] tf_rd;
    wire        tf_re;

    // input side: posedge qsclk
    always @(posedge qsclk or posedge qcs_n) begin
        if (qcs_n) begin
            nib <= 7'd0; hdr_done <= 1'b0; dnib <= 5'd0; is_read <= 1'b0;
        end else begin
            if (!hdr_done) begin
                if (nib < 7'd2) cmd <= {cmd[3:0], qio_in};
                else            addr <= {addr[43:0], qio_in};
                nib <= nib + 7'd1;
                if (nib == 7'd13) begin
                    hdr_done <= 1'b1;
                    is_read  <= (cmd == 8'h2A) || (cmd == 8'h4A) || (cmd == 8'h6A);
                end
            end else if (!is_read) begin
                // byte k = nibbles 2k (high), 2k+1 (low); byte k at bits 8k
                word_sh[dnib[4:1]*8 + (dnib[0] ? 0 : 4) +: 4] <= qio_in;
                dnib <= dnib + 5'd1;
            end
        end
    end

    // power-on state below (flip-flop INIT on the FPGA): QCS_N is high
    // after configuration, but a level is not an edge -- the asynchronous
    // reset only fires on a rising QCS_N (found by the unit test: the very
    // first transaction after power-on was lost)
    assign hf_we = !qcs_n && !hdr_done && (nib == 7'd13);
    assign hf_wd = {cmd, addr[43:0], qio_in};
    assign wf_we = !qcs_n && hdr_done && !is_read && (dnib == 5'd31);
    assign wf_wd = {word_sh[127:124], qio_in, word_sh[119:0]};   // + low nibble of byte 15

    // output side: posedge qsclk. Each nibble is launched on the rising
    // edge BEFORE the one the host samples it on (a full period of
    // output time): the pin sees QSCLK through IBUF + BUFG (~4.6 ns) plus
    // clock-to-out + OBUF (~4 ns), too much for the half period of a
    // falling-edge launch at 80 MHz (first board P&R: -6.06 ns on qio).
    reg [15:0] dcnt;
    reg [4:0]  onib;
    reg        out_on;
    initial begin
        nib = 0; hdr_done = 0; dnib = 0; is_read = 0;
        dcnt = 0; onib = 0; out_on = 0; qio_oe = 0; qio_t = 4'hF; qio_out = 0;
    end
    // pop on the edge that launches the last nibble of a word: the next
    // edge already launches nibble 0 of the next word
    assign tf_re = out_on && (onib == 5'd31);
    always @(posedge qsclk or posedge qcs_n) begin
        if (qcs_n) begin
            qio_oe <= 1'b0; qio_t <= 4'hF; dcnt <= 16'd0; onib <= 5'd0; out_on <= 1'b0; qio_out <= 4'd0;
        end else if (hdr_done && is_read) begin
            if (!out_on) begin
                dcnt <= dcnt + 16'd1;
                // last dummy rising edge: launch the first data nibble
                if (dcnt == DUMMY - 1) begin
                    out_on <= 1'b1; qio_oe <= 1'b1; qio_t <= 4'h0;
                    qio_out <= tf_rd[7:4];              // byte 0 high nibble
                    onib <= 5'd1;
                end
            end else begin
                qio_out <= tf_rd[onib[4:1]*8 + (onib[0] ? 0 : 4) +: 4];
                onib <= onib + 5'd1;
            end
        end
    end

    // The three FIFOs are NEVER reset by ui_clk_sync_rst: their qsclk
    // side has no reset (QSCLK only runs during transactions), and a
    // one-sided reset would leave the two pointer sets inconsistent. They
    // start empty from the flip-flop INIT values. While rst is high the
    // ui side below discards whatever arrives (the host polls STATUS
    // right after releasing sys_rst, before the MIG releases ui_clk_sync_rst;
    // found in the ESP32 co-simulation, 2026-10-07).
    async_fifo #(.DW(56), .AW(2)) u_hf (
        .wclk(qsclk), .wrst(1'b0), .wr_en(hf_we), .wr_data(hf_wd), .full(), .wr_count(),
        .rclk(clk), .rrst(1'b0), .rd_en(hf_re), .rd_data(hf_rd), .empty(hf_empty));
    async_fifo #(.DW(128), .AW(4)) u_wf (
        .wclk(qsclk), .wrst(1'b0), .wr_en(wf_we), .wr_data(wf_wd), .full(), .wr_count(),
        .rclk(clk), .rrst(1'b0), .rd_en(wf_re), .rd_data(wf_rd), .empty(wf_empty));
    async_fifo #(.DW(128), .AW(5)) u_tf (
        .wclk(clk), .wrst(1'b0), .wr_en(tf_we), .wr_data(tf_wd), .full(tf_full), .wr_count(tf_cnt),
        .rclk(qsclk), .rrst(1'b0), .rd_en(tf_re), .rd_data(tf_rd), .empty(tf_empty));

    // =========================================================
    // ui_clk domain: move words between the FIFOs and DDR3 (bursts of
    // two 128-bit words = one 256-bit transaction at 8*(W>>1))
    // =========================================================
    localparam C_IDLE = 4'd0, C_WGET = 4'd1, C_WREQ = 4'd2, C_WWAIT = 4'd3,
               C_RREQ = 4'd4, C_RWAIT = 4'd5, C_RPUSH = 4'd6,
               C_STAT = 4'd7, C_FGET = 4'd8, C_FREAD = 4'd10;
    reg [3:0]  cs;

    // control registers + done IRQ
    reg        done_r, irq;
    reg        f_busy;
    assign data_ready_n = ~(irq | run_error);
    // flash transaction buffer: host bytes in, flash responses out
    (* ram_style = "distributed" *) reg [127:0] fbuf [0:31];
    // ONE registered write port (both FSMs below write it, never in the
    // same cycle), so the buffer maps to LUTRAM
    reg         fbw_en;
    reg [4:0]   fbw_a;
    reg [127:0] fbw_d;
    always @(posedge clk) if (fbw_en) fbuf[fbw_a] <= fbw_d;
    reg [4:0]   fw;           // buffer word (host side: FLASH_XFER in, FLASH_READ out)
    reg [4:0]   ffw;          // buffer word (flash side)
    reg         f_go;         // buffer loaded: run the flash transaction
    reg [4:0]   fw_last;
    reg [9:0]   fleft;        // flash bytes left
    reg [4:0]   fb;           // bytes of the current word already exchanged
    reg [127:0] fcur;         // word being shifted: tx byte at [7:0], responses enter at [127:120]
    localparam FS_LOAD = 2'd0, FS_SEND = 2'd1, FS_WAIT = 2'd2, FS_ALIGN = 2'd3;
    reg [1:0]   fs;
    reg [31:0] cw;            // current 128-bit word address
    reg [15:0] left;          // words left
    reg        have_lo, have_hi;
    reg [255:0] pend;
    reg [255:0] rbuf;
    reg        rhalf;         // next word to push is the high half of rbuf
    assign active = (cs == C_WGET) || (cs == C_WREQ) || (cs == C_WWAIT) || (cs == C_RREQ) ||
                    (cs == C_RWAIT) || (cs == C_RPUSH) ||
                    (cs == C_IDLE && !hf_empty && (hf_rd[55:48] == 8'h1A || hf_rd[55:48] == 8'h2A));
    wire [9:0] f_n = (hf_rd[15:0] > 16'd512) ? 10'd512 : hf_rd[9:0];
    wire [9:0] f_nm1 = f_n - 10'd1;

    always @(posedge clk) begin
        hf_re <= 1'b0; wf_re <= 1'b0; tf_we <= 1'b0; m_req <= 1'b0;
        net_start <= 1'b0; f_req <= 1'b0; f_go <= 1'b0; fbw_en <= 1'b0;
        if (run_done) begin done_r <= 1'b1; irq <= 1'b1; end
        if (rst) begin
            cs <= C_IDLE; n_write_words <= 0; n_read_words <= 0;
            done_r <= 1'b0; irq <= 1'b0; f_busy <= 1'b0; f_active <= 1'b0; net_base <= 0;
            fs <= FS_LOAD;
            // discard headers / write data that arrive during reset
            if (!hf_empty && !hf_re) hf_re <= 1'b1;
            if (!wf_empty && !wf_re) wf_re <= 1'b1;
        end else begin
        case (cs)
            // a new FLASH_XFER waits for the running one (the host polls
            // STATUS[68] first; this only keeps the buffer consistent)
            C_IDLE: if (!hf_empty && !hf_re && !(hf_rd[55:48] == 8'h5A && f_busy)) begin
                hf_re <= 1'b1;
                cw    <= hf_rd[47:16];
                left  <= hf_rd[15:0];
                have_lo <= 1'b0; have_hi <= 1'b0;
                fw <= 5'd0;
                case (hf_rd[55:48])
                    8'h3A: begin    // REG_WRITE
                        if (hf_rd[15:0] == 16'h0001 && hf_rd[17]) begin
                            net_start <= 1'b1; done_r <= 1'b0; irq <= 1'b0;
                        end
                        if (hf_rd[15:0] == 16'h0004) net_base <= hf_rd[16 +: AW];
                    end
                    8'h4A: cs <= C_STAT;
                    8'h5A: if (hf_rd[15:0] != 16'd0) begin
                        fleft <= f_n; fw_last <= f_nm1[8:4]; f_busy <= 1'b1; cs <= C_FGET;
                    end
                    8'h6A: if (hf_rd[15:0] != 16'd0) cs <= C_FREAD;
                    8'h2A: if (hf_rd[15:0] != 16'd0) cs <= C_RREQ;
                    8'h1A: if (hf_rd[15:0] != 16'd0) cs <= C_WGET;
                    default: ;
                endcase
            end
            // ---- control: status word ----
            C_STAT: begin
                tf_we <= 1'b1;
                tf_wd <= {59'd0, f_busy, done_r, run_busy, run_error, calib_done,
                          {(32-AW){1'b0}}, net_base, 32'h4E505604};
                irq <= 1'b0;
                cs <= C_IDLE;
            end
            // ---- flash: host bytes into the buffer, then hand over to
            // the flash FSM below (STATUS stays readable meanwhile) ----
            C_FGET: if (!wf_empty && !wf_re) begin
                wf_re <= 1'b1;
                fbw_en <= 1'b1; fbw_a <= fw; fbw_d <= wf_rd;
                if (fw == fw_last) begin
                    f_go <= 1'b1; cs <= C_IDLE;
                end else fw <= fw + 5'd1;
            end
            C_FREAD: begin
                if (!tf_full && tf_cnt <= 6'd29) begin
                    tf_we <= 1'b1; tf_wd <= fbuf[fw];
                    fw <= fw + 5'd1;
                    if (left == 16'd1) cs <= C_IDLE;
                    left <= left - 16'd1;
                end
            end
            // ---- write: gather the words of one burst, then write it ----
            C_WGET: if (!wf_empty && !wf_re) begin
                wf_re <= 1'b1;
                if (cw[0]) begin pend[255:128] <= wf_rd; have_hi <= 1'b1; end
                else       begin pend[127:0]   <= wf_rd; have_lo <= 1'b1; end
                n_write_words <= n_write_words + 1;
                // burst complete when the high word is in, or this is the last word
                if (cw[0] || left == 16'd1) cs <= C_WREQ;
                else begin cw <= cw + 1; left <= left - 16'd1; end
            end
            C_WREQ: if (m_grant) begin
                m_req   <= 1'b1;
                m_wr    <= 1'b1;
                m_addr  <= {cw[AW-3:1], 3'b000};
                m_wdata <= pend;
                m_wmask <= {{16{!have_hi}}, {16{!have_lo}}};
                cs <= C_WWAIT;
            end
            C_WWAIT: if (m_ready) begin
                have_lo <= 1'b0; have_hi <= 1'b0;
                if (left == 16'd1) cs <= C_IDLE;
                else begin cw <= cw + 1; left <= left - 16'd1; cs <= C_WGET; end
            end
            // ---- read: fetch a burst, push its needed words ----
            C_RREQ: if (tf_cnt <= 6'd29 && m_grant) begin
                m_req  <= 1'b1;
                m_wr   <= 1'b0;
                m_addr <= {cw[AW-3:1], 3'b000};
                cs <= C_RWAIT;
            end
            C_RWAIT: if (m_ready) begin
                rbuf  <= m_rdata;
                rhalf <= cw[0];
                cs <= C_RPUSH;
            end
            C_RPUSH: begin
                tf_we <= 1'b1;
                tf_wd <= rhalf ? rbuf[255:128] : rbuf[127:0];
                n_read_words <= n_read_words + 1;
                if (left == 16'd1) cs <= C_IDLE;
                else begin
                    cw <= cw + 1; left <= left - 16'd1;
                    if (rhalf) cs <= C_RREQ; else rhalf <= 1'b1;
                end
            end
            default: cs <= C_IDLE;
        endcase
        // ---- flash: one transaction, responses back into the buffer.
        // Runs beside the command FSM; it never writes fbuf while C_FGET
        // does (f_go comes after the last C_FGET write). ----
        if (f_busy) case (fs)
            FS_LOAD: if (f_active) begin fcur <= fbuf[ffw]; fb <= 5'd0; fs <= FS_SEND; end
                     else if (f_go) begin f_active <= 1'b1; ffw <= 5'd0; end
            FS_SEND: begin f_req <= 1'b1; f_wdata <= fcur[7:0]; fs <= FS_WAIT; end
            FS_WAIT: if (f_done) begin
                fleft <= fleft - 10'd1;
                if (fleft == 10'd1) begin
                    fcur <= {f_rdata, fcur[127:8]}; fb <= fb + 5'd1; fs <= FS_ALIGN;
                end else if (fb == 5'd15) begin
                    fbw_en <= 1'b1; fbw_a <= ffw; fbw_d <= {f_rdata, fcur[127:8]};
                    ffw <= ffw + 5'd1; fs <= FS_LOAD;
                end else begin
                    fcur <= {f_rdata, fcur[127:8]}; fb <= fb + 5'd1; fs <= FS_SEND;
                end
            end
            default: begin   // FS_ALIGN: last word, responses down to byte 0
                if (fb == 5'd16) begin
                    fbw_en <= 1'b1; fbw_a <= ffw; fbw_d <= fcur;
                    f_active <= 1'b0; f_busy <= 1'b0; fs <= FS_LOAD;
                end else begin
                    fcur <= {8'h00, fcur[127:8]}; fb <= fb + 5'd1;
                end
            end
        endcase
        end
    end
endmodule
