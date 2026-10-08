// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps
// v4 -- isolated test for im2col_feeder.v: random images of several sizes,
// channel counts (1..4) and strides (1, 2) in a latency-4 memory model,
// every output beat compared with a directly computed im2col vector,
// random output back-pressure. Frame 0 is the MobileFaceNet conv1 case
// (112x112x3, stride 2).
module tb;
    localparam BASE = 100, NF = 10;
    reg clk = 0; always #5 clk = ~clk;
    reg rst, start;
    reg [7:0] iw, ih, ow, oh; reg [2:0] ch; reg s2; reg [4:0] rw; reg [1:0] ng;
    wire rd_en; wire [14:0] rd_addr; wire [127:0] rd_data;
    wire ov; reg orr; wire [127:0] od;
    im2col_feeder #(.AW(15)) dut (
        .clk(clk), .rst(rst), .start(start), .cfg_base(15'd100),
        .cfg_iw(iw), .cfg_ih(ih), .cfg_c(ch), .cfg_s2(s2), .cfg_rw(rw),
        .cfg_ow(ow), .cfg_oh(oh), .cfg_ng(ng),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data),
        .out_valid(ov), .out_ready(orr), .out_data(od));
    reg [127:0] mem [0:8191];
    // latency 4: rd_en/addr in cycle t -> data in cycle t+4
    reg [14:0] ad0; always @(posedge clk) ad0 <= rd_addr;
    reg [127:0] m1, m2, m3;
    always @(posedge clk) begin m1 <= mem[ad0]; m2 <= m1; m3 <= m2; end
    assign rd_data = m3;
    reg [7:0] img [0:255][0:511];
    function [7:0] px(input integer r, input integer c, input integer k);
        px = (r < 0 || c < 0 || r >= ih || c >= iw) ? 8'd0 : img[r][c*ch+k];
    endfunction
    integer r, c, b, i, j, beat, errors, beats, frame, kr, kc, k, wd, s, nexp;
    reg [383:0] v;
    // test cases: iw ih c stride
    integer T_IW [0:NF-1], T_IH [0:NF-1], T_C [0:NF-1], T_S [0:NF-1];
    initial begin
        T_IW[0] = 112; T_IH[0] = 112; T_C[0] = 3; T_S[0] = 2;   // MobileFaceNet
        T_IW[1] = 96;  T_IH[1] = 64;  T_C[1] = 3; T_S[1] = 2;
        T_IW[2] = 37;  T_IH[2] = 23;  T_C[2] = 3; T_S[2] = 2;   // odd sizes
        T_IW[3] = 64;  T_IH[3] = 48;  T_C[3] = 1; T_S[3] = 2;   // grayscale
        T_IW[4] = 50;  T_IH[4] = 41;  T_C[4] = 1; T_S[4] = 1;
        T_IW[5] = 40;  T_IH[5] = 33;  T_C[5] = 2; T_S[5] = 1;
        T_IW[6] = 33;  T_IH[6] = 20;  T_C[6] = 4; T_S[6] = 2;   // 3 beats
        T_IW[7] = 124; T_IH[7] = 30;  T_C[7] = 4; T_S[7] = 1;   // widest RGBA row
        T_IW[8] = 165; T_IH[8] = 17;  T_C[8] = 3; T_S[8] = 1;   // widest RGB row
        T_IW[9] = 1;   T_IH[9] = 1;   T_C[9] = 3; T_S[9] = 1;   // smallest
    end
    always @(negedge clk) orr <= ($random & 3) != 0;
    always @(posedge clk) if (!rst && ov && orr) begin
        i = (beats / ng) / ow; j = (beats / ng) % ow; beat = beats % ng;
        v = 0;
        for (kr = 0; kr < 3; kr = kr + 1) for (kc = 0; kc < 3; kc = kc + 1) for (k = 0; k < ch; k = k + 1)
            v[(kr*3*ch+kc*ch+k)*8 +: 8] = px(s*i-1+kr, s*j-1+kc, k);
        if (od !== v[beat*128 +: 128]) begin
            errors = errors + 1;
            if (errors < 10) $display("FAIL frame %0d pos(%0d,%0d) beat %0d: got %h exp %h", frame, i, j, beat, od, v[beat*128 +: 128]);
        end
        beats = beats + 1;
    end
    initial begin
        errors = 0; start = 0;
        rst = 1; repeat (3) @(posedge clk); @(negedge clk) rst = 0;
        for (frame = 0; frame < NF; frame = frame + 1) begin
            @(negedge clk);
            iw = T_IW[frame]; ih = T_IH[frame]; ch = T_C[frame]; s = T_S[frame]; s2 = (s == 2);
            ow = (iw + s - 1) / s; oh = (ih + s - 1) / s;
            rw = (iw * ch + 15) / 16; ng = (9 * ch + 15) / 16; if (ng < 2) ng = 2;
            // image rows at BASE + r*rw words; bytes past iw*ch zero
            for (r = 0; r < ih; r = r + 1) for (b = 0; b < 512; b = b + 1)
                img[r][b] = (b < iw * ch) ? $random : 8'd0;
            // stale data in the memory around the image
            for (r = 0; r < 8192; r = r + 1) mem[r] = {$random, $random, $random, $random};
            for (r = 0; r < ih; r = r + 1) for (i = 0; i < rw; i = i + 1)
                for (b = 0; b < 16; b = b + 1) mem[BASE + r*rw + i][b*8 +: 8] = img[r][i*16+b];
            beats = 0;
            nexp = ow * oh * ng;
            start <= 1; @(negedge clk) start <= 0;
            wd = 0;
            while (beats < nexp && wd < 400000) begin @(negedge clk); wd = wd + 1; end
            $display("frame %0d: %0dx%0dx%0d s%0d -> %0dx%0d, %0d beats in %0d cycles",
                     frame, iw, ih, ch, s, ow, oh, beats, wd);
            if (beats != nexp) begin errors = errors + 1; $display("FAIL: incomplete"); end
            repeat (40) @(negedge clk);
            if (ov) begin errors = errors + 1; $display("FAIL: extra beats"); end
        end
        $display("=== %0d errors ===", errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_im2col_feeder)");
        $finish;
    end
endmodule
