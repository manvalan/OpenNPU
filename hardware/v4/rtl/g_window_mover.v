// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- A.1 architecture, fifth building
// block: G, the incremental sliding-window mover, extended for
// Winograd F(2x2,3x3) tiling (4 rows resident, slide by 2 rows;
// 4x4 tiles extracted sliding by 2 columns) -- see this session's
// own brainstorm log for the real derivation (row-buffer depth/
// slide-quantum change from direct-conv's K=3/S=1 to Winograd's
// 4/2, plus a NEW 2D column-tile extractor on top of the row
// buffer that direct-conv's row-at-a-time model never needed).
//
// Real, deliberate scope limit for THIS module: the memory source
// is a SIMPLE, ZERO-LATENCY combinational read port (mem_addr out,
// mem_rdata in, same-cycle) -- standing in for a future real DDR3
// fetch. This isolates and proves the row-buffer/tile-extraction
// CONTROL logic correctness first; coping with real, variable DDR3
// latency/backpressure is a real, separate, deliberately deferred
// concern (matches this whole project's "one variable at a time"
// discipline, and this session's own G/F/mover discussion that
// explicitly separated "does the addressing logic work" from "how
// fast does memory respond").
//
// Feature map layout convention (this module's own, documented
// here since nothing upstream fixes it yet): row-major, channel-
// interleaved -- flat index(row,col,ch) = row*(W*CIN) + col*CIN + ch.
// Valid (unpadded) convolution only -- output tile top-left
// positions range row=0,2,4,...,H-4 and col=0,2,4,...,W-4 (W,H
// must both be even and >=4, not enforced in hardware, a real
// caller responsibility for this first version).
// ============================================================
module g_window_mover #(
    parameter W    = 8,
    parameter H    = 8,
    parameter CIN  = 2
)(
    input  wire clk,
    input  wire rst,
    input  wire start,

    // ---- simple synchronous(same-cycle) memory read port ----
    output reg  [$clog2(W*H*CIN)-1:0] mem_addr,
    input  wire signed [7:0]          mem_rdata,

    // ---- tile output, one 4x4xCIN tile per `tile_valid` pulse ----
    output reg                        tile_valid,
    output reg  [7:0]                 out_row,   // top-left row of this output tile (0,2,4,...)
    output reg  [7:0]                 out_col,   // top-left col of this output tile (0,2,4,...)
    output reg  signed [8*16*CIN-1:0] d_flat,     // matches winograd_f23_neuron's own d_flat layout

    output reg                        busy,
    output reg                        done       // one-cycle pulse when the whole feature map is exhausted
);
    localparam ROWBYTES = W*CIN;
    localparam ADDRW    = $clog2(W*H*CIN);
    localparam FILLW    = $clog2(4*ROWBYTES);
    localparam REFILLW  = $clog2(2*ROWBYTES);

    localparam S_IDLE   = 3'd0,
               S_FILL    = 3'd1,
               S_EMIT    = 3'd2,
               S_SHIFT   = 3'd3,
               S_REFILL  = 3'd4,
               S_DONE    = 3'd5;

    reg [2:0] state;
    reg [FILLW-1:0]   fill_cnt;
    reg [REFILLW-1:0] refill_cnt;
    reg [7:0] cur_row_top;
    reg [7:0] cur_col;

    reg signed [7:0] rowbuf [0:3][0:ROWBYTES-1];
    integer shift_i;

    // ---- address generation (combinational, same-cycle read) ----
    always @(*) begin
        case (state)
            S_FILL:   mem_addr = fill_cnt; // rows 0..3 are one contiguous block starting at addr 0
            S_REFILL: mem_addr = (cur_row_top + 2) * ROWBYTES + refill_cnt;
            default:  mem_addr = {ADDRW{1'b0}};
        endcase
    end

    // ---- tile extraction: combinational, direct from the resident
    // 4-row buffer at the current cur_col, packed exactly the way
    // winograd_f23_neuron/winograd_f23_multichan expect (group ci
    // occupies bits [ci*128 +: 128], value index v at
    // [ci*128 + v*8 +: 8], row-major 4x4 within a group). ----
    integer tr, tc, tch;
    reg signed [8*16*CIN-1:0] tile_comb;
    always @(*) begin
        tile_comb = {(8*16*CIN){1'b0}};
        for (tch = 0; tch < CIN; tch = tch + 1)
            for (tr = 0; tr < 4; tr = tr + 1)
                for (tc = 0; tc < 4; tc = tc + 1)
                    tile_comb[tch*128 + (tr*4+tc)*8 +: 8] = rowbuf[tr][(cur_col+tc)*CIN + tch];
    end

    always @(posedge clk) begin
        if (rst) begin
            state      <= S_IDLE;
            tile_valid <= 1'b0;
            busy       <= 1'b0;
            done       <= 1'b0;
            fill_cnt   <= {FILLW{1'b0}};
            refill_cnt <= {REFILLW{1'b0}};
            cur_row_top<= 8'd0;
            cur_col    <= 8'd0;
        end else begin
            tile_valid <= 1'b0;
            done       <= 1'b0;

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
                    if (fill_cnt == (4*ROWBYTES-1)) begin
                        cur_col <= 8'd0;
                        state   <= S_EMIT;
                    end else begin
                        fill_cnt <= fill_cnt + 1'b1;
                    end
                end

                S_EMIT: begin
                    tile_valid <= 1'b1;
                    out_row    <= cur_row_top;
                    out_col    <= cur_col;
                    d_flat     <= tile_comb;

                    if (cur_col == (W-4)) begin
                        // last column of this band -- decide whether
                        // another band exists.
                        if ((cur_row_top + 2) <= (H-4)) begin
                            state <= S_SHIFT;
                        end else begin
                            state <= S_DONE;
                        end
                    end else begin
                        cur_col <= cur_col + 8'd2;
                    end
                end

                S_SHIFT: begin
                    // evict the oldest 2 rows, keep the newest 2 --
                    // real, explicit register move (correctness-first,
                    // a rotating-index optimization is real, disclosed
                    // later work, not done here). Explicit element-wise
                    // for-loop, not a whole-unpacked-array assignment,
                    // for portability (plain Verilog-2001 style, matches
                    // the rest of this project, and not all synthesis
                    // flows accept the latter).
                    for (shift_i = 0; shift_i < ROWBYTES; shift_i = shift_i + 1) begin
                        rowbuf[0][shift_i] <= rowbuf[2][shift_i];
                        rowbuf[1][shift_i] <= rowbuf[3][shift_i];
                    end
                    cur_row_top <= cur_row_top + 8'd2;
                    refill_cnt  <= {REFILLW{1'b0}};
                    state       <= S_REFILL;
                end

                S_REFILL: begin
                    rowbuf[2 + refill_cnt / ROWBYTES][refill_cnt % ROWBYTES] <= mem_rdata;
                    if (refill_cnt == (2*ROWBYTES-1)) begin
                        cur_col <= 8'd0;
                        state   <= S_EMIT;
                    end else begin
                        refill_cnt <= refill_cnt + 1'b1;
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
