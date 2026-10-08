// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- end-to-end test of dwpw_engine.v (depthwise 3x3 -> requant ->
// pointwise 1x1 -> requant, fused). Independent golden in plain integer
// arithmetic: per-channel depthwise, requant (same definition as
// requant_act.v's header), dot products over ALL input channels,
// requant. Every output tile (pair, channel tile) is checked, plus
// coverage (each tile exactly once) and done. Random layer shapes:
// sizes, stride 1/2, ng, nco, activations, input bubbles.
// Also reports cycles start->done against the ideal ng*nco per pair.
// ============================================================
module tb;
    localparam P     = `ifdef TB_P `TB_P `else 4 `endif;
    localparam P_CO  = `ifdef TB_PCO `TB_PCO `else 3 `endif;
    localparam NDSP  = `ifdef TB_NDSP `TB_NDSP `else P_CO `endif;
    localparam MAXW  = `ifdef TB_MAXW `TB_MAXW `else 20 `endif;
    localparam MAXNG = `ifdef TB_MAXNG `TB_MAXNG `else 4 `endif;
    localparam MAXNCO = `ifdef TB_MAXNCO `TB_MAXNCO `else 4 `endif;
    localparam CMAX  = P*MAXNG;
    localparam COMAX = P_CO*MAXNCO;
    localparam NLAYERS = `ifdef TB_NLAYERS `TB_NLAYERS `else 24 `endif;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst, start;
    wire done;

    reg [7:0] cfg_w, cfg_h;
    reg [5:0] cfg_ng, cfg_nco;
    reg cfg_stride2;
    reg cfg_pw_only;
    integer PWO;
    reg [4:0] dw_shift, pw_shift;
    reg [2:0] dw_ash, pw_ash;
    reg [1:0] dw_act, pw_act;

    reg in_valid;
    wire in_ready;
    reg signed [8*P-1:0] in_pix;

    wire [5:0] wd_g, rq_g, pwq_cot;
    // two-cycle lookup like v4_core (address register + data register):
    // the engine's B-lane requant samples the bias 2 cycles after the tag
    // pointer moves, so a one-cycle model would give B the next tile's
    reg  [5:0] pwq_cot_d0, pwq_cot_d;
    always @(posedge clk) begin pwq_cot_d0 <= pwq_cot; pwq_cot_d <= pwq_cot_d0; end
    reg signed [72*P-1:0] wd_flat;
    reg signed [32*P-1:0] dw_bias_f;
    reg signed [8*P-1:0]  dw_alpha_f;
    wire [15:0] w_addr;
    reg signed [8*P*P_CO-1:0] w_data;
    reg signed [32*P_CO-1:0] pw_bias_f;
    reg signed [8*P_CO-1:0]  pw_alpha_f;

    wire o_valid, o_b_valid;
    wire [15:0] o_pair;
    wire [5:0] o_cot;
    wire signed [8*P_CO-1:0] o_ya, o_yb;

    dwpw_engine #(.P(P), .P_CO(P_CO), .N_DSP_COLS(NDSP), .MAXW(MAXW), .MAXNG(MAXNG), .MAXNCO(MAXNCO)) dut (
        .clk(clk), .rst(rst), .start(start), .done(done),
        .cfg_w_i(cfg_w), .cfg_h_i(cfg_h), .cfg_ng_i(cfg_ng), .cfg_nco_i(cfg_nco), .cfg_stride2_i(cfg_stride2), .cfg_pw_only_i(cfg_pw_only),
        .dw_shift_i(dw_shift), .dw_ash_i(dw_ash), .dw_act_i(dw_act),
        .pw_shift_i(pw_shift), .pw_ash_i(pw_ash), .pw_act_i(pw_act),
        .in_valid(in_valid), .in_ready(in_ready), .in_pix(in_pix),
        .wd_g(wd_g), .wd_flat(wd_flat), .rq_g(rq_g), .dw_bias(dw_bias_f), .dw_alpha(dw_alpha_f),
        .w_base_i(16'd0), .w_addr(w_addr), .w_data(w_data),
        .pwq_cot(pwq_cot), .pw_bias(pw_bias_f), .pw_alpha(pw_alpha_f),
        .x_sel(1'b0), .x_acc({32*P_CO{1'b0}}),     // GDConv requant input unused here
        .o_valid(o_valid), .o_pair(o_pair), .o_cot(o_cot), .o_b_valid(o_b_valid), .o_ya(o_ya), .o_yb(o_yb)
    );

    // ---------------- layer data ----------------
    reg signed [7:0]  fmap [0:MAXW*MAXW*CMAX-1];
    reg signed [7:0]  wd [0:CMAX-1][0:8];
    integer           dwb [0:CMAX-1];
    reg signed [7:0]  dwa [0:CMAX-1];
    reg signed [7:0]  wp [0:COMAX-1][0:CMAX-1];
    integer           pwb [0:COMAX-1];
    reg signed [7:0]  pwa [0:COMAX-1];
    integer W, H, S, NG, NCO, C, CO, OUT_W, OUT_H, NPOS, NPAIRS;

    // golden results
    integer dwq  [0:MAXW*MAXW-1][0:CMAX-1];
    integer gold [0:MAXW*MAXW-1][0:COMAX-1];
    reg     seen [0:MAXW*MAXW-1][0:MAXNCO-1];

    function automatic integer sat8(input longint v);
        sat8 = (v > 127) ? 127 : ((v < -128) ? -128 : v);
    endfunction
    function automatic integer requant(input longint a, input longint b, input integer al,
                                       input integer sh, input integer as, input integer ac);
        longint s, q, p;
        begin
            s = a + b;
            if (sh > 0) s = s + (64'sd1 <<< (sh-1));
            q = sat8(s >>> sh);
            if (ac == 1)      requant = (q < 0) ? 0 : q;
            else if (ac == 2) begin
                if (q >= 0) requant = q;
                else begin
                    p = q * al;
                    if (as > 0) p = p + (64'sd1 <<< (as-1));
                    requant = sat8(p >>> as);
                end
            end else requant = q;
        end
    endfunction

    // ---------------- memories / lookups seen by the DUT ----------------
    integer l, k2;
    always @(*) begin
        for (l = 0; l < P; l = l + 1) begin
            for (k2 = 0; k2 < 9; k2 = k2 + 1) wd_flat[l*72 + k2*8 +: 8] = wd[wd_g*P + l][k2];
            dw_bias_f[l*32 +: 32] = dwb[rq_g*P + l];
            dw_alpha_f[l*8 +: 8]  = dwa[rq_g*P + l];
        end
        // the engine's pw requant samples bias/alpha one cycle after the
        // accumulators (BIAS_LAT = 1): look up the tile it asked for one
        // cycle earlier
        for (l = 0; l < P_CO; l = l + 1) begin
            pw_bias_f[l*32 +: 32] = pwb[pwq_cot_d*P_CO + l];
            pw_alpha_f[l*8 +: 8]  = pwa[pwq_cot_d*P_CO + l];
        end
    end
    // pointwise weight RAM, synchronous read: word cot*NG+g
    integer wc, wi, wcot, wg;
    always @(posedge clk) begin
        wcot = w_addr / NG; wg = w_addr % NG;
        for (wc = 0; wc < P_CO; wc = wc + 1)
            for (wi = 0; wi < P; wi = wi + 1)
                w_data[(wc*P + wi)*8 +: 8] <= wp[wcot*P_CO + wc][wg*P + wi];
    end

    // ---------------- output checker ----------------
    integer errors, tiles, j, pa, pb;
    always @(posedge clk) begin
        if (!rst && o_valid) begin
            tiles = tiles + 1;
            pa = 2*o_pair; pb = 2*o_pair + 1;
            if (o_cot >= NCO || pa >= NPOS) begin
                errors = errors + 1;
                $display("FAIL bad tile pair=%0d cot=%0d", o_pair, o_cot);
            end else begin
                if (seen[pa][o_cot]) begin errors = errors + 1; $display("FAIL duplicate tile pair=%0d cot=%0d", o_pair, o_cot); end
                seen[pa][o_cot] = 1;
                if (o_b_valid !== (pb < NPOS)) begin errors = errors + 1; $display("FAIL b_valid pair=%0d", o_pair); end
                for (j = 0; j < P_CO; j = j + 1) begin
                    if ($signed(o_ya[j*8 +: 8]) !== gold[pa][o_cot*P_CO + j]) begin
                        errors = errors + 1;
                        if (errors < 20) $display("FAIL pos %0d co %0d: got %0d exp %0d", pa, o_cot*P_CO+j, $signed(o_ya[j*8 +: 8]), gold[pa][o_cot*P_CO+j]);
                    end
                    if (pb < NPOS && $signed(o_yb[j*8 +: 8]) !== gold[pb][o_cot*P_CO + j]) begin
                        errors = errors + 1;
                        if (errors < 20) $display("FAIL pos %0d co %0d: got %0d exp %0d", pb, o_cot*P_CO+j, $signed(o_yb[j*8 +: 8]), gold[pb][o_cot*P_CO+j]);
                    end
                end
            end
        end
    end

    // handshake counter for the input driver
    integer p_acc;
    always @(posedge clk) if (!rst && in_valid && in_ready) p_acc = p_acc + 1;

    integer layer, i, c, co, pos, orow, ocol, kr, kc, bubble_pct, wdg, cyc, missing;
    integer total_cyc, total_ideal;
    longint acc;
    initial begin
        errors = 0; tiles = 0; total_cyc = 0; total_ideal = 0;
        rst = 1; start = 0; in_valid = 0; in_pix = 0;
        cfg_w = 3; cfg_h = 3; cfg_ng = 1; cfg_nco = 1; cfg_stride2 = 0; cfg_pw_only = 0;
        dw_shift = 0; pw_shift = 0; dw_ash = 0; pw_ash = 0; dw_act = 0; pw_act = 0;
        repeat (4) @(posedge clk);
        @(negedge clk) rst = 0;

        for (layer = 0; layer < NLAYERS; layer = layer + 1) begin
            W = 3 + ($random & 32'h7fffffff) % (MAXW - 2);
            H = 3 + ($random & 32'h7fffffff) % 12;
            S = (layer % 3 == 2) ? 2 : 1;
            // ng >= 2: the core contract (v4_plan.py: Cin >= 32; results
            // >= 2 cycles apart, needed by the shared A/B pointwise requant)
            NG  = 2 + ($random & 32'h7fffffff) % (MAXNG - 1);
            NCO = 1 + ($random & 32'h7fffffff) % MAXNCO;
            if (layer == 0) begin W = 6; H = 5; S = 1; NG = 2; NCO = 2; end
`ifdef TB_FIXED
            // fixed real layer shape (padded input W x H), e.g. a MobileFaceNet block
            W = `TB_FW; H = `TB_FH; S = `TB_FS; NG = `TB_FNG; NCO = `TB_FNCO;
`endif
            PWO = (layer % 5 == 4);
`ifdef TB_FPWO
            PWO = 1;
`endif
            C = NG*P; CO = NCO*P_CO;
            OUT_W = (W-3)/S + 1; OUT_H = (H-3)/S + 1;
            if (PWO) begin OUT_W = W; OUT_H = H; S = 1; end
            NPOS = OUT_W*OUT_H; NPAIRS = (NPOS+1)/2;
            bubble_pct = (layer % 4 == 3) ? 50 : 0;

            for (i = 0; i < W*H*C; i = i + 1) fmap[i] = $random;
            for (c = 0; c < C; c = c + 1) begin
                for (i = 0; i < 9; i = i + 1) wd[c][i] = $random;
                dwb[c] = $random % 20000; dwa[c] = $random;
            end
            for (co = 0; co < CO; co = co + 1) begin
                for (c = 0; c < C; c = c + 1) wp[co][c] = $random;
                pwb[co] = $random % 20000; pwa[co] = $random;
            end
            @(negedge clk);
            dw_shift <= 6 + $random % 3; pw_shift <= 7 + $random % 3;
            dw_ash <= $random; pw_ash <= $random;
            dw_act <= layer % 3; pw_act <= (layer + 1) % 3;
            cfg_w <= W; cfg_h <= H; cfg_ng <= NG; cfg_nco <= NCO; cfg_stride2 <= (S == 2); cfg_pw_only <= PWO;
            @(negedge clk);

            // golden
            for (pos = 0; pos < NPOS; pos = pos + 1) begin
                orow = pos / OUT_W; ocol = pos % OUT_W;
                for (c = 0; c < C; c = c + 1) begin
                    if (PWO) dwq[pos][c] = fmap[pos*C + c];
                    else begin
                        acc = 0;
                        for (kr = 0; kr < 3; kr = kr + 1)
                            for (kc = 0; kc < 3; kc = kc + 1)
                                acc = acc + fmap[((orow*S+kr)*W + (ocol*S+kc))*C + c] * wd[c][kr*3+kc];
                        dwq[pos][c] = requant(acc, dwb[c], dwa[c], dw_shift, dw_ash, dw_act);
                    end
                end
                for (co = 0; co < CO; co = co + 1) begin
                    acc = 0;
                    for (c = 0; c < C; c = c + 1) acc = acc + wp[co][c] * dwq[pos][c];
                    gold[pos][co] = requant(acc, pwb[co], pwa[co], pw_shift, pw_ash, pw_act);
                end
                for (i = 0; i < MAXNCO; i = i + 1) seen[pos][i] = 0;
            end

            start <= 1;
            @(negedge clk);
            start <= 0;
            cyc = 1;
            p_acc = 0;
            while (p_acc < W*H*NG) begin
                if (($random & 127) >= bubble_pct) begin
                    in_valid <= 1;
                    for (c = 0; c < P; c = c + 1) in_pix[c*8 +: 8] <= fmap[(p_acc/NG)*C + (p_acc%NG)*P + c];
                end else in_valid <= 0;
                @(negedge clk); cyc = cyc + 1;
            end
            in_valid <= 0;
            wdg = 0;
            while (!done && wdg < 200000) begin @(negedge clk); wdg = wdg + 1; cyc = cyc + 1; end
            if (!done) begin errors = errors + 1; $display("FAIL layer %0d: no done", layer); end
            missing = 0;
            for (pos = 0; pos < NPOS; pos = pos + 2)
                for (i = 0; i < NCO; i = i + 1) if (!seen[pos][i]) missing = missing + 1;
            if (missing) begin errors = errors + 1; $display("FAIL layer %0d: %0d tiles missing", layer, missing); end
            if (bubble_pct == 0) begin
                total_cyc = total_cyc + cyc; total_ideal = total_ideal + NPAIRS*NCO*NG;
            end
            $display("layer %2d: %s in %0dx%0d s%0d Cin=%0d Cout=%0d -> %0d pos, %0d cycles (pw ideal %0d, input beats %0d)%s",
                     layer, PWO ? "PW-only" : "dw+pw  ", W, H, S, C, CO, NPOS, cyc, NPAIRS*NCO*NG, W*H*NG, bubble_pct ? " [bubbles]" : "");
        end
        $display("=== %0d layers, %0d output tiles checked, %0d errors; no-bubble layers: %0d cycles vs %0d ideal pw cycles ===",
                 NLAYERS, tiles, errors, total_cyc, total_ideal);
        if (errors == 0) $display("ALL TESTS PASSED (tb_dwpw_engine, P=%0d P_CO=%0d NDSP=%0d)", P, P_CO, NDSP);
        $finish;
    end
endmodule
