// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps
module tb;
    reg signed [7:0] d [0:8];
    reg signed [7:0] w [0:8];
    wire signed [19:0] y;

    depthwise_mac3x3 dut (
        .d0(d[0]),.d1(d[1]),.d2(d[2]),.d3(d[3]),.d4(d[4]),
        .d5(d[5]),.d6(d[6]),.d7(d[7]),.d8(d[8]),
        .w0(w[0]),.w1(w[1]),.w2(w[2]),.w3(w[3]),.w4(w[4]),
        .w5(w[5]),.w6(w[6]),.w7(w[7]),.w8(w[8]),
        .y(y)
    );

    function automatic signed [19:0] golden;
        integer i;
        reg signed [19:0] acc;
        begin
            acc = 0;
            for (i = 0; i < 9; i = i + 1) acc = acc + d[i]*w[i];
            golden = acc;
        end
    endfunction

    integer errors, tests, k, i;
    reg signed [19:0] g;
    initial begin
        errors = 0; tests = 0;
        for (i=0;i<9;i=i+1) d[i]=8'sd127;
        for (i=0;i<9;i=i+1) w[i]=8'sd127;
        #1; g = golden(); tests=tests+1; if (y!==g) begin errors=errors+1; $display("FAIL max: got=%0d exp=%0d",y,g); end

        for (i=0;i<9;i=i+1) d[i]=-8'sd128;
        for (i=0;i<9;i=i+1) w[i]=-8'sd128;
        #1; g = golden(); tests=tests+1; if (y!==g) begin errors=errors+1; $display("FAIL min: got=%0d exp=%0d",y,g); end

        for (k=0;k<2000;k=k+1) begin
            for (i=0;i<9;i=i+1) d[i]=$random;
            for (i=0;i<9;i=i+1) w[i]=$random;
            #1; g = golden(); tests=tests+1;
            if (y!==g) begin errors=errors+1; $display("FAIL random: got=%0d exp=%0d",y,g); end
        end
        $display("=== %0d/%0d tests, %0d errors ===", tests-errors, tests, errors);
        if (errors==0) $display("ALL TESTS PASSED (tb_depthwise_mac3x3)");
        $finish;
    end
endmodule
