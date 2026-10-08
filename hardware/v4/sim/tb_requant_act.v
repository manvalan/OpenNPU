// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4 -- isolated test for requant_act.v against an independent golden
// written with plain 64-bit integer arithmetic (division-free: explicit
// floor via >>> on longint). Random + extreme accumulators, all shifts
// 0..31, all alpha shifts 0..7, all three activations, random stalls.
// ============================================================
module tb;
    localparam N = 4;
    localparam IN_W = 32;
    localparam NVEC = 40000;

    reg clk = 0;
    always #5 clk = ~clk;
    reg en;
    reg signed [IN_W*N-1:0] acc;
    reg signed [32*N-1:0]   bias;
    reg signed [8*N-1:0]    alpha;
    reg [4:0] shift;
    reg [2:0] ash;
    reg [1:0] act;
    wire signed [8*N-1:0] y;

    requant_act #(.N(N), .IN_W(IN_W)) dut (
        .clk(clk), .en(en), .acc(acc), .bias(bias), .alpha(alpha),
        .shift(shift), .ash(ash), .act(act), .y(y)
    );

    function automatic integer sat8(input longint v);
        sat8 = (v > 127) ? 127 : ((v < -128) ? -128 : v);
    endfunction

    function automatic integer golden(input longint a, input longint b, input integer al,
                                      input integer sh, input integer as, input integer ac);
        longint s, q, p;
        begin
            s = a + b;
            if (sh > 0) s = s + (64'sd1 <<< (sh-1));
            q = sat8(s >>> sh);
            if (ac == 1)      golden = (q < 0) ? 0 : q;
            else if (ac == 2) begin
                if (q >= 0) golden = q;
                else begin
                    p = q * al;
                    if (as > 0) p = p + (64'sd1 <<< (as-1));
                    golden = sat8(p >>> as);
                end
            end else golden = q;
        end
    endfunction

    // expected-value pipeline mirrors the DUT's 7 en-gated stages
    integer exp_q [0:7][0:N-1];
    reg     exp_v [0:7];
    integer errors, checked, i, l, t;
    longint av, bv;

    function automatic longint rnd_acc(input integer m);
        case (m)
            0: rnd_acc = $random;                          // full 32-bit
            1: rnd_acc = $random % 70000;                  // typical
            2: rnd_acc = ($random & 1) ? 2147483647 : -2147483648;
            default: rnd_acc = $random % 300;
        endcase
    endfunction

    initial begin
        errors = 0; checked = 0;
        en = 1; acc = 0; bias = 0; alpha = 0; shift = 0; ash = 0; act = 0;
        for (t = 0; t < 8; t = t + 1) exp_v[t] = 0;
        for (i = 0; i < NVEC; i = i + 1) begin
            @(negedge clk);
            // stalls: when en=0 the DUT must hold; the golden pipe too
            en <= (($random & 7) != 0);
            #1;
            if (en) begin
                // check the value that has been in stage 3 since the last en edge
                if (exp_v[7]) begin
                    for (l = 0; l < N; l = l + 1) begin
                        if ($signed(y[l*8 +: 8]) !== exp_q[7][l]) begin
                            errors = errors + 1;
                            if (errors < 20) $display("FAIL vec lane %0d: got %0d exp %0d", l, $signed(y[l*8 +: 8]), exp_q[7][l]);
                        end
                    end
                    checked = checked + 1;
                end
            end
            // new inputs (config changes per vector too: exercises every combination)
            shift <= $random; ash <= $random; act <= ($random & 32'h7fffffff) % 3;
            #1;
            for (l = 0; l < N; l = l + 1) begin
                av = rnd_acc(($random & 32'h7fffffff) % 4);
                bv = (($random & 3) == 0) ? 0 : $random % 100000;
                acc[l*IN_W +: IN_W]  = av;
                bias[l*32 +: 32]     = bv;
                alpha[l*8 +: 8]      = $random;
            end
            @(posedge clk);
            if (en) begin
                // advance golden pipe: inputs sampled at this edge enter stage 1
                for (t = 7; t > 0; t = t - 1) begin
                    exp_v[t] = exp_v[t-1];
                    for (l = 0; l < N; l = l + 1) exp_q[t][l] = exp_q[t-1][l];
                end
                exp_v[0] = 1;
                for (l = 0; l < N; l = l + 1)
                    exp_q[0][l] = golden($signed(acc[l*IN_W +: IN_W]), $signed(bias[l*32 +: 32]),
                                         $signed(alpha[l*8 +: 8]), shift, ash, act);
            end
        end
        $display("=== %0d vectors x %0d lanes checked, %0d errors ===", checked, N, errors);
        if (errors == 0) $display("ALL TESTS PASSED (tb_requant_act)");
        $finish;
    end
endmodule
