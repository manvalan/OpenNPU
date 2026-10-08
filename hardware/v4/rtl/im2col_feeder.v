// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- im2col feeder for the first layer of a network: 3x3 convolution,
// pad 1, stride 1 or 2, on a raw image of IW x IH pixels and C = 1..4
// channels, so the image can be sent to the FPGA as is and the first
// layer still runs as a pointwise-only pass on the array (9*C values
// -> ng beats of 16, padded with zeros).
//
// The image size, channels and stride are run-time configuration (pass
// descriptor, rtl/v4_core.v), sampled on `start`:
//   cfg_iw, cfg_ih  image size (1..255)
//   cfg_c           channels per pixel, 1..4
//   cfg_s2          stride 2 (else 1)
//   cfg_rw          image words per row = ceil(IW*C/16), 1..31
//   cfg_ow, cfg_oh  output size = ceil(IW/s), ceil(IH/s)
//   cfg_ng          beats per output position = ceil(9*C/16), 2..3
//                   (C = 1 gives 9 values: still 2 beats, the second zero,
//                   because the array needs ng >= 2)
//
// Image in the feature-map memory: row r (0..IH-1) at base + r*RW words,
// bytes contiguous (pixel-major, C channels), bytes IW*C..16*RW-1 of
// every row ZERO (they are the right padding when IW*C is not a
// multiple of 16).
// Output: for every output position (i, j), raster order, ng 128-bit
// beats = bytes 16b..16b+15 of the vector
//   v[kr*3C + kc*C + ch] = img(s*i-1+kr, s*j-1+kc, ch)   (0 outside),
//   v[9C..16*ng-1] = 0
// -- the engine's pw-only beat order. For C = 3, stride 2 this is the
// MobileFaceNet conv1 vector (27 values + 5 zeros, 2 beats).
//
// Structure (version 2: version 1 kept whole rows in byte shift
// registers, +17k LUT in the core synthesis):
//   * image rows go into a 5-slot row RAM (distributed), row r in slot
//     r % 5, one word later: slot word 0 = zeros (holds the left
//     padding), slot word k = image word k-1 (k = 1..RW), slot word RW+1
//     (mod 32) = zeros (right padding). Word 0 is never written with
//     anything but zeros (RAM initialised to 0). A window starting at
//     image byte b sits at slot byte b + 16;
//   * the loader runs ahead of the emitter (rows up to s*i+3 while
//     output row i is emitted), so row loads overlap the computation;
//   * position j's 3C-byte window of a row starts at image byte
//     s*C*j - C, slot byte p = 16 - C + s*C*j: two adjacent words are
//     read (3 rows x 2 read ports; the second wraps to the zero word 0
//     when p is in word 31) and byte-shifted by (p mod 16) -- one
//     16-way byte shifter per row.
// Limits: (IW*C) <= 496 bytes (RW <= 31); C <= 4.
// Memory read port: latency 4, like fmap_feeder.v.
// ============================================================
module im2col_feeder #(
    parameter AW = 15
)(
    input  wire clk,
    input  wire rst,
    input  wire start,
    input  wire [AW-1:0] cfg_base,
    input  wire [7:0]    cfg_iw,
    input  wire [7:0]    cfg_ih,
    input  wire [2:0]    cfg_c,
    input  wire          cfg_s2,
    input  wire [4:0]    cfg_rw,
    input  wire [7:0]    cfg_ow,
    input  wire [7:0]    cfg_oh,
    input  wire [1:0]    cfg_ng,

    output reg           rd_en,
    output reg  [AW-1:0] rd_addr,
    input  wire [127:0]  rd_data,

    output wire          out_valid,
    input  wire          out_ready,
    output wire [127:0]  out_data
);
    localparam LAT = 4;
    localparam NS  = 5;                    // row slots

    // configuration, sampled on start
    reg [7:0]  ih, ow, oh;
    reg [2:0]  ch;
    reg        s2;
    reg [4:0]  rw;
    reg [1:0]  ngl;           // last beat = ng - 1
    reg [3:0]  pstep;         // padded bytes per output column = s*C
    // minus/plus one precomputed (the first generic-board P&R had
    // ow -> compare -> pbr at -1.02 ns and s2 -> lim -> lbase at -0.86)
    reg [7:0]  ow_m1, oh_m1;
    reg [4:0]  rw_m1, rw_p1;
    always @(posedge clk)
        if (start) begin
            ih <= cfg_ih; ow <= cfg_ow; oh <= cfg_oh; ch <= cfg_c; s2 <= cfg_s2; rw <= cfg_rw;
            ow_m1 <= cfg_ow - 8'd1; oh_m1 <= cfg_oh - 8'd1;
            rw_m1 <= cfg_rw - 5'd1; rw_p1 <= cfg_rw + 5'd1;
            ngl <= cfg_ng - 2'd1;
            pstep <= cfg_s2 ? {cfg_c, 1'b0} : {1'b0, cfg_c};
        end

    // row RAM: slot s, slot word k at {s, k}
    (* ram_style = "distributed" *) reg [127:0] rows [0:NS*32-1];
    integer ri;
    initial for (ri = 0; ri < NS*32; ri = ri + 1) rows[ri] = 128'd0;

    // ---------------- loader ----------------
    reg        running;
    reg [7:0]  oi;            // output row being emitted
    reg [7:0]  lr;            // next image row to request
    reg [4:0]  lw;            // next word of that row
    reg [2:0]  lslot;         // lr % NS
    reg [AW-1:0] lbase;       // memory address of row lr
    reg        gap;           // one idle request cycle after each row
    reg [4:0]  req_w;
    reg [2:0]  req_s;
    reg [LAT-1:0] pv;
    reg [4:0]  pw_ [1:LAT];
    reg [2:0]  ps_ [1:LAT];
    reg [7:0]  rows_done;
    reg        tail_pend;
    (* max_fanout = 16 *) reg rw_en;
    reg        row_fin;
    // write port of the 6-read-port row RAM: every bit fans out to all
    // the replicas (second board P&R: rw_a -> rows at -1.4 ns)
    (* max_fanout = 16 *) reg [7:0]  rw_a;
    (* max_fanout = 8 *) reg [127:0] rw_d;
    reg [2:0]  tail_s;
    // rows s*oi-1 .. s*oi+3 may be in the 5 slots at once
    // lim registered: one cycle late is safe, it only grows within a
    // layer (a smaller old value just delays a load by a cycle) and it
    // restarts from 3 = lim(oi = 0) on start
    wire [8:0] lim = (s2 ? {oi, 1'b0} : {1'b0, oi}) + 9'd3;
    reg  [8:0] lim_r;
    always @(posedge clk) lim_r <= start ? 9'd3 : lim;
    wire can_load = running && !gap && (lr < ih) && ({1'b0, lr} <= lim_r);

    integer k;
    always @(posedge clk) begin
        rd_en <= 1'b0;
        if (rst || start) begin
            pv <= 0; lr <= 8'd0; lw <= 5'd0; lslot <= 3'd0; gap <= 1'b0;
            lbase <= cfg_base;
            rows_done <= 8'd0; tail_pend <= 1'b0; rw_en <= 1'b0; row_fin <= 1'b0;
        end else begin
            pv <= {pv[LAT-2:0], rd_en};
            pw_[1] <= req_w; ps_[1] <= req_s;
            for (k = 2; k <= LAT; k = k + 1) begin pw_[k] <= pw_[k-1]; ps_[k] <= ps_[k-1]; end
            gap <= 1'b0;
            if (can_load) begin
                rd_en   <= 1'b1;
                rd_addr <= lbase + lw;
                req_w   <= lw;
                req_s   <= lslot;
                if (lw == rw_m1) begin
                    lw <= 5'd0; lr <= lr + 8'd1; gap <= 1'b1;
                    lbase <= lbase + rw;
                    lslot <= (lslot == NS - 1) ? 3'd0 : lslot + 3'd1;
                end else lw <= lw + 5'd1;
            end
            // image word k lands in slot word k+1
            // (row RAM write itself registered once more: fifth P&R)
            rw_en <= 1'b0;
            row_fin <= 1'b0;
            if (pv[LAT-1]) begin
                rw_en <= 1'b1;
                rw_a  <= {ps_[LAT], pw_[LAT] + 5'd1};
                rw_d  <= rd_data;
                if (pw_[LAT] == rw_m1) begin
                    tail_pend <= 1'b1; tail_s <= ps_[LAT];
                end
            end else if (tail_pend) begin
                // the request gap guarantees this free write cycle:
                // zeros after the row (slot word RW+1, word 0 if RW = 31)
                rw_en <= 1'b1; rw_a <= {tail_s, rw_p1}; rw_d <= 128'd0;
                tail_pend <= 1'b0;
                row_fin <= 1'b1;
            end
            if (rw_en) rows[rw_a] <= rw_d;
            // a row counts as done once its tail word is really in the RAM
            if (row_fin) rows_done <= rows_done + 8'd1;
        end
    end

    // ---------------- emitter ----------------
    // F: read the 3 x 2 words of position (oi, oj) into registers
    //    (addresses from registers: slots and byte offset kept
    //    incrementally -- the first synthesis had oi -> %5 / *6 -> RAM ->
    //    shifter in one cycle at -8.2 ns)
    // V: byte-shift into the 9C-byte vector
    // E: ng output beats
    reg  [7:0] oj;
    (* max_fanout = 16 *) reg [2:0] s0r, s1r, s2r;   // slots of rows s*oi-1, s*oi, s*oi+1
    reg  [8:0] pbr;                 // 16 - C + s*C*oj (slot byte of the window)
    reg  [8:0] need;                // rows needed for this output row: s*oi+2
    reg  [8:0] need_c;              // min(need, IH): rows that exist
    reg        bot;                 // row s*oi+1 is the bottom padding (need > IH)
    reg        f_valid, f_zero, f_zbot;
    reg  [3:0] f_sh;
    reg [255:0] f_d0, f_d1, f_d2;
    reg        have, last_f;
    reg  [1:0] beat;
    reg [383:0] vec;

    wire [4:0] w0 = pbr[8:4];
    wire [4:0] w1 = pbr[8:4] + 5'd1;
    // registered (the fourth board P&R had rows_done -> compare -> CE of
    // the 768 f_d flops at -0.235 ns). One cycle stale is safe because
    // rows_done only grows within a layer; it is forced low on start and
    // for the cycle after `need` grows, so it never uses an old `need`.
    reg  rows_ready;
    reg  fetching;                  // positions left to fetch
    wire do_f = running && fetching && !f_valid && rows_ready;
    always @(posedge clk)
        if (rst || start || (do_f && oj == ow_m1)) rows_ready <= 1'b0;
        else                                            rows_ready <= ({1'b0, rows_done} >= need_c);

    function [2:0] plus1(input [2:0] x);
        plus1 = (x == 3'd4) ? 3'd0 : x + 3'd1;          // (x + 1) mod 5
    endfunction
    function [2:0] plus2(input [2:0] x);
        plus2 = (x >= 3'd3) ? x - 3'd3 : x + 3'd2;      // (x + 2) mod 5
    endfunction

    wire [255:0] x0s = f_d0 >> {f_sh, 3'b000};
    wire [255:0] x1s = f_d1 >> {f_sh, 3'b000};
    wire [255:0] x2s = f_d2 >> {f_sh, 3'b000};
    wire [95:0]  r0 = f_zero ? 96'd0 : x0s[95:0];
    wire [95:0]  r1 = x1s[95:0];
    wire [95:0]  r2 = f_zbot ? 96'd0 : x2s[95:0];
    // the three 3C-byte row windows, packed
    reg  [287:0] packed_v;
    always @* begin
        case (ch)
            3'd1:    packed_v = {216'd0, r2[23:0], r1[23:0], r0[23:0]};
            3'd2:    packed_v = {144'd0, r2[47:0], r1[47:0], r0[47:0]};
            3'd3:    packed_v = {72'd0,  r2[71:0], r1[71:0], r0[71:0]};
            default: packed_v = {        r2[95:0], r1[95:0], r0[95:0]};
        endcase
    end

    wire [8:0] need_n = need + (s2 ? 9'd2 : 9'd1);

    always @(posedge clk) begin
        if (rst) begin
            running <= 1'b0; have <= 1'b0; f_valid <= 1'b0; fetching <= 1'b0;
        end else if (start) begin
            running <= 1'b1; fetching <= 1'b1; have <= 1'b0; f_valid <= 1'b0; beat <= 2'd0;
            oi <= 8'd0; oj <= 8'd0; pbr <= 9'd16 - {6'd0, cfg_c}; need <= 9'd2;
            need_c <= (cfg_ih < 8'd2) ? {1'b0, cfg_ih} : 9'd2;
            bot <= (cfg_ih < 8'd2);
            s0r <= 3'd4; s1r <= 3'd0; s2r <= 3'd1;
            last_f <= 1'b0;
        end else if (running) begin
            // F
            if (do_f) begin
                f_d0 <= {rows[{s0r, w1}], rows[{s0r, w0}]};
                f_d1 <= {rows[{s1r, w1}], rows[{s1r, w0}]};
                f_d2 <= {rows[{s2r, w1}], rows[{s2r, w0}]};
                f_sh <= pbr[3:0];
                f_zero <= (oi == 8'd0);
                f_zbot <= bot;
                f_valid <= 1'b1;
                if (oj == ow_m1) begin
                    oj <= 8'd0; pbr <= 9'd16 - {6'd0, ch};
                    if (oi == oh_m1) fetching <= 1'b0;
                    oi <= oi + 8'd1;
                    need <= need_n;
                    need_c <= (need_n > {1'b0, ih}) ? {1'b0, ih} : need_n;
                    bot <= (need_n > {1'b0, ih});
                    if (s2) begin s0r <= plus2(s0r); s1r <= plus2(s1r); s2r <= plus2(s2r); end
                    else    begin s0r <= plus1(s0r); s1r <= plus1(s1r); s2r <= plus1(s2r); end
                end else begin
                    oj <= oj + 8'd1; pbr <= pbr + pstep;
                end
            end
            // V
            if (f_valid && !have) begin
                vec <= {96'd0, packed_v};
                have <= 1'b1; beat <= 2'd0;
                if (!do_f) f_valid <= 1'b0;
                last_f <= !fetching && !do_f;
            end
            // E
            if (have && out_ready) begin
                if (beat == ngl) begin
                    have <= 1'b0;
                    beat <= 2'd0;
                    if (last_f) running <= 1'b0;
                end else
                    beat <= beat + 2'd1;
            end
        end
    end

    assign out_valid = have;
    assign out_data  = (beat == 2'd0) ? vec[127:0] : (beat == 2'd1) ? vec[255:128] : vec[383:256];
endmodule
