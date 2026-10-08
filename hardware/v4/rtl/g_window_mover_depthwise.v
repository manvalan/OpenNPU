// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- "G-esteso": g_window_mover.v's own
// row-buffer/sliding-window mechanism, extended to compute the
// depthwise MAC (depthwise_mac3x3.v, one instance per channel)
// directly as it streams, instead of handing a raw tile to a
// downstream stage. See hardware/v4/docs/DEPTHWISE_SEPARABLE_
// PIPELINE.md for the real math and the real per-channel cost
// measurement (0 DSP48E1, 696 LUT, isolated).
//
// Real, deliberate simplification versus g_window_mover.v's own
// Winograd-tiling form: plain K=3/stride=1 depthwise needs only 3
// resident rows (not 4) and slides by 1 row/1 col (not 2) -- no 2D
// tile extractor needed, one window position emits one CIN-wide
// vector of already-depthwise-filtered scalars, not a raw tile.
//
// Same real scope limit as g_window_mover.v: a simple, zero-
// latency combinational memory read port stands in for real DDR3 --
// proving the row-buffer/depthwise CONTROL logic correctness first.
//
// Feature map layout: same convention as g_window_mover.v (row-
// major, channel-interleaved, index(row,col,ch)=row*(W*CIN)+col*CIN+ch).
// Valid (unpadded) 3x3 convolution only -- output positions range
// row=0..H-3, col=0..W-3 (Hout=H-2, Wout=W-2).
// ============================================================
module g_window_mover_depthwise #(
    parameter W   = 8,
    parameter H   = 8,
    parameter CIN = 4
)(
    input  wire clk,
    input  wire rst,
    input  wire start,

    output reg  [$clog2(W*H*CIN)-1:0] mem_addr,
    input  wire signed [7:0]          mem_rdata,

    // 9 real weights per channel (row-major kr*3+kc), flattened:
    // channel c's own weights at [c*72 +: 72], value kr*3+kc at
    // [c*72 + (kr*3+kc)*8 +: 8].
    input  wire signed [72*CIN-1:0] wd_flat,

    output reg                       out_valid,
    output reg  [7:0]                out_row,
    output reg  [7:0]                out_col,
    output reg  signed [20*CIN-1:0]  dw_flat,   // CIN depthwise results, [c*20 +: 20]

    output reg busy,
    output reg done
);
    localparam ROWBYTES = W*CIN;
    localparam ADDRW    = $clog2(W*H*CIN);
    localparam FILLW    = $clog2(3*ROWBYTES);

    localparam S_IDLE  = 3'd0,
               S_FILL   = 3'd1,
               S_EMIT   = 3'd2,
               S_SHIFT  = 3'd3,
               S_REFILL = 3'd4,
               S_DONE   = 3'd5;

    reg [2:0] state;
    reg [FILLW-1:0] fill_cnt;
    reg [7:0] cur_row_top;
    reg [7:0] cur_col;

    reg signed [7:0] rowbuf [0:2][0:ROWBYTES-1];
    integer shift_i;

    always @(*) begin
        case (state)
            S_FILL:   mem_addr = fill_cnt; // rows 0..2, one contiguous block from addr 0
            S_REFILL: mem_addr = (cur_row_top + 2) * ROWBYTES + fill_cnt;
            default:  mem_addr = {ADDRW{1'b0}};
        endcase
    end

    // ---- per-channel 3x3 window extraction: runtime-indexed (cur_col
    // is a register) array reads done in a plain procedural always
    // block first -- same pattern already proven safe in g_window_
    // mover.v's own tile_comb extraction. A generate block driving a
    // module port directly off a runtime-computed array index (as an
    // earlier version of this file did) crashed Icarus with an
    // internal assertion -- worked around, not a real Verilog
    // semantic issue, but real tool fragility worth avoiding either
    // way. ----
    reg signed [8*CIN-1:0] win0, win1, win2, win3, win4, win5, win6, win7, win8;
    integer wch;
    always @(*) begin
        for (wch = 0; wch < CIN; wch = wch + 1) begin
            win0[wch*8 +: 8] = rowbuf[0][(cur_col+0)*CIN+wch];
            win1[wch*8 +: 8] = rowbuf[0][(cur_col+1)*CIN+wch];
            win2[wch*8 +: 8] = rowbuf[0][(cur_col+2)*CIN+wch];
            win3[wch*8 +: 8] = rowbuf[1][(cur_col+0)*CIN+wch];
            win4[wch*8 +: 8] = rowbuf[1][(cur_col+1)*CIN+wch];
            win5[wch*8 +: 8] = rowbuf[1][(cur_col+2)*CIN+wch];
            win6[wch*8 +: 8] = rowbuf[2][(cur_col+0)*CIN+wch];
            win7[wch*8 +: 8] = rowbuf[2][(cur_col+1)*CIN+wch];
            win8[wch*8 +: 8] = rowbuf[2][(cur_col+2)*CIN+wch];
        end
    end

    // ---- combinational depthwise result, at the CURRENT (pre-edge)
    // cur_col/rowbuf -- must be REGISTERED into dw_flat on the same
    // edge as out_row/out_col (see S_EMIT below), not left as a bare
    // wire: a bare wire would reflect NEXT cycle's window position by
    // the time a caller samples it post-edge, silently misaligned
    // with out_row/out_col -- a REAL bug this module's own testbench
    // caught (the exact one-cycle-misalignment class already found
    // by inspection once before, in winograd_conv_engine.v; missed
    // here until the test ran). ----
    wire signed [20*CIN-1:0] dw_comb;
    genvar gc;
    generate
        for (gc = 0; gc < CIN; gc = gc + 1) begin : GEN_CH
            depthwise_mac3x3 u_dw (
                .d0(win0[gc*8+:8]), .d1(win1[gc*8+:8]), .d2(win2[gc*8+:8]),
                .d3(win3[gc*8+:8]), .d4(win4[gc*8+:8]), .d5(win5[gc*8+:8]),
                .d6(win6[gc*8+:8]), .d7(win7[gc*8+:8]), .d8(win8[gc*8+:8]),

                .w0(wd_flat[gc*72+0*8 +: 8]), .w1(wd_flat[gc*72+1*8 +: 8]), .w2(wd_flat[gc*72+2*8 +: 8]),
                .w3(wd_flat[gc*72+3*8 +: 8]), .w4(wd_flat[gc*72+4*8 +: 8]), .w5(wd_flat[gc*72+5*8 +: 8]),
                .w6(wd_flat[gc*72+6*8 +: 8]), .w7(wd_flat[gc*72+7*8 +: 8]), .w8(wd_flat[gc*72+8*8 +: 8]),

                .y(dw_comb[gc*20 +: 20])
            );
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            out_valid   <= 1'b0;
            busy        <= 1'b0;
            done        <= 1'b0;
            fill_cnt    <= {FILLW{1'b0}};
            cur_row_top <= 8'd0;
            cur_col     <= 8'd0;
        end else begin
            out_valid <= 1'b0;
            done      <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        busy        <= 1'b1;
                        cur_row_top <= 8'd0;
                        fill_cnt    <= {FILLW{1'b0}};
                        state       <= S_FILL;
                    end
                end

                S_FILL: begin
                    rowbuf[fill_cnt / ROWBYTES][fill_cnt % ROWBYTES] <= mem_rdata;
                    if (fill_cnt == (3*ROWBYTES-1)) begin
                        cur_col <= 8'd0;
                        state   <= S_EMIT;
                    end else begin
                        fill_cnt <= fill_cnt + 1'b1;
                    end
                end

                S_EMIT: begin
                    out_valid <= 1'b1;
                    out_row   <= cur_row_top;
                    out_col   <= cur_col;
                    dw_flat   <= dw_comb;

                    if (cur_col == (W-3)) begin
                        if ((cur_row_top + 1) <= (H-3)) begin
                            state <= S_SHIFT;
                        end else begin
                            state <= S_DONE;
                        end
                    end else begin
                        cur_col <= cur_col + 8'd1;
                    end
                end

                S_SHIFT: begin
                    for (shift_i = 0; shift_i < ROWBYTES; shift_i = shift_i + 1) begin
                        rowbuf[0][shift_i] <= rowbuf[1][shift_i];
                        rowbuf[1][shift_i] <= rowbuf[2][shift_i];
                    end
                    cur_row_top <= cur_row_top + 8'd1;
                    fill_cnt    <= {FILLW{1'b0}};
                    state       <= S_REFILL;
                end

                S_REFILL: begin
                    rowbuf[2][fill_cnt] <= mem_rdata;
                    if (fill_cnt == (ROWBYTES-1)) begin
                        cur_col <= 8'd0;
                        state   <= S_EMIT;
                    end else begin
                        fill_cnt <= fill_cnt + 1'b1;
                    end
                end

                S_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
