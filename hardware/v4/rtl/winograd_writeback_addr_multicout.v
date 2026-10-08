// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- A.1 architecture, Cout extension:
// output write-back addressing for COUT output channels, extending
// winograd_writeback_addr.v's own single-channel version.
//
// Output feature map layout convention (DELIBERATELY matches the
// INPUT layout g_window_mover.v already uses -- row-major, channel-
// interleaved: index(row,col,ch) = row*(OUT_W*COUT) + col*COUT + ch
// -- so a future multi-layer chain can feed one layer's output
// straight into the next layer's input memory with NO reshuffle).
//
// Bus packing convention (flattened, matches this project's own
// established style): y_flat holds COUT groups of 4 signed INT8
// values (channel c's own y0..y3 at bits [c*32 +: 32], each 8-bit
// value at [c*32 + p*8 +: 8] for tile position p=0..3). Outputs
// (we/addr/data) are flattened the same way, 4*COUT entries total
// (position p, channel c at flat index p*COUT+c).
// ============================================================
module winograd_writeback_addr_multicout #(
    parameter W    = 8,
    parameter H    = 8,
    parameter COUT = 4
)(
    input  wire                in_valid,
    input  wire [7:0]          in_row,
    input  wire [7:0]          in_col,
    input  wire signed [8*4*COUT-1:0] y_flat,

    output wire [4*COUT-1:0]                        we_flat,
    output wire [4*COUT*$clog2((W-2)*(H-2)*COUT)-1:0] addr_flat,
    output wire signed [8*4*COUT-1:0]                wdata_flat
);
    localparam OUT_W  = W-2;
    localparam OUT_H  = H-2;
    localparam ADDRW  = $clog2(OUT_W*OUT_H*COUT);

    genvar p, c;
    generate
        for (p = 0; p < 4; p = p + 1) begin : GEN_POS
            for (c = 0; c < COUT; c = c + 1) begin : GEN_CH
                localparam integer FLAT_IDX = p*COUT + c;
                wire [7:0] dr = (p < 2) ? 8'd0 : 8'd1;
                wire [7:0] dc = (p % 2 == 0) ? 8'd0 : 8'd1;

                assign we_flat[FLAT_IDX] = in_valid;
                assign addr_flat[FLAT_IDX*ADDRW +: ADDRW] =
                    (in_row+dr) * (OUT_W*COUT) + (in_col+dc) * COUT + c;
                assign wdata_flat[FLAT_IDX*8 +: 8] = y_flat[c*32 + p*8 +: 8];
            end
        end
    endgenerate
endmodule
