# v4_board_area_180 — release record

Status: **released** (2026-10-09, tag `v4-board-area-180`). The one OPEN item
(Quad-SPI timing of the ESP32-S3) is a measurement on the first board.

## Identity

| | |
|---|---|
| Files | `v4_board_area_180.bit`, `v4_board_area_180.bin` (write_cfgmem SPIx1 at 0x0) |
| sha256 | see `README.md` |
| RTL | branch `v4-generic-area`, commit 3d1e425 (+ core MMCM CLKOUT0_DIVIDE_F 7.75, applied on the routed design) |
| Device | XC7A100T-2CSG324 |
| Clocks | 200 MHz LVDS oscillator → MIG 310 MHz (DDR3-620), ui_clk 155.0 MHz; core 180.0 MHz (155.0 × 9 / 7.75); qsclk ≤ 80 MHz from the ESP32-S3 |
| Config | Master SPI x1, CONFIGRATE 33, SPI_FALL_EDGE, COMPRESS, CFGBVS VCCO, CONFIG_VOLTAGE 3.3, PERSIST NO |
| Checkpoint | `~/Develop/FPGA-Neural/bitstreams/v4_board_area_180.dcp` (mikilab, not in git) |

## How it was built (reproducible)

1. `vivado/create_v4_board.tcl` (fresh project, `vivado/mig_200`), RTL 3d1e425
   with `CLKOUT0_DIVIDE_F(7.375)` in `rtl/v4_board_top.v`.
2. Synthesis + implementation as `vivado/impl_v4_board.tcl`
   (Performance_ExplorePostRoutePhysOpt, ExtraTimingOpt placer,
   AggressiveExplore phys_opt/route, KEEP_EQUIVALENT_REGISTERS). Result at
   189.15 MHz: core WNS −0.180 ns.
3. On the routed checkpoint, only `CLKOUT0_DIVIDE_F` of `u_mmcm` set to
   7.75 (`vivado/eco_core_mmcm_divide.tcl` method), `update_timing`,
   `write_bitstream`. No cell moved, no net rerouted.

## Verification evidence

| Check | Result |
|---|---|
| RTL, 7 networks bit-exact (`sim/run_nets.sh`: bench_small, bench_medium, resnet_s, vgg_pool, mfn, unet_s, mlp784) | pass (mfn 519,408 core-test cycles) |
| RTL, Icarus regression (`sim/run_icarus.sh`, 11 benches incl. whole board over Quad-SPI) | 11/11; board MobileFaceNet bit-exact, 515,986 cycles = 2.867 ms at 180 MHz |
| Synthesis: every parameter RAM chunk has its own RAMs and write enable (`vivado/check_param_ram_we.tcl`) | 4,117 RAMs, 0 errors |
| Gate-level netlist, MobileFaceNet pass 1 output tensor (6,272 words) vs golden — design 46d1dbf (this design + a requant change since reverted) | bit-exact |
| Gate-level netlist of THIS synthesis, MobileFaceNet pass 1 output tensor (6,272 words, depthwise included), whole board over Quad-SPI | bit-exact, 0 errors (26,542 cycles for 2 passes) |
| Gate-level netlist of THIS synthesis, bench_small and mlp784 end to end (boot, image and result over Quad-SPI, flash loopback) | bit-exact, 0 errors (10,854 and 9,579 cycles) |
| Gate-level netlist, whole MobileFaceNet (40 passes) | not run (~26 h of Icarus); every layer type is covered above |

## Timing signoff (routed design, `docs/pnr/board/fix/r189/div_O7_750/signoff_*`)

- WNS +0.088 ns (178,397 endpoints, 0 failing), WHS +0.018 ns, pulse width
  +0.264 ns, 0 routing errors, DRC warnings only.
- Per clock: core +0.088, ui_clk ≥ +0.12, qsclk +1.35 (input) / +1.97
  (output), osc_200 ≥ +1.0.
- Power (report_power defaults, 25 °C ambient): 4.74 W, Tj 46.6 °C.

### Quad-SPI pad timing (report_datasheet)

| | min | max |
|---|---|---|
| qio[*] setup / hold to qsclk ↑ at the FPGA pin | — | setup 2.80 ns, hold 1.27 ns |
| qcs_n setup / hold | — | setup 2.77 ns, hold 2.63 ns |
| qsclk ↑ → qio[*] valid at the FPGA pin (clock-to-pad) | 2.49 ns | 8.52 ns |

Budget at 80 MHz (12.5 ns): host → FPGA, the host launches on the falling
edge and the FPGA samples 6.25 ns later: host clock-to-out + board skew
must stay below 6.25 − 2.80 = 3.45 ns. FPGA → host: the FPGA launches one
cycle before the host samples; 12.5 − 8.52 = 3.98 ns remain for both board
flights + the host setup. ESP-IDF states 80 MHz works with IO_MUX pins
when the slave's data valid time is below 12.5 ns
(`input_delay_ns`, ESP-IDF SPI Master "Timing considerations").
**OPEN**: the ESP32-S3 GP-SPI clock-to-out / setup figures are not in the
public datasheet tables found so far; measure qsclk → qio at both ends on
the first board (scope or logic analyzer) at 80 MHz, and set
`input_delay_ns` in `fpga_neural_v4.c` (today 0) to the measured FPGA data
valid time. Fallback: 40 MHz, which doubles every margin.

### Constraint waivers (reviewed)

- **TIMING-18** (qio/qcs_n): input delays are given on the falling edge of
  qsclk, where the ESP32 launches (mode 0); the rising-edge warning does not
  apply.
- **TIMING-47 / TIMING-24**: osc_200 and ui_clk are declared asynchronous
  (set_clock_groups) although both derive from the oscillator; the only
  crossings are the MIG's own temperature monitor / IDELAYCTRL
  synchronizers (V4-B11), 13 paths in report_clock_interaction.
- **CDC-1** (98 "unknown CDC circuitry"): the read data of the async FIFOs
  (`async_fifo.v`, LUTRAM written in one domain, read in the other) into
  their consumers (u_qspi pend/fbw_d/net_base/cw/left, u_stream wr_data_q
  /s_addr/b_next/b_last); valid by construction (Gray pointers, the data is
  read only when the synchronized pointer says it is written), covered by
  the set_max_delay -datapath_only constraints.
- **LUTAR-1**: inside the MIG IP (Xilinx reset synchronizer).
- **SYNTH-9** (1,059 small multipliers in LUTs): intentional (DSPs 228/240).

## Known limits

- Depthwise at 8 MACs (one 16-channel beat every 2 cycles): MobileFaceNet
  +11.8 % cycles vs 16 MACs, which did not fit (272 slices short).
- Previous bitstreams `v4_board_area_189/196` and `v4_board_top_199/189`
  must not be used for depthwise networks (`README.md`).
