# v4 board bitstreams

## Generic accelerator, 195.8 MHz (2026-10-08)

`v4_board_area_196.bit` / `.bin` -- same RTL as v4_board_area_189 (5fce52b),
core MMCM CLKOUT0_DIVIDE_F 7.125: core 195.79 MHz (5.108 ns), ui_clk 155.0
MHz. ECO of the best 199.34 MHz build (Vivado/v4_board_fix8 from-scratch
P&R, then `vivado/eco_postroute_loop.tcl`: phys_opt / route_design loop,
core WNS -0.107 -> -0.014 ns at 199.34 MHz), then ONLY the core MMCM's
CLKOUT0_DIVIDE_F changed on the routed design
(`vivado/eco_core_mmcm_divide.tcl`): 0 cells moved, 0 nets rerouted.
WNS +0.075 ns (173,097 endpoints, 0 failing), WHS +0.030 ns, 0 routing
errors, DRC warnings only (DPIP-1, DPOP-2, PLBUFGOPT-1, REQP-1709 = the
MIG's PLL CLKOUT3 -> BUFH, inherent to the MIG). Reports:
`docs/pnr/board/fix/m196/`. To rebuild from RTL set CLKOUT0_DIVIDE_F
7.125 in rtl/v4_board_top.v (the committed RTL keeps 7.000).
`.bit` sha256 aa8321ab18cf143baefa8e11f47e85116b2bcd4b6b57bf57420e7e07fc984ab7
`.bin` sha256 672320a20e3d5666d57d345063bc75ff72abee6519a9b563035b62042cba4ba7
Checkpoint (not in git): ~/Develop/FPGA-Neural/bitstreams/v4_board_area_196.dcp.
MobileFaceNet 515,968 cycles = 2.635 ms at 195.79 MHz.

## Generic accelerator, depthwise fixed (2026-10-08, branch v4-generic-area)

`v4_board_area_189.bit` / `.bin` -- the FIRST bitstream in which the
depthwise path is really present and its weights are written (every
earlier one had the dw weight RAM optimized away or never written:
`docs/pnr/board/area/netlist_sim/RESULTS.md`). RTL 5fce52b (generic
network support, area cuts, depthwise at 8 MACs, Quad-SPI-only host link,
dw weight RAM inside dw_linebuf_grouped) with CLKOUT0_DIVIDE_F 7.375:
core 189.15 MHz, ui_clk 155.0 MHz, same board as below (one 200 MHz
oscillator, flash pins). Full from-scratch P&R (no ECO), Vivado/v4_board_fix8:
WNS 0.000 ns (172,903 endpoints, 0 failing), WHS +0.020 ns, DRC warnings
only (DPIP-1, DPOP-2, PLBUFGOPT-1). LUT 51,157, slices 15,691/15,850,
BRAM 127.5/135, DSP 228/240. Every parameter RAM's write enable checked
live in the synthesized netlist. Reports: `docs/pnr/board/fix/m189/`.
`.bit` sha256 556257fbce33fc295a69c5a9425ccdf447ddebe808cd9c5b3c7f8e4286a711c5
`.bin` (write_cfgmem SPIx1 at 0x0) sha256 961265de21548db8e179ae08a732215534d8768ffdeadb4df2bf12f37396d4f6
Checkpoint (not in git): ~/Develop/FPGA-Neural/bitstreams/v4_board_area_189.dcp.

**Do not use the two files below for networks with depthwise layers
(MobileFaceNet included): their netlists never wrote the dw weights.**
They also have the old two-port host link (management SPI + Quad-SPI).

## Earlier (pre-generic) builds

Since 2026-10-06 (datasheet rev. 1.3, branch v4-sysclk-200) both files are
for the board with:
- ONE 200 MHz LVDS oscillator on N5/P5 (bank 34, LVDS_25 input,
  DIFF_TERM FALSE + 100 ohm external): IBUFDS -> BUFG = IDELAYCTRL
  reference, -> MMCM x31/5/4 = 310.0 MHz -> MIG (NO_BUFFER); ui_clk
  155.0 MHz. T14/T15 unused.
- config flash on the Master-SPI pins FCS_B L13, D00 K17, D01 K18
  (bank 14 at 3.3 V), CCLK E9; boot options Master SPI x1, CONFIGRATE 33,
  SPI_FALL_EDGE, COMPRESS. Bank 0 at 3.3 V (CFGBVS = VCCO), PERSIST NO.

Both are ECOs of the closed routed designs (`vivado/eco_osc200.tcl` on
the v4-board-*-flashcfg checkpoints, which were `vivado/eco_flash_pins.tcl`
on v4-board-199/189): 4 new cells (MMCM, BUFG, 2 reset LUTs) placed by
hand, 0 existing cells moved, their nets routed. The same change in RTL is
`rtl/v4_board_top.v` + the NO_BUFFER MIG (`vivado/mig_200/`). Reports:
`docs/pnr/board/osc200/`.

`v4_board_top_199.bit` — core 199.29 MHz (MMCM O = 7), WNS +0.004 ns,
WHS +0.011 ns, 0 routing errors, DRC warnings only. 2,970,734 bytes.
sha256 cbdc468ed9cd0c1ebc0cdc3e5e14bce4a3611ed84d6af40d9ede71d6bd180a25.
Checkpoint (not in git): ~/Develop/FPGA-Neural/bitstreams/v4_board_199_osc200.dcp.

`v4_board_top_189.bit` — core 189.15 MHz (MMCM O = 7.375), WNS +0.034 ns,
WHS +0.028 ns. 2,972,478 bytes. sha256
133750f49e032a8fbeb8d6b33e24442628c9a5655b2557a267c25866aa8f3157.
Checkpoint (not in git): ~/Develop/FPGA-Neural/bitstreams/v4_board_189_osc200.dcp.

Earlier builds (in git history):
- tags `v4-board-199-flashcfg` / `v4-board-189-flashcfg`: two
  oscillators (310.078 MHz on N5/P5, 200 MHz on T14/T15), flash on the
  Master-SPI pins;
- tags `v4-board-199` / `v4-board-189`: two oscillators, flash on
  D9/D10/C9, uncompressed.
They do not match the rev. 1.3 board.
