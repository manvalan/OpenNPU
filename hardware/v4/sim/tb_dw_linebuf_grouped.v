// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- isolated correctness test for dw_linebuf_grouped.v (BRAM line
// buffer depthwise over NG channel groups, forked from
// tb_dw_linebuf_stream.v). Independent golden model: direct 3x3 depthwise
// conv per channel over the padded frame, stride 1 or 2. Checks every
// output value, the output ORDER/coordinates, full coverage, out_last,
// under random input bubbles (in_valid low) and random output
// back-pressure (out_ready low). Several frame sizes and both strides
// run back-to-back on the same instance (runtime cfg).
// ============================================================
module tb;
    localparam LANES = `ifdef TB_LANES `TB_LANES `else 3 `endif;
    localparam MAXW  = 20;
    localparam MAXNG = `ifdef TB_MAXNG `TB_MAXNG `else 4 `endif;
    localparam HALF  = `ifdef TB_HALF 1 `else 0 `endif;   // LANES/2 MACs used twice

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst, start;

    reg  [7:0] cfg_w, cfg_h;
    reg        cfg_stride2;
    reg        in_valid;
    wire       in_ready;
    reg  signed [8*LANES-1:0]  in_pix;
    reg  signed [72*LANES-1:0] wd_flat;
    wire       out_valid;
    reg        out_ready;
    wire [7:0] out_row, out_col;
    wire       out_last;
    wire signed [20*LANES-1:0] dw_flat;

    reg  [5:0] cfg_ng;
    wire [5:0] wd_g, out_g;
    dw_linebuf_grouped #(.LANES(LANES), .MAXW(MAXW), .MAXNG(MAXNG), .HALF(HALF)) dut (
        .clk(clk), .rst(rst), .start(start),
        .cfg_w(cfg_w), .cfg_h(cfg_h), .cfg_ng(cfg_ng), .cfg_stride2(cfg_stride2),
        .in_valid(in_valid), .in_ready(in_ready), .in_pix(in_pix),
        .wd_g(wd_g), .wd_flat(wd_flat),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_row(out_row), .out_col(out_col), .out_g(out_g), .out_last(out_last), .dw_flat(dw_flat)
    );

    localparam CMAX = LANES*MAXNG;
    reg signed [7:0] fmap [0:MAXW*MAXW*CMAX-1];
    reg signed [7:0] wd [0:CMAX-1][0:8];
    integer NG, C;
    // weight lookup by the group the DUT asks for (combinational, like a LUTRAM)
    integer wl, wk;
    always @(*) begin
        for (wl = 0; wl < LANES; wl = wl + 1)
            for (wk = 0; wk < 9; wk = wk + 1)
                wd_flat[wl*72 + wk*8 +: 8] = wd[wd_g*LANES + wl][wk];
    end

    integer W, H, S, OUT_W, OUT_H;
    integer c, i;

    function automatic signed [19:0] golden(input integer orow, input integer ocol, input integer ch);
        integer kr, kc, rr, cc;
        reg signed [19:0] acc;
        begin
            acc = 0;
            for (kr = 0; kr < 3; kr = kr + 1)
                for (kc = 0; kc < 3; kc = kc + 1) begin
                    rr = orow*S + kr; cc = ocol*S + kc;
                    acc = acc + fmap[(rr*W + cc)*C + ch] * wd[ch][kr*3+kc];
                end
            golden = acc;
        end
    endfunction

    integer errors, checks, got, exp_row, exp_col, exp_g, lasts;
    integer bubble_pct, stall_pct;

    // ---- output checker (samples on posedge when handshake completes) ----
    reg signed [19:0] g, v;
    integer ck;
    always @(posedge clk) begin
        if (!rst && out_valid && out_ready) begin
            checks = checks + 1;
            for (ck = 0; ck < LANES; ck = ck + 1) begin
                v = dw_flat[ck*20 +: 20];
                g = golden(out_row, out_col, exp_g*LANES + ck);
                if (v !== g) begin
                    errors = errors + 1;
                    if (errors < 20) $display("FAIL W=%0d H=%0d S=%0d pos(%0d,%0d) ch=%0d got=%0d exp=%0d",
                                               W, H, S, out_row, out_col, ck, v, g);
                end
            end
            if (out_row !== exp_row || out_col !== exp_col || out_g !== exp_g) begin
                errors = errors + 1;
                if (errors < 20) $display("FAIL ORDER got(%0d,%0d,g%0d) exp(%0d,%0d,g%0d)", out_row, out_col, out_g, exp_row, exp_col, exp_g);
            end
            got = got + 1;
            if (out_last) begin
                lasts = lasts + 1;
                if (got != OUT_W*OUT_H*NG) begin
                    errors = errors + 1;
                    $display("FAIL out_last at #%0d, expected at #%0d", got, OUT_W*OUT_H*NG);
                end
            end
            if (exp_g == NG-1) begin
                exp_g = 0;
                if (exp_col == OUT_W-1) begin exp_col = 0; exp_row = exp_row + 1; end
                else exp_col = exp_col + 1;
            end else exp_g = exp_g + 1;
        end
    end

    integer p_acc;
    always @(posedge clk) if (!rst && in_valid && in_ready) p_acc = p_acc + 1;

    // ---- random back-pressure, driven on negedge (project rule) ----
    always @(negedge clk) out_ready <= (($random & 127) >= stall_pct);

    integer p, wdg, frame;
    integer sizes_w [0:5];
    integer sizes_h [0:5];
    integer cycles_frame;
    initial begin
        errors = 0; checks = 0;
        sizes_w[0]=3;  sizes_h[0]=3;
        sizes_w[1]=10; sizes_h[1]=9;
        sizes_w[2]=20; sizes_h[2]=12;
        sizes_w[3]=6;  sizes_h[3]=17;
        sizes_w[4]=18; sizes_h[4]=18;
        sizes_w[5]=11; sizes_h[5]=4;
        rst = 1; start = 0; in_valid = 0; in_pix = 0; stall_pct = 0;
        cfg_w = 3; cfg_h = 3; cfg_stride2 = 0;
        repeat (4) @(posedge clk);
        @(negedge clk) rst = 0;

        for (frame = 0; frame < 48; frame = frame + 1) begin
            W = sizes_w[frame % 6]; H = sizes_h[frame % 6];
            S = ((frame / 6) % 2) ? 2 : 1;
            // bubble/stall mix: none, light, heavy, none-in-heavy-out...
            case ((frame / 12) % 4)
                0: begin bubble_pct = 0;  stall_pct = 0;  end
                1: begin bubble_pct = 30; stall_pct = 0;  end
                2: begin bubble_pct = 0;  stall_pct = 50; end
                3: begin bubble_pct = 60; stall_pct = 70; end
            endcase
            NG = 1 + (frame % MAXNG);
            C  = NG*LANES;
            OUT_W = (W - 3) / S + 1;
            OUT_H = (H - 3) / S + 1;
            for (i = 0; i < W*H*C; i = i + 1) fmap[i] = $random;
            for (c = 0; c < C; c = c + 1) for (i = 0; i < 9; i = i + 1) wd[c][i] = $random;
            // adversarial extremes on one frame per size
            if (frame % 7 == 3) begin
                for (i = 0; i < W*H*C; i = i + 1) fmap[i] = -128;
                for (c = 0; c < C; c = c + 1) for (i = 0; i < 9; i = i + 1) wd[c][i] = -128;
            end

            @(negedge clk);
            cfg_w <= W; cfg_h <= H; cfg_ng <= NG; cfg_stride2 <= (S == 2);
            start <= 1;
            @(negedge clk);
            start <= 0;
            got = 0; lasts = 0; exp_row = 0; exp_col = 0; exp_g = 0;
            cycles_frame = 0;

            // p_acc counts real handshakes (sampled at posedge, pre-NBA
            // values); stimulus changes only on negedge.
            p_acc = 0;
            while (p_acc < W*H*NG) begin
                if (($random & 127) >= bubble_pct) begin
                    in_valid <= 1;
                    // beat p_acc = pixel p_acc/NG, group p_acc%NG
                    for (c = 0; c < LANES; c = c + 1) in_pix[c*8 +: 8] <= fmap[(p_acc/NG)*C + (p_acc%NG)*LANES + c];
                end else begin
                    in_valid <= 0;
                end
                @(negedge clk);
                cycles_frame = cycles_frame + 1;
            end
            in_valid <= 0;
            wdg = 0;
            while (lasts == 0 && wdg < 20000) begin @(negedge clk); wdg = wdg + 1; end
            if (lasts == 0 || got != OUT_W*OUT_H*NG) begin
                errors = errors + 1;
                $display("FAIL frame %0d W=%0d H=%0d S=%0d NG=%0d: got %0d outputs, exp %0d, lasts=%0d",
                         frame, W, H, S, NG, got, OUT_W*OUT_H*NG, lasts);
            end
            if (frame < 12)
                $display("frame %2d W=%0d H=%0d S=%0d NG=%0d: %0d output beats, %0d input cycles for %0d beats",
                         frame, W, H, S, NG, got, cycles_frame, W*H*NG);
        end
        $display("=== %0d output vectors checked (x%0d lanes), %0d errors ===", checks, LANES, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_dw_linebuf_grouped, LANES=%0d MAXNG=%0d, 48 frames)", LANES, MAXNG);
        $finish;
    end
endmodule
