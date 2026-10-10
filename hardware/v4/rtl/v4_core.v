// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- G-esteso compute core: runs a whole network from a descriptor
// list, entirely on chip.
//
//   descriptor RAM --> layer sequencer --> fmap_feeder --> dwpw_engine
//        --> tile_writer (+ residual) --> fmap_mem (3 banks) --> ...
//
// One descriptor = one engine pass (a fused dw3x3 -> 1x1 layer, or a
// pointwise-only 1x1 layer, optionally restricted to a row window for
// banded processing). Layers run back to back; the next one starts as
// soon as the engine is done and the writer has retired every word.
//
// Descriptor word (256 bits: desc chunk 0 = [127:0], chunk 1 = [255:128]):
//   [0] pw_only [1] stride2 [2] res_en [3] last
//   [11:4] w  [19:12] h   (unpadded input map)
//   [25:20] ng (low 6 bits; [191:189] = ng bits 8:6, a pointwise pass
//         takes up to MAXNGV = 256 groups = 4096 inputs) [31:26] nco
//   [36:32] dw_shift [39:37] dw_ash [41:40] dw_act
//   [46:42] pw_shift [49:47] pw_ash [51:50] pw_act
//   [66:52] in_base [81:67] out_base [96:82] res_base [99:97] ngo_log2
//   [107:100] r_first [115:108] r_last   (padded input rows, inclusive)
//   [131:116] pos_offset (first output position of this pass)
//   [147:132] w_base (pw weight word) [159:148] dwp_base (dw group)
//   [171:160] pwp_base (pw output tile / GDConv group)
//   [188] im2col: first-layer input comes from im2col_feeder (raw image
//         at in_base, 3x3 pad 1, stride [1]) instead of fmap_feeder; w, h
//         are then the OUTPUT size, ng the beats per position, and
//         [180:173] image width  [183:181] image channels (1..4)
//         [89:82]   image height
//         replace the feeder start word and res_base (unused by an
//         im2col pass); image rows are ceil(width*channels/16) words
//   [187:173] feeder start word (in_base + max(r_first-pad,0)*w*ng)
//   [192] conv3: dense 3x3 convolution (pad 1, stride [1]) on the
//         feature map at in_base, through conv3_feeder (pointwise-only
//         pass, ng = 9 * input groups, w, h = OUTPUT size), with
//         [200:193] input width  [208:201] input height
//         [214:209] input groups [229:215] input row stride (width*groups)
//   [230] pool: max/average pooling (pool_unit.v) over a KxK window of
//         the map at in_base, through conv3_feeder (same fields as conv3:
//         input size, groups, row stride; w, h = OUTPUT size, ng = groups)
//         [231] 2x2 window (else 3x3) [232] no padding (else pad 1)
//         [233] max (else average) [241:234] mul [245:242] shift
//   [246] 1x1 window (copy / upsampling) [247] 2x nearest upsampling
//   [253:248] groups emitted per position by the window feeder (pooling:
//         output groups, >= input groups [214:209]; extra = zero)
//   [255:254] reserved (0)
//   [172] gdconv: global depthwise (GDConv 7x7) pass on gdconv_unit --
//         uses w, h, ng, in_base, out_base, w_base (16 bytes of weights
//         per beat, packed 16 beats per 2048-bit word), pw_* requant and
//         pwp_base; output = 1x1 x (ng*16) at out_base
//
// Descriptors are not kept on chip: before each pass's parameters are
// loaded, its three descriptor words are read from DDR3 at
// desc_base + 3*pass (pass n+1's are read while pass n computes).
//
// Host port (while the core is idle): 128-bit chunk writes into every
// memory (sel 1 pw weights [16], 2 dw weights [9],
// 3 dw requant [5], 4 pw requant [5], 5 feature map) and feature-map
// reads (sel 6, data on host_rdata 6 cycles later with host_rvalid).
// The wide memories are split into 128-bit chunk arrays so every write
// is a full-width write of one physical RAM. How they are filled from
// DDR3 during inference is a separate block (later step).
// ============================================================
module v4_core #(
    parameter NDESC   = 256,    // unused (descriptors are read from DDR3); passes <= 256 (li: 8 bits)
    parameter WDEPTH  = 4096,   // pw weight words (2048 bits each)
    parameter DWDEPTH = 256,    // dw weight / dw requant groups
    parameter PWDEPTH = 512,    // pw requant tiles
    parameter N_DSP_COLS = 14,
    parameter MAXW    = 128,
    parameter MAXNG   = 32,
    parameter MAXNCO  = 32,
    parameter MAXNGV  = 256,    // pointwise input groups (Cin <= 16*MAXNGV)
    parameter LBDEPTH = 512
)(
    input  wire clk,
    input  wire rst,
    input  wire start,
    output reg  done,
    output reg  [31:0] cycles,
    output reg  [31:0] stall_cycles,   // cycles spent waiting for DDR3 parameter loads
    output wire error,

    input  wire          host_we_i,
    input  wire          host_re_i,
    input  wire [2:0]    host_sel_i,
    input  wire [15:0]   host_addr_i,
    input  wire [3:0]    host_chunk_i,
    input  wire [127:0]  host_wdata_i,
    output reg           host_rvalid,
    output wire [127:0]  host_rdata,

    // DDR3 address of the descriptor table (3 words per pass: desc chunk
    // 0, chunk 1, load descriptor), in the same coordinates as
    // ddr_req_addr; stable from start to done
    input  wire [24:0]   desc_base,

    // DDR3 read port for the parameter loader (request + in-order stream)
    output wire          ddr_req_valid,
    input  wire          ddr_req_ready,
    output wire [24:0]   ddr_req_addr,
    output wire [15:0]   ddr_req_len,
    input  wire          ddr_rvalid,
    input  wire [127:0]  ddr_rdata
);
    localparam AW = 15;
    localparam P = 16, P_CO = 16;

    // ---------------- host port input registers ----------------
    // one register stage on every host input (the first board P&R had
    // v4_boot -> desc/fmap/memory write enables at -0.78 ns: the core-only
    // wrapper v4_core_top had its own staging + multicycle constraints)
    reg          host_we, host_re;
    reg [2:0]    host_sel;
    (* max_fanout = 32 *) reg [15:0] host_addr;
    reg [3:0]    host_chunk;
    (* max_fanout = 32 *) reg [127:0] host_wdata;
    always @(posedge clk) begin
        host_we <= host_we_i; host_re <= host_re_i; host_sel <= host_sel_i;
        host_addr <= host_addr_i; host_chunk <= host_chunk_i; host_wdata <= host_wdata_i;
    end

    // ---------------- memory write port: host (idle) or loader ----------------
    wire         ld_we;
    wire [2:0]   ld_sel;
    wire [15:0]  ld_addr;
    wire [3:0]   ld_chunk;
    wire [127:0] ld_data;
    wire         mw_en_c    = ld_we | host_we;
    wire [2:0]   mw_sel_c   = ld_we ? ld_sel   : host_sel;
    wire [15:0]  mw_addr_c  = ld_we ? ld_addr  : host_addr;
    wire [3:0]   mw_chunk_c = ld_we ? ld_chunk : host_chunk;
    wire [127:0] mw_data_c  = ld_we ? ld_data  : host_wdata;
    // registered, with the (sel, chunk) decode done here once: the fifth
    // P&R had loader sel -> decode -> LUTRAM write enables at -0.40 ns
    reg          mw_en;
    reg [2:0]    mw_sel;
    reg [15:0]   mw_addr;
    reg [3:0]    mw_chunk;
    reg [127:0]  mw_data;
    reg [15:0]   we_w;
    reg [8:0]    we_dww;
    reg [4:0]    we_dwq, we_pwq;
    integer      mi;
    always @(posedge clk) begin
        mw_en <= mw_en_c; mw_sel <= mw_sel_c; mw_addr <= mw_addr_c;
        mw_chunk <= mw_chunk_c; mw_data <= mw_data_c;
        for (mi = 0; mi < 16; mi = mi + 1) we_w[mi]   <= mw_en_c && mw_sel_c == 3'd1 && mw_chunk_c == mi;
        for (mi = 0; mi < 9;  mi = mi + 1) we_dww[mi] <= mw_en_c && mw_sel_c == 3'd2 && mw_chunk_c == mi;
        for (mi = 0; mi < 5;  mi = mi + 1) begin
            we_dwq[mi] <= mw_en_c && mw_sel_c == 3'd3 && mw_chunk_c == mi;
            we_pwq[mi] <= mw_en_c && mw_sel_c == 3'd4 && mw_chunk_c == mi;
        end
    end

    // ---------------- memories (128-bit chunk arrays) ----------------
    genvar gk;
    // pw weights: 16 chunks, synchronous read
    wire [15:0]   e_w_addr;
    // kept as fabric flops: the first generic-board P&R had them merged
    // away (BRAM output register + DSP B register), leaving a single
    // BRAM -> DSP route at -0.88 ns
    reg [2047:0] w_data_r;
    wire [15:0]   w_rd_addr;
    generate
        for (gk = 0; gk < 16; gk = gk + 1) begin : GEN_WC
            (* ram_style = "block" *) reg [127:0] mem [0:WDEPTH-1];
            reg [127:0] q1;
            // local copy of the write port next to each bank: the first
            // generic-board P&R had mw_data -> the 16 spread BRAM pairs at
            // -1.32 ns, almost all route (2026-10-07). One more cycle of
            // write latency; the weights are read passes later.
            reg          wl_en;
            reg [15:0]   wl_addr;
            reg [127:0]  wl_data;
            always @(posedge clk) begin
                wl_en <= we_w[gk]; wl_addr <= mw_addr; wl_data <= mw_data;
                if (wl_en) mem[wl_addr] <= wl_data;
                q1 <= mem[w_rd_addr];
                w_data_r[gk*128 +: 128] <= q1;     // extra stage: engine W_LAT = 2
            end
        end
    endgenerate

    // dw weights (9 chunks), dw requant (5), pw requant (5): small,
    // combinational read (distributed RAM)
    wire [5:0]    wd_g, rq_g, pwq_cot;
    wire [11:0]   dwq_a, pwq_a;
    wire [639:0]  dwq, pwq;
    generate
        // each bank has its own copy of the write port, as GEN_WC (the
        // first generic-board P&R had mw_addr/mw_data/we -> these LUTRAMs
        // at -0.75..-1.07 ns, all route)
        // dw weights: inside dw_linebuf_grouped (DWW_INT), written through
        // we_dww / mw_addr / mw_data (registered here)
        for (gk = 0; gk < 5; gk = gk + 1) begin : GEN_DWQ
            reg                        wl_en;
            reg [$clog2(DWDEPTH)-1:0]  wl_addr;
            reg [127:0]                wl_data;
            always @(posedge clk) begin
                wl_en <= we_dwq[gk]; wl_addr <= mw_addr[$clog2(DWDEPTH)-1:0]; wl_data <= mw_data;
            end
            param_lutram #(.DEPTH(DWDEPTH), .AW($clog2(DWDEPTH))) u_m (
                .clk(clk), .we(wl_en), .waddr(wl_addr), .wdata(wl_data),
                .raddr(dwq_a), .rdata(dwq[gk*128 +: 128]));
        end
        for (gk = 0; gk < 5; gk = gk + 1) begin : GEN_PWQ
            reg                        wl_en;
            reg [$clog2(PWDEPTH)-1:0]  wl_addr;
            reg [127:0]                wl_data;
            always @(posedge clk) begin
                wl_en <= we_pwq[gk]; wl_addr <= mw_addr[$clog2(PWDEPTH)-1:0]; wl_data <= mw_data;
            end
            param_lutram #(.DEPTH(PWDEPTH), .AW($clog2(PWDEPTH))) u_m (
                .clk(clk), .we(wl_en), .waddr(wl_addr), .wdata(wl_data),
                .raddr(pwq_a), .rdata(pwq[gk*128 +: 128]));
        end
    endgenerate
    // ---------------- descriptor fetch + parameter loader ----------------
    // df_go: read the next pass's three descriptor words (one DDR request
    // at df_ptr) into nd_lo/nd_hi/nd_ld, then start the parameter loader
    // with nd_ld. The two never use the DDR port at the same time: the
    // loader starts only after the descriptor's last word arrived.
    reg         df_go;
    reg         df_init;      // with the first df_go: table pointer = desc_base
    reg         ld_half_n;    // half for the load that follows the fetch
    localparam DF_IDLE = 2'd0, DF_REQ = 2'd1, DF_DATA = 2'd2;
    reg [1:0]   df_st;
    reg [1:0]   df_cnt;
    reg [24:0]  df_ptr;
    reg [127:0] nd_lo, nd_hi, nd_ld;
    reg         df_req_valid;
    wire        df_busy = (df_st != DF_IDLE) || df_go;

    reg         ld_start;
    reg         ld_half;
    wire        ld_busy;
    wire        pl_req_valid;
    wire [24:0] pl_req_addr;
    wire [15:0] pl_req_len;
    param_loader u_ld (
        .clk(clk), .rst(rst), .start(ld_start), .ldesc(nd_ld), .half(ld_half), .busy(ld_busy),
        .req_valid(pl_req_valid), .req_ready(ddr_req_ready), .req_addr(pl_req_addr), .req_len(pl_req_len),
        .rvalid(ddr_rvalid && df_st != DF_DATA), .rdata(ddr_rdata),
        .wr_en(ld_we), .wr_sel(ld_sel), .wr_addr(ld_addr), .wr_chunk(ld_chunk), .wr_data(ld_data)
    );
    assign ddr_req_valid = df_req_valid | pl_req_valid;
    assign ddr_req_addr  = df_req_valid ? df_ptr : pl_req_addr;
    assign ddr_req_len   = df_req_valid ? 16'd3  : pl_req_len;

    always @(posedge clk) begin
        ld_start <= 1'b0;
        if (df_init) df_ptr <= desc_base;
        if (rst) begin
            df_st <= DF_IDLE; df_req_valid <= 1'b0;
        end else case (df_st)
            DF_IDLE: if (df_go) begin
                df_req_valid <= 1'b1; df_cnt <= 2'd0; df_st <= DF_REQ;
            end
            DF_REQ: if (ddr_req_ready) begin
                df_req_valid <= 1'b0; df_st <= DF_DATA;
            end
            DF_DATA: if (ddr_rvalid) begin
                case (df_cnt)
                    2'd0: nd_lo <= ddr_rdata;
                    2'd1: nd_hi <= ddr_rdata;
                    default: nd_ld <= ddr_rdata;
                endcase
                df_cnt <= df_cnt + 2'd1;
                if (df_cnt == 2'd2) begin
                    df_ptr <= df_ptr + 25'd3;
                    ld_start <= 1'b1; ld_half <= ld_half_n;
                    df_st <= DF_IDLE;
                end
            end
            default: df_st <= DF_IDLE;
        endcase
    end

    // ---------------- sequencer ----------------
    localparam S_IDLE = 3'd0, S_LOAD = 3'd1, S_GO = 3'd2, S_RUN = 3'd3, S_NEXT = 3'd4, S_PREP = 3'd5,
               S_WAITL = 3'd6;
    reg [2:0]  state;
    reg [7:0]  li;            // layer index
    reg [255:0] d;            // current descriptor
    (* max_fanout = 32 *) reg        go;            // start pulse to engine/feeder/writer
    reg        eng_done_seen;
    reg [31:0] layer_t0;

    wire d_pw_only = d[0];
    wire d_s2      = d[1];
    wire d_res     = d[2];
    wire d_last    = d[3];
    wire d_gd      = d[172];
    wire d_i2c     = d[188];
    wire d_c3      = d[192];
    wire d_pool    = d[230];
    wire d_win     = d_c3 | d_pool;    // conv3_feeder pass
    wire [7:0]  d_w   = d[11:4];
    wire [7:0]  d_h   = d[19:12];
    wire [8:0]  d_ng  = {d[191:189], d[25:20]};
    wire [5:0]  d_nco = d[31:26];
    wire [7:0]  d_rf  = d[107:100];
    wire [7:0]  d_rl  = d[115:108];

    wire eng_done;
    wire wr_idle;
    wire w_en, fm_wbusy;   // writer write enable, fmap write still landing
    wire pool_done;        // declared before its use in the pass FSM
    wire feed_busy;
    wire gd_done, gd_in_ready;
    (* shreg_extract = "no" *) reg [639:0] pwq_r;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; done <= 1'b0; go <= 1'b0; cycles <= 32'd0; li <= 8'd0;
            df_go <= 1'b0; df_init <= 1'b0;
        end else begin
            go <= 1'b0;
            df_go <= 1'b0;
            df_init <= 1'b0;
            if (state != S_IDLE) cycles <= cycles + 32'd1;
            case (state)
                S_IDLE: if (start) begin
                    li <= 8'd0; cycles <= 32'd0; done <= 1'b0; stall_cycles <= 32'd0;
                    // descriptor + parameters of pass 0 into half 0 (not overlapped)
                    df_go <= 1'b1; df_init <= 1'b1; ld_half_n <= 1'b0;
                    state <= S_WAITL;
                end
                // pass li may start only once its parameters are on chip
                S_WAITL: begin
                    if (!df_busy && !ld_busy && !ld_start) state <= S_LOAD;
                    else stall_cycles <= stall_cycles + 32'd1;
                end
                S_LOAD: begin
                    d <= {nd_hi, nd_lo};   // pass li's, fetched before its parameters
                    state <= S_PREP;
                end
                S_PREP: state <= S_GO;   // feeder start address: 2 registered steps
                S_GO: begin
                    go <= 1'b1;
                    // prefetch pass li+1's parameters into the other half,
                    // overlapped with pass li (half (li+1)%2 was pass li-1's)
                    if (!d_last) begin
                        df_go <= 1'b1; ld_half_n <= ~li[0];
                    end
                    eng_done_seen <= 1'b0;
                    layer_t0 <= cycles;
                    state <= S_RUN;
                end
                S_RUN: begin
                    // `go` is still high in the first S_RUN cycle: the engine
                    // has not been reset yet and its `done` may still be the
                    // PREVIOUS layer's (it pulses every other cycle while
                    // idle) -- found by tb_v4_core_mfn: pass 33 "finished"
                    // in 2 cycles and every later pass mismatched.
                    if ((d_gd ? gd_done : d_pool ? pool_done : eng_done) && !go) eng_done_seen <= 1'b1;
                    if (eng_done_seen && wr_idle && !w_en && !fm_wbusy && !go) begin
`ifndef SYNTHESIS
                        $display("[v4_core] layer %0d done: %0d cycles (%s, in %0dx%0d, ng=%0d nco=%0d%s)",
                                 li, cycles - layer_t0, d_gd ? "GDConv " : d_pool ? "pooling" : (d_pw_only ? "pw-only" : "dw+pw"),
                                 d_w, d_h, d_ng, d_nco, d_res ? ", residual" : "");
`endif
                        state <= S_NEXT;
                    end
                end
                S_NEXT: begin
                    if (d_last) begin
`ifndef SYNTHESIS
                        $display("[v4_core] network done: %0d cycles, of which %0d waiting for parameter loads", cycles, stall_cycles);
`endif
                        done <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        li <= li + 8'd1;
                        state <= S_WAITL;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // ---------------- feature-map memory ----------------
    // registered: host accesses only happen long after the core went
    // idle, core accesses only start cycles after it left idle
    (* max_fanout = 16 *) reg idle_h;
    always @(posedge clk) idle_h <= (state == S_IDLE);
    wire host_we_f = host_we && host_sel == 3'd5;
    wire host_re_f = host_re && host_sel == 3'd6;
    reg  hr1, hr2, hr3, hr4;
    always @(posedge clk) begin
        hr1 <= idle_h && host_re_f;
        hr2 <= hr1;
        hr3 <= hr2;
        hr4 <= hr3;
        host_rvalid <= hr4;
    end

    wire          f_rd_en;  wire [AW-1:0] f_rd_addr;  wire [127:0] f_rd_data;
    wire          r_rd_en;  wire [AW-1:0] r_rd_addr;  wire [127:0] r_rd_data;
    wire [AW-1:0] w_addr_fm;  wire [127:0] w_data_fm;
    wire          mem_conflict;

    fmap_mem #(.NB(3), .BANK_WORDS(8192), .AW(AW)) u_fmap (
        .clk(clk), .rst(rst),
        .rd0_en(f_rd_en), .rd0_addr(f_rd_addr), .rd0_data(f_rd_data),
        .rd1_en(idle_h ? host_re_f : r_rd_en), .rd1_addr(idle_h ? host_addr[AW-1:0] : r_rd_addr), .rd1_data(r_rd_data),
        .wr_en(idle_h ? host_we_f : w_en), .wr_addr(idle_h ? host_addr[AW-1:0] : w_addr_fm),
        .wr_data(idle_h ? host_wdata : w_data_fm),
        .conflict(mem_conflict), .wr_busy(fm_wbusy)
    );

    // ---------------- feeder ----------------
    wire         fe_valid, fe_ready;
    wire [127:0] fe_data;
    wire          ff_rd_en;  wire [AW-1:0] ff_rd_addr;
    wire          ff_valid;  wire [127:0]  ff_data;
    wire          ic_rd_en;  wire [AW-1:0] ic_rd_addr;
    wire          ic_valid;  wire [127:0]  ic_data;
    wire          c3_rd_en;  wire [AW-1:0] c3_rd_addr;
    wire          c3_valid;  wire [127:0]  c3_data;
    wire          c3_pad;
    assign f_rd_en   = d_i2c ? ic_rd_en   : d_win ? c3_rd_en   : ff_rd_en;
    assign f_rd_addr = d_i2c ? ic_rd_addr : d_win ? c3_rd_addr : ff_rd_addr;
    assign fe_valid  = d_i2c ? ic_valid   : d_win ? c3_valid   : ff_valid;
    // data mux selects: registered copies of the pass type (d -> mux ->
    // engine vw_data was -0.86 ns in the first generic-board P&R)
    (* max_fanout = 32 *) reg m_i2c, m_win;
    always @(posedge clk) begin m_i2c <= d_i2c; m_win <= d_win; end
    assign fe_data   = m_i2c ? ic_data    : m_win ? c3_data    : ff_data;

    // image words per row, registered: d is stable from S_LOAD, two
    // cycles before `go`
    reg [4:0] i2c_rw;
    always @(posedge clk) i2c_rw <= (d[180:173] * d[183:181] + 11'd15) >> 4;
    im2col_feeder #(.AW(AW)) u_i2c (
        .clk(clk), .rst(rst), .start(go && d_i2c), .cfg_base(d[66:52]),
        .cfg_iw(d[180:173]), .cfg_ih(d[89:82]), .cfg_c(d[183:181]), .cfg_s2(d_s2), .cfg_rw(i2c_rw),
        .cfg_ow(d_w), .cfg_oh(d_h), .cfg_ng(d_ng[1:0]),
        .rd_en(ic_rd_en), .rd_addr(ic_rd_addr), .rd_data(f_rd_data),
        .out_valid(ic_valid), .out_ready(fe_ready), .out_data(ic_data)
    );

    // dense 3x3 convolution / pooling windows anywhere in the network
    wire c3_busy;
    conv3_feeder #(.AW(AW)) u_c3 (
        .clk(clk), .rst(rst), .start(go && d_win), .busy(c3_busy),
        .cfg_base(d[66:52]), .cfg_iw(d[200:193]), .cfg_ih(d[208:201]), .cfg_ng(d[214:209]),
        .cfg_rs(d[229:215]), .cfg_s2(d_s2), .cfg_ow(d_w), .cfg_oh(d_h),
        .cfg_pool(d_pool), .cfg_k2(d[231]), .cfg_pad(!d[232]),
        .cfg_k1(d[246]), .cfg_up2(d[247]), .cfg_nge(d_c3 ? d[214:209] : d[253:248]),
        .rd_en(c3_rd_en), .rd_addr(c3_rd_addr), .rd_data(f_rd_data),
        .out_valid(c3_valid), .out_ready(d_pool ? 1'b1 : fe_ready), .out_data(c3_data), .out_pad(c3_pad)
    );

    wire         pool_t_valid, pool_t_odd;
    wire [15:0]  pool_t_pair;
    wire [5:0]   pool_t_cot;
    wire [127:0] pool_t_y;
    pool_unit u_pool (
        .clk(clk), .rst(rst), .start(go && d_pool), .done(pool_done),
        .cfg_ow_i(d_w), .cfg_oh_i(d_h), .cfg_ng_i(d[253:248]), .cfg_k2_i(d[231]), .cfg_k1_i(d[246]),
        .cfg_max_i(d[233]),
        .cfg_mul_i(d[241:234]), .cfg_sh_i(d[245:242]),
        .in_valid(c3_valid && d_pool), .in_ready(), .in_data(c3_data), .in_pad(c3_pad),
        .t_valid(pool_t_valid), .t_pair(pool_t_pair), .t_odd(pool_t_odd), .t_cot(pool_t_cot), .t_y(pool_t_y)
    );

    fmap_feeder #(.AW(AW)) u_feed (
        .clk(clk), .rst(rst), .start(go && !d_i2c && !d_c3), .busy(feed_busy),
        .cfg_base(d[187:173]), .cfg_w(d_w), .cfg_h(d_h), .cfg_ng(d_ng),
        .cfg_pad(!d_pw_only && !d_gd), .cfg_r_first(d_rf), .cfg_r_last(d_rl),
        .rd_en(ff_rd_en), .rd_addr(ff_rd_addr), .rd_data(f_rd_data),
        .out_valid(ff_valid), .out_ready(d_gd ? gd_in_ready : fe_ready), .out_data(ff_data)
    );

    // ---------------- engine ----------------
    // GDConv unit (MobileFaceNet's global depthwise 7x7)
    wire [15:0]  gd_w_addr;
    wire [3:0]   gd_w_chunk;
    wire [5:0]   gd_q_g;
    wire         gd_t_valid;
    wire [5:0]   gd_t_cot;
    wire [127:0] gd_t_y;
    reg  [3:0]   gd_chunk_d0, gd_chunk_d;
    reg  [127:0] gd_wsel;
    always @(posedge clk) begin
        gd_chunk_d0 <= gd_w_chunk;
        gd_chunk_d  <= gd_chunk_d0;
        gd_wsel    <= w_data_r[gd_chunk_d*128 +: 128];
    end
    // GDConv uses the engine's pointwise requant (lanes 0..15)
    wire [511:0] gd_rq_acc;
    wire [127:0] o_ya, o_yb;
    (* max_fanout = 64 *) reg gd_sel;
    always @(posedge clk) gd_sel <= d_gd;
    gdconv_unit #(.MAXNG(MAXNG)) u_gd (
        .clk(clk), .rst(rst), .start(go && d_gd), .done(gd_done),
        .cfg_npos_i(d_w * d_h), .cfg_ng_i(d_ng[5:0]), .cfg_w_base_i(d[147:132]),
        .cfg_shift_i(d[46:42]), .cfg_ash_i(d[49:47]), .cfg_act_i(d[51:50]),
        .in_valid(fe_valid && d_gd), .in_ready(gd_in_ready), .in_pix(fe_data),
        .w_addr(gd_w_addr), .w_chunk(gd_w_chunk), .w_data(gd_wsel),
        .q_g(gd_q_g), .q_bias(pwq_r[511:0]), .q_alpha(pwq_r[639:512]),
        .rq_acc(gd_rq_acc), .rq_y(o_ya),
        .t_valid(gd_t_valid), .t_cot(gd_t_cot), .t_y(gd_t_y)
    );

    assign w_rd_addr = d_gd ? gd_w_addr : e_w_addr;   // engine keeps base + offset in a register
    assign dwq_a = d[159:148] + rq_g;
    // pw / GDConv requant params: key registered, then the lookup
    // registered (2 cycles; both requants use BIAS_LAT = 1). The tag
    // pointer only moves on a result and results are >= 2 cycles apart,
    // so the key sampled the cycle before a result is that result's.
    // (the add is inside the register: d -> add -> LUTRAM address was
    // -0.68 ns in the first generic-board P&R; d is stable for the pass)
    (* shreg_extract = "no", max_fanout = 16 *) reg [11:0] pwq_a_r;
    always @(posedge clk) pwq_a_r <= d[171:160] + (d_gd ? gd_q_g : pwq_cot);
    assign pwq_a = pwq_a_r;

    // pw requant params: registered lookup of the head tag. The engine's
    // results are >= ng >= 2 cycles apart, so after the tag pointer moves
    // the registered value is refreshed before the next result samples it
    // (unregistered: tq_rd -> tag -> LUTRAM -> requant was -0.12 ns).
    always @(posedge clk) pwq_r <= pwq;

    wire        o_valid, o_b_valid;
    wire [15:0] o_pair;
    wire [5:0]  o_cot;

    dwpw_engine #(.P(P), .P_CO(P_CO), .N_DSP_COLS(N_DSP_COLS),
                  .MAXW(MAXW), .MAXNG(MAXNG), .MAXNGV(MAXNGV), .MAXNCO(MAXNCO), .LBDEPTH(LBDEPTH), .W_LAT(2),
                  .DW_HALF(1),     // 8 depthwise MACs (2026-10-08, area)
                  .DWW_INT(1), .DWDEPTH(DWDEPTH)) u_eng (
        .clk(clk), .rst(rst), .start(go && !d_gd && !d_pool), .done(eng_done),
        .cfg_w_i(d_pw_only ? d_w : d_w + 8'd2),
        .cfg_h_i(d_pw_only ? d_h : (d_rl - d_rf + 8'd1)),
        .cfg_ng_i(d_ng), .cfg_nco_i(d_nco), .cfg_stride2_i(d_s2), .cfg_pw_only_i(d_pw_only),
        .dw_shift_i(d[36:32]), .dw_ash_i(d[39:37]), .dw_act_i(d[41:40]),
        .pw_shift_i(d[46:42]), .pw_ash_i(d[49:47]), .pw_act_i(d[51:50]),
        .in_valid(fe_valid && !d_gd && !d_pool), .in_ready(fe_ready), .in_pix(fe_data),
        .wd_g(wd_g), .wd_flat(1152'd0),
        .dww_we(we_dww), .dww_waddr(mw_addr[7:0]), .dww_wdata(mw_data), .dww_base(d[159:148]),
        .rq_g(rq_g), .dw_bias(dwq[511:0]), .dw_alpha(dwq[639:512]),
        .w_base_i(d[147:132]), .w_addr(e_w_addr), .w_data(w_data_r),
        .pwq_cot(pwq_cot), .pw_bias(pwq_r[511:0]), .pw_alpha(pwq_r[639:512]),
        .o_valid(o_valid), .o_pair(o_pair), .o_cot(o_cot), .o_b_valid(o_b_valid),
        .o_ya(o_ya), .o_yb(o_yb),
        .x_sel(gd_sel), .x_acc(gd_rq_acc)
    );

    // ---------------- writer ----------------
    wire wr_overflow;
    // registered copies of the pass type for the writer's wide input
    // mux (d -> mux -> ti_ya was -1.02 ns); d is loaded long before go
    (* max_fanout = 32 *) reg m_gd, m_pool;
    always @(posedge clk) begin m_gd <= d_gd; m_pool <= d_pool; end
    tile_writer #(.AW(AW)) u_wr (
        .clk(clk), .rst(rst), .start(go),
        .cfg_out_base_i(d[81:67]), .cfg_ngo_log2_i(d[99:97]), .cfg_pos_offset_i(d[131:116]),
        .cfg_res_en_i(d_res), .cfg_res_base_i(d[96:82]),
        .t_valid(m_gd ? gd_t_valid : m_pool ? pool_t_valid : o_valid),
        .t_pair(m_gd ? 16'd0 : m_pool ? pool_t_pair : o_pair),
        .t_cot(m_gd ? gd_t_cot : m_pool ? pool_t_cot : o_cot),
        .t_b_valid(m_gd || m_pool ? 1'b0 : o_b_valid), .t_odd(m_pool && pool_t_odd),
        .t_ya(m_gd ? gd_t_y : m_pool ? pool_t_y : o_ya), .t_yb(o_yb),
        .rd_en(r_rd_en), .rd_addr(r_rd_addr), .rd_data(r_rd_data),
        .wr_en(w_en), .wr_addr(w_addr_fm), .wr_data(w_data_fm),
        .idle(wr_idle), .overflow(wr_overflow)
    );

    reg [127:0] host_rdata_r;
    always @(posedge clk) host_rdata_r <= r_rd_data;
    assign host_rdata = host_rdata_r;

    assign error = mem_conflict | wr_overflow;
endmodule
