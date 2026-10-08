// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps
// v4 -- isolated test for conv3_feeder.v: random feature maps of several
// sizes, group counts and strides in a latency-4 memory model full of
// stale data, every output beat (and its out-of-map flag) compared with
// the directly computed window word (zero outside the map), random
// output back-pressure. Convolution order (kr, kc, g) with 3x3 pad 1,
// pooling order (g, kr, kc) with 3x3 pad 1 and 2x2 without padding,
// 1x1 copies into wider tensors (extra groups zero) and 2x upsampling.
module tb;
    localparam BASE = 300, NF = 20;
    reg clk = 0; always #5 clk = ~clk;
    reg rst, start;
    reg [7:0] iw, ih, ow, oh; reg [5:0] ng; reg s2; reg [14:0] rs; reg pool, k2, pad, k1, up2; reg [5:0] nge;
    wire opad;
    wire rd_en; wire [14:0] rd_addr; wire [127:0] rd_data;
    wire ov; reg orr; wire [127:0] od; wire busy;
    conv3_feeder #(.AW(15)) dut (
        .clk(clk), .rst(rst), .start(start), .busy(busy),
        .cfg_base(15'd300), .cfg_iw(iw), .cfg_ih(ih), .cfg_ng(ng), .cfg_rs(rs), .cfg_s2(s2),
        .cfg_ow(ow), .cfg_oh(oh), .cfg_pool(pool), .cfg_k2(k2), .cfg_pad(pad), .out_pad(opad),
        .cfg_k1(k1), .cfg_up2(up2), .cfg_nge(nge),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data),
        .out_valid(ov), .out_ready(orr), .out_data(od));
    reg [127:0] mem [0:32767];
    reg [14:0] ad0; always @(posedge clk) ad0 <= rd_addr;
    reg [127:0] m1, m2, m3;
    always @(posedge clk) begin m1 <= mem[ad0]; m2 <= m1; m3 <= m2; end
    assign rd_data = m3;
    integer i, j, k, r, c, errors, beats, frame, wd, s, nexp, kr, kc, g, nb, rr, cc, K, PD, ins;
    // reads must stay inside the map
    always @(posedge clk) if (!rst && rd_en && (rd_addr < BASE || rd_addr >= BASE + ih * rs)) begin
        errors = errors + 1;
        if (errors < 10) $display("FAIL frame %0d: read outside the map at %0d", frame, rd_addr);
    end
    reg [127:0] e;
    integer T_IW [0:NF-1], T_IH [0:NF-1], T_NG [0:NF-1], T_S [0:NF-1], T_M [0:NF-1], T_E [0:NF-1];
    // M: 0 conv, 1 pool 3x3 pad 1, 2 pool 2x2, 3 copy 1x1, 4 upsampling 2x; E: emitted groups (copy)
    initial begin
        T_IW[0] = 14;  T_IH[0] = 14;  T_NG[0] = 8;  T_S[0] = 1;
        T_IW[1] = 14;  T_IH[1] = 14;  T_NG[1] = 8;  T_S[1] = 2;
        T_IW[2] = 13;  T_IH[2] = 7;   T_NG[2] = 2;  T_S[2] = 2;   // odd sizes
        T_IW[3] = 9;   T_IH[3] = 11;  T_NG[3] = 4;  T_S[3] = 1;
        T_IW[4] = 1;   T_IH[4] = 1;   T_NG[4] = 2;  T_S[4] = 1;   // 1x1 map
        T_IW[5] = 2;   T_IH[5] = 3;   T_NG[5] = 16; T_S[5] = 2;
        T_IW[6] = 56;  T_IH[6] = 30;  T_NG[6] = 2;  T_S[6] = 1;
        T_IW[7] = 255; T_IH[7] = 3;   T_NG[7] = 1;  T_S[7] = 2;   // widest
        T_IW[8] = 5;   T_IH[8] = 4;   T_NG[8] = 28; T_S[8] = 1;   // most groups
        T_IW[9] = 14;  T_IH[9] = 14;  T_NG[9] = 4;  T_S[9] = 2;   // pooling 2x2 s2
        T_IW[10] = 13; T_IH[10] = 7;  T_NG[10] = 2; T_S[10] = 2;  // 2x2 s2, odd size (floor)
        T_IW[11] = 9;  T_IH[11] = 11; T_NG[11] = 8; T_S[11] = 1;  // 2x2 s1
        T_IW[12] = 32; T_IH[12] = 32; T_NG[12] = 2; T_S[12] = 2;  // 3x3 s2 pad 1
        T_IW[13] = 7;  T_IH[13] = 5;  T_NG[13] = 1; T_S[13] = 1;  // 3x3 s1 pad 1
        T_IW[14] = 2;  T_IH[14] = 2;  T_NG[14] = 32; T_S[14] = 2; // 2x2 on 2x2 -> 1x1
        for (i = 0; i < NF; i = i + 1) T_M[i] = 0;
        T_M[9] = 2; T_M[10] = 2; T_M[11] = 2; T_M[12] = 1; T_M[13] = 1; T_M[14] = 2;
        T_IW[15] = 9;  T_IH[15] = 5;  T_NG[15] = 2;  T_S[15] = 1; T_M[15] = 3;   // copy, same groups
        T_IW[16] = 6;  T_IH[16] = 7;  T_NG[16] = 3;  T_S[16] = 1; T_M[16] = 3;   // copy 3 -> 8 groups
        T_IW[17] = 7;  T_IH[17] = 4;  T_NG[17] = 4;  T_S[17] = 1; T_M[17] = 4;   // upsampling 7x4 -> 14x8
        T_IW[18] = 1;  T_IH[18] = 1;  T_NG[18] = 1;  T_S[18] = 1; T_M[18] = 4;   // 1x1 -> 2x2
        T_IW[19] = 20; T_IH[19] = 15; T_NG[19] = 2;  T_S[19] = 1; T_M[19] = 4;
        for (i = 0; i < NF; i = i + 1) T_E[i] = T_NG[i];
        T_E[16] = 8; T_E[19] = 5;
    end
    always @(negedge clk) orr <= ($random & 3) != 0;
    always @(posedge clk) if (!rst && ov && orr) begin
        nb = K * K * nge;
        i = (beats / nb) / ow; j = (beats / nb) % ow; k = beats % nb;
        if (pool) begin g = k / (K * K); kr = (k / K) % K; kc = k % K; end
        else begin kr = k / (K * ng); kc = (k / ng) % K; g = k % ng; end
        rr = s * i - PD + kr; cc = s * j - PD + kc;
        if (up2) begin rr = i / 2; cc = j / 2; end
        ins = !(rr < 0 || cc < 0 || rr >= ih || cc >= iw || g >= ng);
        e = ins ? mem[BASE + (rr * iw + cc) * ng + g] : 128'd0;
        if (od !== e || opad !== !ins) begin
            errors = errors + 1;
            if (errors < 10) $display("FAIL frame %0d pos(%0d,%0d) tap(%0d,%0d) g %0d: got %h exp %h",
                                      frame, i, j, kr, kc, g, od, e);
        end
        beats = beats + 1;
    end
    initial begin
        errors = 0; start = 0; iw = 1; ih = 1; ng = 1; rs = 1; s2 = 0; ow = 1; oh = 1;
        rst = 1; repeat (3) @(posedge clk); @(negedge clk) rst = 0;
        for (frame = 0; frame < NF; frame = frame + 1) begin
            for (r = 0; r < 32768; r = r + 1) mem[r] = {$random, $random, $random, $random};
            @(negedge clk);
            iw <= T_IW[frame]; ih <= T_IH[frame]; ng <= T_NG[frame]; s = T_S[frame]; s2 <= (T_S[frame] == 2);
            pool <= T_M[frame] != 0; k2 <= T_M[frame] == 2; pad <= T_M[frame] < 2;
            k1 <= T_M[frame] >= 3; up2 <= T_M[frame] == 4; nge <= T_E[frame];
            K = (T_M[frame] >= 3) ? 1 : (T_M[frame] == 2) ? 2 : 3; PD = (T_M[frame] < 2) ? 1 : 0;
            ow <= (T_M[frame] == 4) ? 2 * T_IW[frame] : (T_IW[frame] + 2 * PD - K) / T_S[frame] + 1;
            oh <= (T_M[frame] == 4) ? 2 * T_IH[frame] : (T_IH[frame] + 2 * PD - K) / T_S[frame] + 1;
            rs <= T_IW[frame] * T_NG[frame];
            repeat (3) @(negedge clk);
            beats = 0;
            nexp = ow * oh * K * K * nge;
            start <= 1; @(negedge clk) start <= 0;
            wd = 0;
            while (beats < nexp && wd < 2000000) begin @(negedge clk); wd = wd + 1; end
            $display("frame %0d: %s %0dx%0d pad %0d, %0dx%0d ng %0d->%0d s%0d -> %0dx%0d, %0d beats in %0d cycles",
                     frame, up2 ? "up2 " : pool ? "pool" : "conv", K, K, PD, iw, ih, ng, nge, s, ow, oh, beats, wd);
            if (beats != nexp) begin errors = errors + 1; $display("FAIL: incomplete"); end
            repeat (40) @(negedge clk);
            if (ov) begin errors = errors + 1; $display("FAIL: extra beats"); end
            if (busy) begin errors = errors + 1; $display("FAIL: still busy"); end
        end
        $display("=== %0d errors ===", errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_conv3_feeder)");
        $finish;
    end
endmodule
