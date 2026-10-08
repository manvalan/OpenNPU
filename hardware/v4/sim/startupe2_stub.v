// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps
// Icarus-only stand-in for the STARTUPE2 primitive (flash CCLK path),
// used by tb_v4_board_top.v; the real primitive is used by Vivado/xsim.
module STARTUPE2 #(parameter PROG_USR = "FALSE", parameter real SIM_CCLK_FREQ = 0.0) (
    output wire CFGCLK, output wire CFGMCLK, output wire EOS, output wire PREQ,
    input wire CLK, input wire GSR, input wire GTS, input wire KEYCLEARB, input wire PACK,
    input wire USRCCLKO, input wire USRCCLKTS, input wire USRDONEO, input wire USRDONETS);
    assign CFGCLK = 1'b0; assign CFGMCLK = 1'b0; assign EOS = 1'b1; assign PREQ = 1'b0;
endmodule
