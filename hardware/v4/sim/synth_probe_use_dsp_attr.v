// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/manvalan/OpenNPU
`timescale 1ns/1ps

// ============================================================
// v4-conv-parallel-research -- minimal, standalone synthesis probe:
// does the Xilinx `(* use_dsp = "no" *)` attribute actually force a
// constant 16-bit x ~11-bit multiply onto LUT/carry-chain instead
// of DSP48E1, and if so, what does it cost in LUTs? Deliberately
// NOT touching the already-verified winograd_f23_core.v -- this is
// a throwaway characterization probe, isolated to one multiply.
// ============================================================
module synth_probe_use_dsp_attr (
    input  wire signed [10:0] v,
    output wire signed [26:0] m_dsp,
    output wire signed [26:0] m_nodsp
);
    // a non-power-of-two constant (512 would trivially become a
    // free shift regardless of any directive -- not representative)
    localparam signed [15:0] K = 16'sd214;

    assign m_dsp = K * v;

    (* use_dsp = "no" *) wire signed [26:0] m_nodsp_w;
    assign m_nodsp_w = K * v;
    assign m_nodsp = m_nodsp_w;
endmodule
