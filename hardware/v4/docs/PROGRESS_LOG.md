# v4 G-esteso — progress log (one entry per verified step)

Target: MobileFaceNet inference 100x faster than ESP32-S3 (248.8 ms,
Espressif ESP-DL) → ≈ 2.49 ms. Every number below is measured unless
explicitly marked as a projection.

---

## V4-S1 (2026-09-28) — depthwise row buffer in BRAM

**Problem.** `g_window_mover_depthwise.v` keeps its 3-row buffer as a
register array read at 9 runtime column offsets per channel per cycle.
OOC synthesis (W=64, CIN=16) mapped it to 24,576 flip-flops: no BRAM has
9 read ports. It also reads memory 1 byte/cycle, so CIN parallel lanes
were starved.

**Change (fork, old module untouched).**
- `rtl/dw_linebuf_stream.v`: streaming 3x3 depthwise. Input = one pixel
  (LANES channels, LANES*8 bits) per beat, raster order. One simple-dual-
  port RAM, MAXW x (2*LANES*8): word[c] = {row r-1, row r-2}; read at c,
  rewritten one cycle later with {pixel, row r-1} (1R+1W). 3x3xLANES
  window shift register, fixed-index taps only. Runtime `cfg_w`, `cfg_h`,
  `cfg_stride2` (stride 1 or 2; padding is streamed in by the feeder).
  Global stall `en = !out_valid | out_ready` gates every register, the RAM
  read and the RAM write.
- `rtl/depthwise_mac3x3_pipe.v`: 3-stage pipelined fork of
  `depthwise_mac3x3.v` (same math/widths). The combinational MAC alone
  gave WNS = -7.223 ns at a 5 ns clock.

**Verification (Icarus).** `sim/tb_dw_linebuf_stream.v`: independent
golden 3x3 depthwise, 48 frames back-to-back on one instance (6 sizes from
3x3 to 20x12, stride 1 and 2, all-(-128) extreme frames), random input
bubbles (up to 60%) and random output back-pressure (up to 70%). Checks
every value, output order/coordinates, coverage and `out_last`.
- LANES=3: 2872 vectors, 0 errors. LANES=16: 2872 vectors, 0 errors.
- Mutation check (the test must fail on a broken DUT): swapped window
  row, wrong write-back row, stall ignored in the pipeline, stride mask
  removed, MAC stall ignored → 7551 / 8616 / 756 / 2638 / 2295 errors.

**Synthesis (Vivado 2026.1, OOC, xc7a100tcsg324-2, LANES=16, MAXW=64,
5 ns clock, maxThreads 2).**

| | old mover (FF rowbuf) | dw_linebuf_stream, comb MAC | dw_linebuf_stream, piped MAC |
|---|---|---|---|
| Row buffer | 24,576 FF (earlier session measurement) | 4 RAMB36 (`lb_reg` 64x256 SDP) | 4 RAMB36 |
| Slice LUT | — | 11,193 | 10,788 |
| Slice FF | — | 1,860 | 5,016 |
| DSP48E1 | 0 | 0 | 0 |
| WNS @ 5 ns | — | -7.223 ns | **+0.567 ns** |

Throughput: 1 pixel (all LANES channels) per cycle, one output per
accepted pixel at stride 1 (input cycles = pixel count in the no-bubble
frames). Post-synthesis OOC only: in-context P&R is step 3.
CPU package temperature during synthesis peaked at 69 °C.

---

## V4-S2a (2026-09-28) — streaming pointwise array (DSP-packed)

**Why not wire `packed_pe_chained.v` directly.** It is a job-based PE:
one neuron x 2 positions per job, activations fetched from DDR3 by its
own `ddr_prefetch_mgr`, and an FSM that drains the whole pipeline after
every neuron (IDLE/LOAD/.../DONE). Fed by the depthwise stream it would
idle for the pipeline depth after every output channel. What is reused
is its datapath, unchanged in its math.

**Change.** `rtl/pw_array_packed.v`: P_CI x P_CO array, one beat per
cycle, no per-neuron drain. Each beat = one (ci tile, co tile) step for
a PAIR of positions sharing all weights; column co sums P_CI products
for A and B; `first`/`last` flags delimit the accumulation. Same packed
formula as `neural_processor_packed.v` / `mac2_dsp_packed.v`
(x1*2^16 + x0, borrow correction on unpack), same raw-product register +
separate unpack stage, same registered balanced adder tree. 2*P_CI*P_CO
MACs per cycle on P_CI*P_CO DSP48E1. Optional `N_DSP_COLS`: the last
P_CO-N_DSP_COLS columns use two plain 8x8 LUT multiplies per cell
instead (same latency, same results), so a 16x16 array fits the part's
240 DSP (224 DSP + 32 LUT cells).

**Bug found on the way (fixed).** First version put the packing add
between the input register and the DSP A port: WNS -1.018 ns at 5 ns
(xa0 -> 3x CARRY4 -> A). Moving the add in front of the register made it
unsigned by accident (an inline sign-extension concatenation makes the
whole expression unsigned, zero-extending x1): 8898 errors in the tb.
Fixed with separate signed wires, as in the v3 original.

**Verification (Icarus).** `sim/tb_pw_array_packed.v`: independent
integer dot-product golden, 3000 accumulation groups per config, random
group length 1-6 tiles, back-to-back groups, random bubbles (0/25/60 %),
all -128 and ±128/127 extreme groups; results checked in order.
- P_CI/P_CO/NDSP = 4/3/3, 4/3/1, 4/3/0, 1/2/2, 8/5/2, 16/14/14,
  16/16/14: all 3000/3000, 0 errors.
- Mutations: borrow correction removed → 8373 errors; `first` ignored →
  9000; pipeline alignment off by one → 9000.

**Synthesis (Vivado 2026.1, OOC, xc7a100tcsg324-2, 5 ns clock).**

| P_CI x P_CO | DSP48E1 | LUT | FF | WNS @ 5 ns |
|---|---|---|---|---|
| 16 x 4 | 64 | 3,144 | 5,199 | +2.404 ns |
| 16 x 14 | 224 (93 %) | 10,989 | 18,164 | +2.404 ns |
| 16 x 16 (14 DSP + 2 LUT cols) | — | — | — | not run: CPU hit 88 °C, synthesis killed |

Critical path (both): last adder-tree level -> accumulator, 9 levels
(8 CARRY4), 2.62 ns. Post-synthesis OOC only.

---

## V4-S2b (2026-09-28) — depthwise over all channel groups + requant

Icarus only (Vivado paused after the 88 °C event).

- `rtl/dw_linebuf_grouped.v` (fork of `dw_linebuf_stream.v`): input
  beats in (row, col, group) order, `cfg_ng` groups of LANES channels,
  so the depthwise emits every group of position p before p+1 -- what the
  1x1 conv needs. Line buffer word (c*ng + g) in one SDP BRAM, addressed
  by a running counter (no runtime multiply). Window columns c-1 / c-2
  come from a small history RAM indexed by g (column c-1 of group g is
  exactly ng beats older). Weights are requested by group (`wd_g`).
  Test `sim/tb_dw_linebuf_grouped.v` (fork of the S1 test, per-channel
  golden, NG = 1..MAXNG cycling per frame, bubbles + back-pressure):
  LANES/MAXNG = 3/4: 6164 beats, 16/4: 6164, 2/1: 2872, 4/7: 11187 --
  0 errors. Mutations (history write, weight group one stage early, line
  buffer address wrap, out_last group check) → 18492 / 11556 / 17169 /
  202 errors.
- `rtl/requant_act.v`: s = acc + bias; q = sat8(round(s >>> shift));
  activation on the INT8 value (none / ReLU / PReLU with int8 alpha and
  its own shift), power-of-two scales as in ESP-DL. Settings and alpha
  travel down the pipe with the data (can change every beat). Test
  `sim/tb_requant_act.v` (64-bit integer golden, all shifts, extremes,
  random stalls): 34901 x 4 lanes, 0 errors. Mutations (alpha one stage
  early, rounding removed, ReLU removed) → 12370 / 24971 / 16885.

---

## V4-S2c (2026-09-28) — depthwise -> pointwise fused engine, end to end

`rtl/dwpw_engine.v`: dw_linebuf_grouped (P=16 channels/beat) ->
requant_act -> pair vector buffer (2 slots x {A,B} x ng words, the only
place a depthwise result lives) -> sequencer (for each pair: nco x ng
array beats back to back, no drain between tiles or pairs) ->
pw_array_packed -> requant_act -> output tiles (P_CO channels of 2
positions). pw weights from an external synchronous RAM (word cot*ng+g),
small parameters from combinational lookups -- the memory architecture
is decided in step 3.

**Verification.** `sim/tb_dwpw_engine.v`: independent integer golden
(per-channel depthwise, requant, full dot products, requant), checks
every output tile, exact coverage, `o_b_valid` for odd position counts,
`done`. Random layers (size, stride 1/2, ng, nco, all 3 activations,
input bubbles).
- P/P_CO = 4/3: 24 layers, 1197 tiles, 0 errors.
- P/P_CO/NDSP = 16/16/14 (the real array): 10 layers, 445 tiles, 0 errors.
- Mutations (odd last position, requant params from the wrong tag,
  `first` on every beat, depthwise back-pressure ignored) → 8 / 2459 /
  2508 / 2068 errors.

**Real MobileFaceNet shapes (16x16 array, bit-exact vs golden, cycles
measured start -> done):**

| layer (dw 3x3 -> 1x1 project) | cycles | ideal pw cycles | pw utilization |
|---|---|---|---|
| 14x14, dw 256 s1 -> 128 | 13,144 | 12,544 | 95.4 % |
| 56x56 -> 28x28, dw 128 s2 -> 64 | 26,914 | 12,544 | 46.6 % (input-bound: 26,912 input beats) |

The stride-2 case is limited by the depthwise input rate (one 16-channel
beat per cycle, 4 input pixels per output). In the full bottleneck the
expand 1x1 (which produces that input) needs 50,176 array cycles for
this block, so the array stays the bottleneck once expand is fused in.

---

## V4-M1 (2026-09-28) — whole-network cycle model, calibrated on RTL

`model/mfn_cycle_model.py` (output in `model/mfn_cycle_model.out`):
MobileFaceNet layer by layer (Chen et al. 2018 table), cycle rules of
`dwpw_engine.v` that reproduce both RTL-measured layers exactly (13,144
and 26,914 cycles). Total 221.0 M MACs (211.0 M on the array, 10.0 M on
the depthwise lanes) -- matches the paper's ~221 M.

- Schedule A (layer by layer, today's engine; conv1 im2col, pw-only
  mode, GDConv and the final linear layer are PROJECTED, not built):
  **442,284 cycles**, array utilization 93.2 %.
- Schedule B (expand 1x1 fused into the bottleneck, projection):
  419,280 cycles, 98.3 %.
- 100x (2.488 ms) needs **Fmax >= 177.8 MHz** with A, >= 168.5 MHz with
  B. At 200 MHz: A = 2.211 ms (112.5x), B = 2.096 ms (118.7x). At the
  v3 system's 155 MHz: A = 2.853 ms (87.2x).

Not in the model yet: pw weights assumed double-buffered and prefetched
from DDR3 during the previous layer (1 MB total vs ~2.48 GB/s measured
32-bit channel = ~0.4 ms, hidden only if overlapped); feature-map BRAM
budget; in-context Fmax (step 3).

---

## V4-S2d (2026-09-28) — pointwise-only mode (expand 1x1, conv1 via im2col)

`dwpw_engine.v` gains `cfg_pw_only`: input beats of an unpadded map go
straight into the pair vector buffer (depthwise bypassed). Test extended
(every 5th random layer pw-only; `TB_FPWO` for fixed shapes): 24 random
layers incl. 4 pw-only, 1376 tiles, 0 errors. Real shapes, 16x16 array,
bit-exact:

| layer | cycles | ideal | utilization |
|---|---|---|---|
| 28x28 expand 64->128 | 12,568 | 12,544 | 99.8 % |
| 7x7 conv1x1 128->512 | 6,432 | 6,400 | 99.5 % |

Model updated with the measured pw-only overhead (2*ng + 16): schedule A
= 442,314 cycles; 5 of the 6 distinct layer kinds are now RTL-measured
rules (only GDConv and the final 512->128 linear remain projections;
conv1 uses the pw-only rule, its im2col feeder is not built).

---

## V4-S3a (2026-09-28) — whole MobileFaceNet runs on the RTL, bit-exact

New: `rtl/v4_core.v` (descriptor-driven layer sequencer), `rtl/fmap_mem.v`
(3 banks x 8192 x 128 bit = 384 KB, one read port per bank shared by the
feeder and the residual reader, conflict flag), `rtl/fmap_feeder.v`
(padded (row,col,group) stream, row windows for banding, latency-2 BRAM
reads, credit FIFO), `rtl/tile_writer.v` (tile -> 2 words, residual
saturating add). `model/gen_mfn.c`: MobileFaceNet INT8 golden in C with
the RTL's exact arithmetic + all memory images + 38 pass descriptors
(conv1 as pw-only on im2col input, dw1+b1.expand and b1.dw+project run
in 4 row bands so the 56x56x128 tensor never exists whole, residuals,
X/Y ping-pong across banks).

`sim/tb_v4_core_mfn.v`: runs all 38 passes back to back in one
simulation and compares every checked pass's whole output tensor with
the golden: **35 passes checked, 132,664 words, 0 errors; TOTAL 451,287
cycles** (conv1 -> conv1x1 512, everything except GDConv 7x7 and the
final 512->128 linear). Per-pass log: `docs/mfn_rtl_run.log`.

Bug found by this test (fixed): the sequencer could take the PREVIOUS
layer's engine `done` (it pulses every other cycle while idle) in the
first cycle of the next layer; pass 33 "finished" in 2 cycles and every
later tensor mismatched. `done` is now ignored while `go` is high.

vs the model (schedule A 442,314): +9k cycles, from the banded b1 (4
passes each: dw1+expand 54,920 vs 50,728; b1.dw 4x7,018 input-bound)
and small per-pass sequencer/feeder overheads.

---

## V4-S3b (2026-09-28) — first synthesis of the whole core, critical paths cut

Fan fixed by Michele (fan_min 2800), Vivado resumed; package peaked at
80-81 °C with maxThreads 2.

- OOC `pw_array_packed` 16x16 (14 DSP + 2 LUT columns): 224 DSP, 16,622
  LUT, 23,189 FF, WNS +0.662 ns at 5 ns.
- `v4_core_top` (v4_core + 8-bit host bus; on-chip memory plan: pw
  weight ring 512 x 2048 bit, 32-entry dw/pw param buffers, 3 x 128 KB
  feature map), synthesis: 45,268 LUT (71 %, 3,532 as memory), 32,255 FF,
  **132/135 BRAM**, 225 DSP; **WNS -7.153 ns** at 5 ns. Failing groups:
  feeder start-address multiply (-6.45), requant PReLU cycle (-3.5),
  descriptor base -> weight BRAM address (-1.56), requant shift+saturate
  (-0.89), weight address multiply (-0.74), dw weight lookup -> MAC
  (-0.43), writer address (-0.23), pw requant param lookup (-0.12).
- Fixes: requant_act 3 -> 5 stages; feeder start address in 2 registered
  steps + one more sequencer state (S_PREP); engine weight address is now
  a register counting from w_base; dw weights looked up one stage early
  and registered; writer address in its own stage; pw requant params
  registered in v4_core (valid because results are >= ng >= 2 apart).
- Re-verified: requant 34901x4 vectors, dw grouped 3 configs, engine 34
  random layers, **whole MobileFaceNet 35/35 tensors bit-exact, 451,483
  cycles** (+196 from the added stages).

---

## V4-S3c (2026-09-28) — GDConv 7x7 + final linear: the WHOLE network in RTL

- `rtl/gdconv_unit.v`: global depthwise 7x7 (7x7x512 -> 1x1x512). Fed
  by the same feeder (pointwise order), 16 LUT multipliers, per-group
  accumulators in distributed RAM (read-modify-write, groups rotate so
  no hazard for ng >= 3), weights 16 bytes/beat read from the pw weight
  memory (16 beats per 2048-bit word, registered chunk select), requant
  per group, results written as tiles by tile_writer. New descriptor bit
  [172].
- The final linear 512->128 is a pw-only pass on a 1x1 map (engine,
  unchanged).
- `gen_mfn.c` now emits 40 passes and the final 128-value embedding
  (`golden_ref.txt`).

**Whole MobileFaceNet, input image -> 128-value embedding, in one RTL
simulation: 37 output tensors checked (132,704 words), 0 errors;
TOTAL 453,429 cycles** (GDConv 1,622, linear 316). 100x = 182.2 MHz.

---

## V4-S3d (2026-09-28) — first in-context place & route: 150 MHz; routing fixes

`v4_core_top` (whole core, on-chip memory plan, 8-bit host bus; no
MIG/SPI yet), Vivado 2026.1, xc7a100tcsg324-2, **maxThreads 1** (2
threads peaked at 86 °C and were stopped; 1 thread peaked at 74 °C).
Scripts: `constr/pr_core.tcl`, `constr/v4_core_top.xdc`.

**P&R #1 (commit 50667a2): WNS -1.653 ns at 5 ns -> Fmax 150.3 MHz**;
27,790 failing endpoints; 34,068 FF, 132.5/135 BRAM, 225 DSP. With
453,429 cycles: 3.02 ms = 82x. Paths are route-dominated (75-90 % of
the delay is wire): the core is spread over the whole die by the BRAM
(98 %). Worst groups: descriptor -> feeder start-address DSP (-1.60),
depthwise stall chain rq_en (fanout 2,164, 5 LUT levels into the feeder
FIFO, -1.45), feeder pad flag (fanout 128) into the FIFO LUTRAM (-1.37),
GDConv first-flag (fanout 128, -1.35), host registers -> memories
(-1.34), descriptor -> engine slot logic (-1.33), writer FIFO pointer
(-1.33).

Fixes (all behaviour-preserving):
- depthwise -> requant -> vector buffer now fully registered flow
  control: dw output into a 4-entry FIFO (dw_ready = its count), a
  never-stalling requant fed by credit (16-entry FIFO after it), params
  looked up from a registered group index and registered;
- engine and writer register their static configuration locally;
- feeder start address comes precomputed in the descriptor ([187:173]),
  no multiplier;
- max_fanout on the feeder pad flag, GDConv first flag, writer FIFO
  pointer;
- host strobes delayed one cycle after address/data (2-cycle paths,
  set_multicycle_path).

Re-verified: engine random layers 1563 tiles 0 errors (+2 new mutations
on the FIFO credits caught: 610 / 1431 errors); **whole MobileFaceNet
37/37 tensors bit-exact, 453,176 cycles**.

---

## V4-S3e (2026-09-28) — P&R #2: 157 MHz; second round of pipelining

**P&R #2 (commit 69d9c1a): WNS -1.381 ns -> 156.7 MHz** (2.89 ms, 86x),
17,520 failing endpoints, peak CPU 84 °C (1 thread). Worst groups, again
route-dominated: requant settings registers of the GDConv unit merged by
synthesis with the engine's (same descriptor source) and shipped across
the die (-1.12), feature-map bank mux (-1.03), tag -> pw requant params
turned into SRLs absorbing the registered lookup (-1.02), vector-buffer
write (-0.99), writer input (-0.98/-0.90), weight BRAMs -> 224 DSPs
(-0.91), host multicycle constraint not applied (read before synthesis).

Fixes: register after the feature-map bank mux (read latency 3; feeder
and writer pipelines extended); weight read gets one more register and
the engine a W_LAT = 2 operand alignment; writer input register; vector
buffer RAM write registered; shreg_extract = "no" on requant settings
and the pw param register; GDConv unit registers its own config;
`-keep_equivalent_registers`; host multicycle XDC read after synthesis
(`constr/v4_core_top_post.xdc`).

Re-verified: engine random layers 0 errors, requant 34,899 x 4, **whole
MobileFaceNet 37/37 tensors bit-exact, 453,336 cycles**.

---

## V4-S3f (2026-09-29) — P&R #3: 162 MHz; third round

CPU capped by Michele at 2.4 GHz (`cpupower frequency-set -u 2.4GHz`):
1-thread P&R peak 54 °C (was 84-85 °C; one uncapped attempt was killed
at 85 °C during synthesis).

**P&R #3 (commit 0352f4e): WNS -1.156 ns -> 162.4 MHz** (2.79 ms, 89x),
4,963 failing endpoints (was 17,520), 42,508 FF. Worst: the last requant
stage (rounding shift + saturate + activation select, 9 levels) in all
three requant instances (-1.16 / -1.09 / -1.05), GDConv 8x8 LUT
multiply (-0.81), feeder rd_en -> 32 BRAMs (-0.66), tag -> pw param
register (-0.63), bank mux select (-0.63), GDConv config -> requant
(-0.61), GDConv accumulator read-modify-write (-0.58).

Fixes: requant_act 5 -> 7 stages (bias add, shift, saturate, product,
rounding shift, select each alone; static rounding constants
registered) with BIAS_LAT = 1 option (params sampled a cycle after the
accumulators); pw/GDConv param key registered then lookup registered;
GDConv products split in nibbles with a registered accumulator read;
fmap_mem input registers (read latency 4, feeder/writer/host pipelines
extended); max_fanout on the bank selects. Bug caught on the way by the
full-network test: the first GDConv split combined the products one
stage too late (pass 38/39 mismatched), fixed.

Re-verified: requant 34,897 x 4 (+ a rounding mutation caught, 1586
errors), engine random layers, **whole MobileFaceNet 37/37 tensors
bit-exact, 453,579 cycles**. P&R #4 adds ExtraTimingOpt placement and
AggressiveExplore phys_opt/route directives.

---

## V4-S3g (2026-09-29) — **P&R #4: timing-clean at 200 MHz**

`v4_core_top` at commit 9be43d3, Vivado 2026.1, xc7a100tcsg324-2, 1
thread, CPU capped at 2.4 GHz (peak 53 °C). Directives: place
ExtraTimingOpt, phys_opt AggressiveExplore (pre and post route), route
AggressiveExplore (`constr/pr_core.tcl`).

**WNS +0.048 ns, TNS 0, WHS +0.035 ns, 0 failing endpoints out of
90,837: all constraints met at 5.000 ns (200 MHz).** Reports:
`docs/pnr/v4_core_top_pr4_timing.rpt`, `docs/pnr/v4_core_top_pr4_util.rpt`.

| resource | used | of | % |
|---|---|---|---|
| Slice LUT | 39,134 | 63,400 | 61.7 |
| LUT as memory | 1,975 | 19,000 | 10.4 |
| Slice FF | 47,816 | 126,800 | 37.7 |
| Block RAM tile | 132.5 | 135 | 98.1 |
| DSP48E1 | 224 | 240 | 93.3 |

History: 150.3 -> 156.7 -> 162.4 -> **>= 200 MHz**.

**MobileFaceNet timing on this core: 453,579 measured cycles / 200 MHz
= 2.268 ms vs 248.8 ms on the ESP32-S3 (ESP-DL) = 109.7x.**

Scope of this number (not yet included): the core's compute from the
first input word to the 128-value embedding, all weights/parameters
already on chip. Not included: loading the input image (37 KB) and
reading the embedding over SPI, the DDR3 weight streaming into the
128 KB on-chip ring (needs a prefetch block that is not built; ~854 KB
of pw weights per inference = ~0.34 ms at the measured 2.48 GB/s,
hidden only if overlapped with compute), the conv1 im2col feeder, MIG
and SPI in the same P&R.

---

## V4-S4a (2026-09-29) — parameters streamed from DDR3, overlapped

`rtl/param_loader.v`: per pass, 4 read requests (pw weights, dw weights,
dw requant, pw requant) on a generic DDR request/stream port; each
128-bit word goes to its chunk of the on-chip memories. `v4_core`:
double buffers by pass parity (weights 2 x 256 x 2048 bit = the same
128 KB ring, dw/pw params 2 x 32 rows), load descriptor per pass (desc
chunk 2), sequencer starts loading pass k+1 when pass k starts and
waits (S_WAITL, counted) only if the load is not finished.
`gen_mfn.c` emits `ddr.hex` (1,001 KB: all pw/dw weights and requant
params) and `ldesc.hex`.

TB DDR3 **model** (not the MIG): 60-cycle first-word latency, then
5/8 word (128 bit) per core cycle = 2.0 GB/s at 200 MHz (80 % of the
board's 32-bit DDR3-620 peak, 2.48 GB/s).

Result: **whole MobileFaceNet bit-exact (37/37 tensors) with every
parameter streamed from the DDR model: 463,839 cycles, of which 10,220
waiting for loads** (67,836 words streamed; banded passes reload their
small weights). At the P&R-closed 200 MHz: **2.319 ms = 107.3x**.

---

## V4-S4b (2026-09-29) — DDR bandwidth sensitivity; im2col on the FPGA

**Sensitivity** (same run, DDR model at half bandwidth, 5/16 word/cycle
= 1.0 GB/s at 200 MHz): whole network bit-exact, 488,813 cycles, 35,194
waiting for loads -> 2.444 ms = **101.8x**. (2.0 GB/s: 463,839 ->
2.319 ms = 107.3x.)

**im2col**: `rtl/im2col_feeder.v` turns the raw 112x112x3 image (rows of
21 words, 37.6 KB) into conv1's 27(+5)-byte vectors on the fly: three
byte shift registers (one per kernel row, 3 zero bytes of left padding)
shifted by a fixed 6 bytes per output position -- no runtime byte
multiplexers; row 2i+1 is kept (unshifted copy) as row kr = 0 of the
next output row, so 2 image rows are read per output row. Unit test
`sim/tb_im2col_feeder.v` (2 random images, latency-4 memory model,
random back-pressure): 12,544 beats, 0 errors; mutations (row reuse,
shift amount, read alignment) -> 6160 / 6160 / 666 errors. In v4_core
descriptor bit [188] selects it for the conv1 pass; gen_mfn.c now puts
the raw image in the feature-map memory.

**Whole MobileFaceNet from the raw image, all parameters streamed from
the DDR model (2.0 GB/s): 37/37 tensors bit-exact, 466,191 cycles**
(conv1 14,937 = +2,352 for the row loads, not overlapped yet; 10,220
waiting for parameters) -> **2.331 ms at 200 MHz = 106.7x**.

---

## V4-S4c (2026-09-29) — im2col v2 (RAM-based, overlapped)

The first im2col (byte shift registers of whole rows) synthesized to
+17k LUT (core at 57,430 LUT = 90.6 %); that P&R was cancelled.
Version 2: 5-slot distributed row RAM (row r in slot r % 5), rows
re-aligned by the 3 padding bytes on the way in (fixed byte shift), the
loader runs ahead of the emitter (rows up to 2i+3), each position reads
2 adjacent words per kernel row and byte-shifts them by 6j mod 16. Unit
test 12,544 beats 0 errors; mutations (tail word, kr=0 slot, padding,
loader running too far ahead) -> 224 / 6160 / 224 / 10863 errors.

**Whole network from the raw image, parameters from the 2.0 GB/s DDR
model: 37/37 bit-exact, 463,884 cycles** (conv1 12,630: row loads now
overlapped) -> **2.319 ms at 200 MHz = 107.3x**.

---

## V4-S4d (2026-09-29) — im2col v3 + loader: timing-driven fixes before P&R #5

Synthesis of the streaming core (loader + im2col v2): 47,718 LUT (75 %),
**WNS -8.151 ns**: im2col output row -> (x2)%5 slot / 6*oj offset ->
row RAM -> 16-way byte shifter -> vector, all in one cycle; also the
loader's groups*9 segment length feeding the request logic (-0.48).
im2col v3: slots and byte offset kept in registers (incremental),
3-stage emitter (registered reads, registered shift, beats), fetch of
the next position overlapped with the beats. Loader: segment length and
address registered in their own state. im2col unit test 0 errors
(mutations: loader too far ahead 11006, byte offset step 12320, tail
word 224). **Whole network bit-exact: 463,905 cycles** (10,240 waiting
for parameters) -> 2.320 ms at 200 MHz = 107.2x.

---

## V4-S4e (2026-09-29) — P&R #5 (streaming core): 185 MHz; fourth round

**P&R #5** (commit of V4-S4d: loader + im2col v3 + 64-row param
buffers): **WNS -0.414 ns -> 184.7 MHz**, 3,986 failing endpoints, all
between -0.41 and -0.3 ns; 46,867 LUT (73.9 %), 59,103 FF, 132.5 BRAM.
With 463,905 cycles: 2.512 ms = 99.0x (100x needs 186.5 MHz).
Report: `docs/pnr/v4_core_top_pr5_timing.rpt`. Congestion-driven:
writer tile->offset (-0.41), loader sel -> param LUTRAM write enables
(-0.40), weight address counter (-0.39), im2col row-RAM write (-0.38),
config subtract -> pw-only counters (-0.38), requant saturation and
PReLU multiply (-0.37/-0.36), fmap address fanout (-0.35).

Fixes: writer position add in its own stage; memory-write port
registered with the (sel, chunk) decode done once; im2col row-RAM
write registered (rows_done follows the real write); engine and
depthwise keep registered minus-one copies of the static config;
requant_act 7 -> 8 stages (saturation flags registered, PReLU product
as two nibble products); max_fanout on fmap addresses; host strobes
held >= 2 cycles (multicycle).

Re-verified: requant 34,896 x 4, im2col unit test, engine random
layers, **whole network bit-exact: 464,018 cycles** (10,231 waiting).

---

## V4-S4f (2026-09-29) — **P&R #6: the complete streaming core closes at 200 MHz**

`v4_core_top` at 52051a7 (DDR3 parameter streaming + im2col +
fourth pipelining round), 1 thread, CPU capped 2.4 GHz (peak 50 °C).
**WNS +0.004 ns, WHS +0.033 ns, 0 failing endpoints of 132,022: all
constraints met at 5.000 ns.** 45,753 LUT (72.2 %), 60,934 FF (48.1 %),
132.5/135 BRAM, 224/240 DSP. Reports: `docs/pnr/v4_core_top_pr6_*.rpt`.

**MobileFaceNet, raw 112x112x3 image -> 128-value embedding, every
parameter streamed from DDR3 (2.0 GB/s model): 464,018 measured cycles
/ 200 MHz = 2.320 ms vs 248.8 ms on the ESP32-S3 = 107.2x.**
(At half the DDR bandwidth, 1.0 GB/s: ~2.44 ms, ~102x.)

Still outside this number: SPI transfer of the input image and of the
result, and the MIG/SPI in the same P&R (the DDR3 bandwidth is modelled).

---

# Board-ready version (V4-B)

Plan: same board, pins and SPI protocol as v3 chained (spi_host_bridge_
v3_chained.v reused unmodified: WRITE_MEM/READ_MEM/registers/flash);
the ESP32 writes weights+descriptors (once) and the image into DDR3, a
boot block copies them on chip, runs the core and writes the embedding
and the on-board cycle count back to DDR3. Core at ~199.3 MHz from an
MMCM on ui_clk (155 MHz), async FIFOs between the domains, a pipelined
DDR3 reader on the MIG app port (the v3 adapter is sequential).

## V4-B1 (2026-09-29) — async FIFO, pipelined DDR3 streamer

- `rtl/async_fifo.v`: Gray-pointer dual-clock FIFO, FWFT, write-side
  count. `sim/tb_async_fifo.v`: 20,000 words across 5.0/6.45 ns clocks
  both ways, depths 4/16/64, random enables: 0 errors; removing `full`
  -> overflow caught (timeout). (Gray vs binary pointer crossing is a
  metastability property RTL simulation cannot see.)
- `rtl/v4_ddr_stream.v`: MIG app master, read commands back to back (1
  burst = 2 x 128-bit words per 2 ui_clk = the channel peak) with FIFO
  credit, odd/even word alignment, masked single-word writes, and the
  app-port ownership mux with the unchanged v3 `mig_native_adapter.v`
  (host path). `sim/tb_v4_ddr_stream.v` (behavioral MIG app model:
  in-order 2-beat reads, random app_rdy/wdf_rdy and latency; real v3
  adapter as competing master): 300 read jobs (1..300 words, odd/even
  starts), 100 streamer writes (neighbour half untouched), 75 host
  write+read-backs: 0 errors; 0.77 word/ui_clk sustained against that
  model (its random stalls, not the real MIG). Mutations: alignment
  skip, write mask, FIFO credit -> caught.

## V4-B2 (2026-09-29) — boot controller + real board top, whole board simulated

- `rtl/v4_boot.v`: header-driven boot (magic "VNN4"): reads the boot
  header, the descriptor table (3 words/pass) and the raw image from
  DDR3 into the core, runs it (the core's loader owns the DDR read
  port during the run, its addresses offset by the header's param base),
  copies the output tensor and a statistics word (cycles, cycles waiting
  for parameters, error, magic) back to DDR3.
- `rtl/v4_board_top.v`: same pins as v3's chained top; MIG, the
  UNMODIFIED v3 spi_host_bridge_v3_chained / host_mem_bridge /
  mig_native_adapter / flash_spi_master; core clock from an MMCME2_BASE
  on ui_clk (M 9, D 1, O 7 -> 199.34 MHz); start/done/busy/error and
  the header address crossed with toggle/2-flop synchronizers, DDR
  traffic through three async FIFOs; the v4 streamer owns the MIG app
  port, handing it to the host adapter only between its own jobs.
  REG 0x04 = header address, CONTROL bit1 = start, STATUS bit4 = done.
- `gen_mfn.c` also writes `ddr_full.hex` (header @16, 40x3 descriptor
  words @64, raw image @256, parameter image @4096, result @80000).

**Whole-board simulation** (`sim/tb_v4_board_top.v`, Icarus, two
unrelated clocks, the MIG replaced by `sim/mig_7series_0_stub.v` -- a
behavioral app-port model, NOT the real controller): over SPI the bench
writes NETWORK_BASE, pulses start, polls STATUS until done, READ_MEMs a
result word. **Embedding in DDR3 bit-exact; core cycles measured by the
board itself 460,673 (6,886 waiting for parameters) = 2.311 ms at 199.34
MHz; host-observed start -> done 2.337 ms (includes boot).** First run
found a bench bug: the SPI master's SCLK high phase (10 ns) was shorter
than the v3 bridge's oversampling needs -- one MISO bit wrong; at 10 MHz
with 30 ns phases all correct. (SCLK limit of the v3 bridge: ~20 MHz.)

## V4-B3 (2026-09-29) — Vivado project, first real-MIG simulation

- `vivado/create_v4_board.tcl`: builds a fresh project (not committed,
  e.g. `Vivado/v4_board`) -- imports the board's MIG configuration
  (xci + mig_a.prj) from the v3 project without touching it, adds all
  RTL / constraints (`constr/v4_board_top.xdc`: v3 pins; ui_clk_o and
  init_calib_complete are no longer top-level ports because they have
  no package pin on the PCB) / sim sources by reference, Micron DDR3
  model + wiredly.v from the MIG example design.
- `sim/tb_v4_board_xsim.v`: the REAL MIG + two Micron x16 DDR3 models;
  over real SPI: WRITE_MEM header + descriptor table, NETWORK_BASE,
  start, STATUS polling, READ_MEM of the statistics word. (Parameters
  and image not loaded: timing is data-independent.)
- 3-pass run: calibration, SPI, boot through the pipelined streamer
  (descriptors read back correctly from the real DDR3), 3 passes: 33,058
  core cycles, 289 waiting for parameters -- consistent with the stub.
- **Real finding (v3 bridge)**: a multi-word READ_MEM at 10 MHz SCLK
  corrupts the high bits of every word after the first (0x344E4E56 read
  as 0x144E0E56): only the first word has the EXP-0117 early-read
  margin; later words are latched before the real DDR3 read returns.
  Firmware rule: read results one halfword per READ_MEM transaction (or
  clock READ_MEM slower). WRITE_MEM is not affected.

## V4-B4 (2026-09-29) — fast Quad-SPI data port (clocked by QSCLK)

The v3 bridge oversamples SCLK with ui_clk (<= ~20 MHz; the image would
take ~15 ms per inference). Michele is designing a castellated module,
ESP32 side free, so the data path gets its own port and the v3 bridge
stays for registers/flash/commands.
Bank-15 check (Vivado package query): A15 (today's SCLK) is NOT clock
capable. Proposed data-port pins, bank 15 byte group T1: QSCLK D15
(IO_L12P_T1_MRCC_15), QCS_N C15, QIO0-3 A13 A14 B18 A18.

`rtl/qspi_data_port.v`: front end clocked directly by QSCLK (mode 0,
all phases on 4 lines: cmd 0x1A write / 0x2A read, 48-bit address =
{W, len}, 64 dummy clocks on reads, data), header / write data / read
data through async FIFOs, ui_clk side moving 256-bit bursts on the v3
memory-controller contract (behind mig_native_adapter.v). Three bugs
found by its unit test and fixed: (1) the async reset only fires on a
rising QCS_N, so the first transaction after power-on was lost -> flops
get power-on values; (2) QSCLK stops right after the last nibble, so a
registered FIFO write enable never reached the FIFO -> write enables
are combinational on the sampling edge; (3) read words were popped one
nibble early.
`sim/tb_qspi_data_port.v` (ESP32-like QSPI master at 80 MHz, memory
model with random latency): 200 write + read-back transactions, 3,955
words, 0 errors, **38.9 MB/s on the wire** (image = 37.6 KB -> ~0.97
ms). Mutations (dummy count, pop timing, write mask) caught.

## V4-B5 (2026-09-29) — Quad-SPI port in the board top

`v4_board_top.v`: new pins qsclk / qcs_n / qio[3:0] (BUFG on QSCLK,
IOBUFs), an owner arbiter on the v3 adapter between host_mem_bridge
(16-bit SPI path) and the QSPI port (both wait for their grant), XDC
with the proposed pins and QSCLK constraints. Whole-board Icarus run
now sends the raw image over the QSPI data port (like the ESP32 per
inference) and reads the embedding + statistics back over it:
**image 37,632 bytes in 0.941 ms; embedding bit-exact; core 460,683
cycles = 2.311 ms; host start -> done 2.337 ms.** Per inference:
~0.94 ms image + ~2.34 ms run; with the next image written while the
current one computes (two headers / image buffers), throughput is set
by the run: ~427 inferences/s.

## V4-B6 (2026-09-29) — whole network on the real MIG + Micron DDR3 models

`sim/tb_v4_board_xsim.v` with `N_PASS=40` in xsim (real MIG IP from the
v3 configuration, two Micron x16 models = 32-bit channel, real
calibration): model loaded into DDR3, start, done. **40 passes, core
460,617 cycles (6,830 waiting for parameters from DDR3) = 2.311 ms at
199.34 MHz; host start -> done 2.342 ms; STATUS done, no error, stats
magic OK.** Same cycle count as the Icarus DDR model (460,683) within
0.02%. This bench checks completion and statistics only; the embedding
bit-exactness is checked by the Icarus whole-board run (V4-B5), not
here. Simulation took ~3 h of CPU.

## V4-B7 (2026-09-30) — whole-board P&R and first bitstream: 189.20 MHz

Real in-context P&R of `v4_board_top` (MIG + v3 SPI bridge + QSPI port +
boot + core), Vivado 2026.1, xc7a100tcsg324-2, one thread.

| Run | Change | core_clk WNS @199.34 MHz | QSPI (80 MHz) |
|---|---|---|---|
| 1 | first board top, default project flow | -0.777 ns (11,321 endpoints) | -6.060 ns |
| 2 | QSPI launch on the rising edge from IOB flops; core host port registered; core reset tree; core-signoff flow (keep_equivalent_registers, ExtraTimingOpt, AggressiveExplore) | -1.485 ns | +1.064 ns |
| 3 | descriptor tables ram_style distributed (ignored: still flops), fanout limits | placement failed | - |
| 4 | load-descriptor table with ONE registered read address -> LUTRAM (synth 46,892 LUT / 53,425 FF, was 49,456 / 61,582) | **-0.235 ns** | +1.163 ns |

Run 1/2 failing endpoints were classified by start/end cell (Tcl over
get_timing_paths): host port -> descriptor flops, im2col row-RAM write
port, reset fanout, then chip-wide route length (82% LUT, 98% BRAM).

Run 4 routing re-timed with the MMCM at O = 7.375 (same placement and
routing, only the MMCM divider changed): **core clock 189.20 MHz (5.285
ns), WNS +0.033 ns, WHS +0.028 ns, 0 failing endpoints, all user
constraints met, DRC clean**; bitstream written (sha256 dcf8ffa7...).
Utilization: 50,098 LUT (79.0%), 60,734 FF, 132.5/135 BRAM, 224 DSP.
RTL updated to O = 7.375. Reports in `docs/pnr/board/`.

Speed at 189.20 MHz: 460,617 core cycles (V4-B6, real MIG) = **2.435 ms =
102.2x** vs ESP32-S3 (248.8 ms). The host start -> done time at 189 MHz
is not simulated yet (at 199 MHz it was ~0.03 ms above the core time).

## V4-B8 (2026-09-30) — whole board closed at 199.34 MHz

Fourth-run residue at 199.34 MHz was 534 endpoints in three classes:
im2col `rows_done` -> compare -> CE of the 768 f_d flops (-0.235 ns),
`li` -> descriptor LUTRAM -> `d` (-0.21 ns), DDR read FIFO Gray compare
-> empty -> boot header enables (-0.1 ns). Fixes: registered
`rows_ready` (forced low on start and after `need` grows), pass
descriptor read registered every cycle (S_WAITL guarantees >= 1 cycle),
one register stage after the read-data FIFO (routing decision
registered with the word). im2col unit test, core (37 passes, 463,971
cycles) and whole-board (bit-exact, 460,683 cycles) Icarus runs
unchanged.

**Fifth P&R, MMCM O = 7: core 199.34 MHz WNS +0.003 ns, WHS +0.011 ns,
0 failing endpoints, all user constraints met; QSPI +0.830 ns.**
49,969 LUT (78.8%), 60,024 FF, 132.5/135 BRAM, 224 DSP. DRC: warnings
only (DSP pipelining advisories, BUFG cascade from phys_opt, MIG PLL
CLKOUT3 buffering). Bitstream `bitstream/v4_board_top_199.bit`, tag
`v4-board-199`. Speed: 460,617 cycles (real-MIG xsim, V4-B6; the fixes
did not change the Icarus counts) = **2.311 ms = 107.7x** vs ESP32-S3;
host start -> done 2.337 ms (Icarus) = 106.5x.

## V4-B9 (2026-10-01) — end-to-end with the real MIG: embedding bit-exact

The earlier real-MIG runs (V4-B6) never loaded parameters or image (the
bench wrote only header + descriptors), so they measured cycles but
could not check data; a first embedding check on 2026-09-30 therefore
read all 0x7F. `tb_v4_board_xsim.v` now preloads the whole gen_mfn DDR3
image straight into the two Micron models' storage (33,277 bursts per
chip, MEM_BITS 17, after the models' RESET_N erase), checks the mapping
by reading two preloaded words back over SPI (MIG BANK_ROW_COLUMN,
burst = words 2P/2P+1 at app_addr 8P, chip 0 = DQ[15:0]), then writes
header + descriptors over SPI, starts, and reads the embedding back over
SPI (one halfword per transaction).

**Final RTL (tag v4-board-199 + bench), 40 passes, real MIG + Micron
DDR3: embedding bit-exact with the C golden model, 460,592 core cycles
(6,804 waiting for parameters) = 2.311 ms at 199.34 MHz, host start ->
done 2.342 ms, error 0.** The image comes from the preload here (QSCLK
is tied off in this bench); the Quad-SPI image path is covered by the
Icarus whole-board test. Log: `docs/board_xsim_realmig_run.log`.
~6 h of CPU (the Micron model searches its storage linearly).
`sim/run_icarus.sh` from scratch: 10/10 benches pass.

## V4-D1 (2026-10-01) — datasheet v4

`docs/datasheet/FPGA-Neural-V4-Datasheet.md` (+ `.pdf`, built by
`build_pdf.py`): hardware, operation, memory map, pinout, timing,
resources, host protocol and ESP32 firmware guide. New
`model/ddr_hex_to_bin.py` turns gen_mfn's `ddr_full.hex` into the binary
blob the ESP32 writes at DDR3 word 0 (checked: 1,090,816 bytes, header
40 passes / desc 64 / image 256 / params 4096 / result 80000, magic OK,
image bytes equal to fmap_init.hex). Found while writing it, not yet
fixed in the firmware: (1) the driver expects DEVICE_ID 0x4E505601, the
chained bridge returns 0x4E505602; (2) the driver treats sys_rst as
active high (init drives 0, board_reset leaves 0) while the real-MIG
bench uses it active low, so the ESP32 would hold the FPGA in reset;
(3) CONTROL bit0 / opcode 0x0F soft reset is not connected in
v4_board_top.v (soft_rst_pulse unused).

## V4-F1 (2026-10-03) — ESP32 driver fixes, verified by driver <-> RTL co-simulation

Fixed in `firmware/esp32/components/fpga_neural`: DEVICE_ID per variant
(chained = 0x4E505602); sys_rst active low (pin set to 1 before it
becomes an output, board_reset pulses 0); `fpga_v4_write_bytes` split
into WRITE_MEM of 4,092 halfwords (the bus has max_transfer_sz 8 KB,
ESP-IDF rejects longer transactions; the old 32 KB would have failed);
Quad-SPI header (cmd + 48-bit address) sent as 7 QIO data bytes with
CS kept low (SPI_TRANS_CS_KEEP_ACTIVE) and a second transaction for
data / 64 dummy cycles + data, because the S3 address register is 32
bits and its half duplex mode cannot have MOSI and MISO in one
transaction (checked in the esp-idf sources: spi_ll_set_address,
SOC_SPI_HD_BOTH_INOUT_SUPPORTED undefined). New `fpga_v4_bringup()`
(first power-on self test, 8 steps).

New `sim/esp32_cosim/`: the real driver C code compiled for the PC with
`idf_cosim.c` in place of ESP-IDF (enforcing the S3 SPI rules above),
connected by two named pipes to `tb_v4_esp32_cosim.v` (whole board,
management SPI 10 MHz, Quad-SPI 80 MHz, bit by bit). Result: all 8
bring-up steps pass, embedding identical to the C golden, 460,784 core
cycles (6,996 waiting for parameters), 28 management SPI + 22 Quad-SPI
transactions. ~24 min of Icarus.

## V4-F2 (2026-10-03) — the real ESP-DL MobileFaceNet on v4

`model/espdl_reader.py` (dependency-free .espdl FlatBuffers reader) and
`model/espdl_to_v4.py` convert `human_face_feat_mfn_s8_v1.espdl` (the
model of the 248.8 ms ESP32-S3 reference) into a parameter pack read by
`gen_mfn.c --params` (and `--image`, `--dump-params`): 50 layers, same
structure as the 40-pass plan, final linear 512 -> 512 (embedding 512,
4 linear passes of 128 outputs, 43 passes). Folding: sh = e_out -
(e_x + e_w) with e_out after PRelu/Concat; PReLU slopes with exponent
-8 rescaled to ash 7 (10 layers); 3 Concat-split convs merged (one,
Conv_74+76, mixes weight exponents -9/-10: the -10 half rounded by 1
bit); weights un-permuted from ESP-PPQ's S3 (N/16,H,W,C,16) layout.
Input: aligned 112x112 face, BGR, (p-127.5)/127.5 at exponent -6.

Checks: gen_mfn default outputs byte-identical before/after; dump ->
params roundtrip identical. On 4 esp-dl example faces (hand-placed
landmarks, `model/align_face.py`): C model vs float network with the
same weights cosine 0.9886-0.9923; same person 0.49 / 0.79, different
people <= 0.08 (float: 0.50 / 0.80 / <= 0.07). Not bit-exact with ESP-DL
(different rounding), by design.

**RTL on the real weights (tb_v4_core_mfn, bill1 face): 37 tensors,
132,728 words, 0 errors; 484,287 cycles, 29,506 waiting for parameters**
(DDR model 5/8 word/cycle) vs 464,018 / 10,231 for the test model: the
linear passes compute in 326 cycles but wait ~6,500 for their 4,096
weight words. Whole board driven by the ESP32 driver co-simulation
(behavioral MIG, bill1 face): bring-up 8/8, 512-value embedding
identical, 477,957 cycles (23,176 waiting) = 2.398 ms at 199.34 MHz =
103.8x, 2.526 ms at 189.20 MHz = 98.5x (real-MIG run not done). A first
run failed (506/512 differ): the bench cleared words 80000..81999 for
the result, which with the 512 model overlap the end of the parameter
image (params 4096..80583); the bench now clears only the result area
named in the header. Log:
`docs/mfn_real_weights_run.log`. Driver generalized: `emb_len` in
`fpga_v4_layout_t`, `fpga_v4_layout_from_blob()`.

## V4-F3 (2026-10-03) — ESP32 bring-up app, datasheet rev 1.1

`firmware/esp32/v4_bringup/`: ESP-IDF app (model.bin + golden.bin
embedded from `make_model.sh`, 3 MB app partition, Kconfig pins/clocks):
`fpga_v4_bringup()` then CONFIG_V4_BENCH_RUNS timed inferences. Only
compiled against host stubs here (no ESP-IDF in this environment).
Datasheet rev 1.1: §4.7 real model, §11 driver fixes, co-simulation,
bring-up app.

## V4-D1 (2026-10-05) — designing and training networks for v4 (software only)

Datasheet chapters drafted as separate files (to be merged):
`docs/datasheet/CAP_PROGETTARE_RETE.md` (A: how to design a network,
data handling, worked examples) and `CAP_TRAINING.md` (B: training in
Python; the existing hardware cannot train, only extract features /
enrol / validate). New tools in `model/`, no RTL change:
- `v4_ref.py`: numpy twin of gen_mfn.c driven by a parameter pack.
  37/37 intermediate tensors identical to gen_mfn's expect.txt (random
  weights, embedding 128 and 512).
- `v4_plan.py`: maps a layer list to passes, checks the RTL limits
  (C multiple of 16, C/16 power of 2, half-buffer sizes, line buffer
  (W+2)*ng <= 512, fmap banks, GDConv, 64 passes), estimates cycles and
  parameter waits. MobileFaceNet: 40 passes, parameter image 64,080
  words (= gen_mfn), cycles 453,907 vs 453,587 RTL (+0.07 %), worst pass
  +11.4 % (stride-2 dw passes are input-bound; the old model said 14,488
  for pass 18, RTL 18,177, per-output-row rule now).
- `v4_qat.py`: PyTorch MobileFaceNet with float (BatchNorm) and v4
  integer forward (STE), calibrate (fold BN, power-of-two exponents,
  residual exponents tied), export_pack. PyTorch = v4_ref = gen_mfn,
  0 mismatches on 10 images (PReLU and ReLU); toy 2-class demo trains
  float -> QAT -> export end to end.
- `make_model.sh` accepts a `.pack` directly.
Open: gen_mfn.c only generates MobileFaceNet descriptors (other
topologies need a generalized generator).

## V4-D2 (2026-10-06) — generic network compiler, firmware usage chapter

`model/v4_compile.py`: any layer list of v4_plan.py + MFNP pack ->
desc/ldesc/ddr/on-chip hex, expect.txt, golden_ref.txt, ddr_full.hex
and the ESP32 blob (`--bin`). Feature maps allocated largest-first with
lifetime overlap check and input/residual in different banks; row bands
for any dw+1x1 pair; Linear/1x1 split along Cout in power-of-two parts.
Checks:
- MobileFaceNet: ldesc, ddr, on-chip images, golden byte-identical to
  gen_mfn (pass descriptors differ only in fmap addresses); RTL core
  sim 40/40 passes bit-exact, 464,019 cycles (132,704 words, 0 errors).
- `demo` net (not MobileFaceNet: ReLU, 7->4 stride 2, GDConv 4x4,
  residual, 256->48 linear in 2 passes, 12 passes): core sim 11 passes
  0 errors; board sim bit-exact, 86,787 cycles = 0.435 ms (v4_plan
  estimate 86,812).
- Board TB regression on gen_mfn output: embedding bit-exact, 460,683 cycles = 2.311 ms (unchanged); compiled MFN on
  the board TB: embedding bit-exact, 460,683 cycles (same as gen_mfn). Driver co-sim on the demo blob (run_cosim.sh --compiled): all bring-up steps pass, 0 mismatches, 86,792 cycles.
Other changes: v4_plan rejects a residual on a 1x1 (would read input and
residual from the same bank); v4_ref.run_net / v4_qat.QNet for any net;
tb_v4_core_mfn read-back address and tb_v4_board_top RESULT_W / output
size read from the blob header; run_cosim.sh `--compiled dir`;
make_model.sh `--net`. Firmware: `fpga_neural_v4_app.c` (face alignment
+ INT8 conversion in C, cosine, argmax, softmax, db search), PC test vs
align_face.py/image_to_int8: 17 of 752,640 values differ by 1, other
functions identical. Datasheet chapter C `CAP_FIRMWARE_USO.md`.

## V4-B10 (2026-10-06) — flash on the Master-SPI pins, boot from flash, configuration from the ESP32

Request (Michele, 2026-10-05): bank 14 at 3.3 V, W25Q32 on the dedicated
Master-SPI pins so the FPGA boots by itself (the D9/D10/C9 flash of v3
could not be read by the configuration logic).

- XDC: flash_cs_n L13 (FCS_B), flash_mosi K17 (D00), flash_miso K18 (D01),
  LVCMOS33; CCLK E9 via STARTUPE2. clk_ref T14/T15 LVDS_25 stays in bank
  14 as an input with `DIFF_TERM FALSE` (UG471: LVDS_25 inputs allowed
  at another VCCO only without the internal termination; the MIG RTL has
  DIFF_TERM_REFCLK = "TRUE", overridden by the port property: the
  routed IBUFDS reports DIFF_TERM 0); external 100 ohm on the board.
  Boot options: CONFIGRATE 33, SPI_BUSWIDTH 1, SPI_FALL_EDGE, COMPRESS.
- Full P&R from scratch (fresh project, same RTL as v4-board-199, same
  directives, 4.7 h): **did not close** — core_clk -0.474 ns (3,503
  endpoints), ui_clk -0.237 ns (41, u_rdf -> u_stream); DRC clean of IO
  errors. Placement variance on a full chip, not the flash change.
- ECO on the tagged routed checkpoints (`vivado/eco_flash_pins.tcl`):
  three IBUF/OBUF unplaced, port pins changed, place_cell on the new IOB
  sites, `route_design -nets` on their 6 nets, DIFF_TERM FALSE. 199.34 MHz:
  WNS +0.003 / WHS +0.011 ns (= tag), QSPI +0.830, 0 routing errors, DRC
  warnings only, bank 14 = {LVCMOS33, LVDS_25}, bank 16 empty. 189.20 MHz:
  +0.033 / +0.028 ns. Compressed bitstreams 2,968,718 / 2,970,462 bytes;
  `write_cfgmem -interface SPIx1` .bin = .bit payload byte for byte.
  Boot estimate 0.72 s nominal (0.48-1.44 s with the CCLK tolerance).
- Power (Vivado vectorless, "Low" confidence): 5.24 W, VCCINT 4.13 A;
  Tj 85 C 5.40 W, VCCINT 4.26 A. Thermal: no heatsink -> runaway (theta_JA
  18.2); heatsink theta_SA 5 still air at 40 C -> Tj 70.6 C. 5 V input
  1.35 A average / 1.5 A peak (estimate). Datasheet §7.
- Connector: hanxia HX-BTB M0810-2x20P / F0830-2x20P, 40 pins, 4.0 mm
  (CONNETTORE_BTB_V4.md); STWXE BA42-40AT/BT rejected (both receptacles).
- Firmware: `fpga_neural_v4_config.c` (JTAG load of the SRAM, flash
  erase/program/verify through FLASH_XFER, PROGRAM_B/DONE, XADC
  temperature over JTAG), `fpga_neural_v4_partition.c`,
  `fpga_neural_set_clock`, `fpga_neural_flash_xfer_raw`; v4_bringup
  step 0 + temperature monitor; 8 MB ESP32 flash with a 4 MB `fpga`
  partition.
- **Real finding (v3 bridge)**: FLASH_XFER takes each MISO bit from the
  latest flash response, so in a continuous stream multi-byte responses
  are mixed (10 MHz: JEDEC read 0xE84617 instead of 0xEF4016 = bits 7..3
  of response j + bits 2..0 of j+1). Firmware rule: response j = {byte
  j+2 bit 7, byte j+1 bits 6..0} at 1.6 MHz; co-simulated window 1.25-2.2
  MHz (1.0 and 2.5 MHz wrong). Write commands without trailing bytes
  (the 2 dummy 0x00 of fpga_neural_flash_xfer would hit the flash).
- Verification: `sim/esp32_cosim/jtag_tap_test.c` 12/12 (C TAP model);
  `run_flash_cosim.sh` (driver + RTL + W25Q32JV model): at 1.6 MHz JEDEC, WREN framing, 64 KB + 4 KB erase and multi-byte reads correct; sweep 1.25-2.2 MHz correct, 1.0 and 2.5 MHz wrong; full run at 1.6 MHz (4,400-byte image, 2 sectors) PASSED: driver code 0,
  model 5 page program / 1 block + 4 sector erase / 1 rejected (the
  trailing-byte WREN) / 0 bytes over 0 bits, PROGRAM_B -> DONE, flash
  array identical to the expected image (0x30000 bytes, bench backdoor
  check). 160 min of Icarus for 32.1 ms simulated. Log:
  `docs/esp32_flash_cosim_run.log`.

## V4-G1 (2026-10-06) — generic accelerator, step 1: user-defined input

Michele's requirement: v4 is a generic parallel accelerator (16 compute
units = the 16 array columns), the network is decided by its designer;
MobileFaceNet is only the benchmark (target stays >= 100x). Step 1 of
the generalisation: the first layer no longer assumes 112x112x3.

- `rtl/im2col_feeder.v`: image width/height (1..255), channels (1..4),
  stride (1/2), words per row, output size and beats per position are
  run-time configuration. Left padding realigned by C bytes, bottom
  padding row zeroed, row base address incremental (no multiplier in the
  loop), stride-1 slot rotation and loader limit, 9C-byte vector packed
  into ng = 2..3 beats. Limit: width*channels <= 496 bytes (row RAM).
- `rtl/v4_core.v`: im2col pass descriptor fields [180:173] width,
  [183:181] channels, [89:82] height (they replace the feeder start word
  and res_base, unused by an im2col pass); stride in bit [1]; words per
  row computed and registered from the descriptor.
- Model: `v4_plan.Input(h, w, c)` (optional first item, default
  112x112x3), `Conv1(..., stride=)`; v4_ref `im2col()`, v4_compile
  (image rows word-aligned and zero-padded, parameter base moves after a
  large image), v4_qat (any input, non-square GDConv); gen_mfn sets the
  new fields. New examples `rgb160` (160x120 RGB) and `gray_s1` (64x48
  grayscale, stride-1 first layer).
- Verification (Icarus 12): tb_im2col_feeder 10 formats (112x112x3 s2,
  odd sizes, 1/2/3/4 channels, s1/s2, widest rows, 1x1), 0 errors, three
  mutations detected. MobileFaceNet core 464,019 cycles, 37 passes
  bit-exact (= before the change); board 460,683 cycles, start->done
  2.337 ms, embedding bit-exact (= before). rgb160: core 8/8 passes
  bit-exact 89,437 cycles; board (image over Quad-SPI) bit-exact 89,370
  cycles = 0.448 ms. gray_s1: core 8/8 bit-exact 57,114 cycles, also with
  the QAT-exported pack. v4_qat --selftest: mfn (vs gen_mfn), demo,
  rgb160, gray_s1 all 0 mismatches.
- Not done yet: P&R (the feeder now has runtime muxes: C-byte realign,
  3C-byte packing, 3-way beat select); planner estimate for a stride-1
  conv1 is low (6,234 vs 9,271 cycles measured: feeder-bound).

## V4-G2 (2026-10-06) — generic accelerator, step 2: up to 4096 inputs per neuron, any channel count

A layer's inputs per neuron are no longer limited to 512 (32 groups of 16).
4096 is the maximum, not a requirement: any channel count from 1 to 4096
works, because the compiler pads the network to the hardware channel
counts with zero channels.

- `rtl/dwpw_engine.v`: new parameter `MAXNGV` (pointwise input groups,
  256 in v4_core). Group count `cfg_ng` and the wg/po_g/sg counters are
  9 bits; the vector RAMs vram_a/b hold 2*MAXNGV words (zero-initialised:
  an unwritten B word made the packed DSP product X in simulation, even
  though the A result does not depend on it in hardware). The dw line
  buffer still takes cfg_ng[5:0].
- `rtl/fmap_feeder.v`: cfg_ng and its group counter are 9 bits.
- `rtl/v4_core.v`: group count = {d[191:189], d[25:20]}; GDConv keeps
  d_ng[5:0].
- Model: `v4_plan.MAXNGV = 256`; `lower(net)` pads each layer's output
  channels to the hardware rules (groups of 16, at least 2 except the
  last layer, at least 3 before a GDConv, a power of two on maps larger
  than 1x1, the last layer only to a multiple of 16) with zero weights,
  bias and slope. plan(), v4_compile (descriptor bits 189..191, padded
  records and expected tensors) and v4_qat (hw_check compares the real
  outputs and checks the padded tail is 0) all run on the lowered net.
  New examples `fc4096` (GDConv 4x4x256 -> Linear 4096 relu -> Linear
  16, i.e. 4096 inputs per neuron) and `odd` (53x37 input, 20, 40, 100,
  70, 7, 1, 4095 and 13 channels). Existing examples lower to themselves.
- Verification (Icarus 12): tb_dwpw_engine passes. MobileFaceNet core
  464,019 cycles, 37 passes bit-exact; board 460,683 cycles = 2.311 ms
  at 199.34 MHz, embedding bit-exact (both = before). fc4096: core 8/8
  passes bit-exact 146,579 cycles; board bit-exact 128,363 cycles =
  643 us, of which 96,254 waiting for parameters (256x4096 + 4096x16
  weights, ~1.26 MB streamed). odd: core 9/9 bit-exact 31,612 cycles;
  board bit-exact 27,985 cycles = 140 us. v4_qat --selftest fc4096, odd,
  mfn, demo, rgb160: 0 mismatches.
- Not done yet: P&R (vector RAM 512x128 x2, 9-bit group counters).

## V4-G3 (2026-10-07) — generic accelerator, step 3: dense 3x3 convolution anywhere, networks without convolutions

- `rtl/conv3_feeder.v` (new): streams, for every output position, the
  3x3 window of a feature map (pad 1, stride 1/2) as 9*ng words in the
  order (kr, kc, g), zero outside the map, so dwpw_engine.v runs a dense
  3x3 convolution as a pointwise-only pass with 9*Cin inputs per neuron.
  Incremental addresses (window rows contiguous, row stride from the
  descriptor), no multiplier; same latency-4 read port and FIFO as
  fmap_feeder.v, one word per cycle.
- `rtl/v4_core.v`: descriptor widened to 256 bits (desc chunk 1 now used
  in full; the board blob already had 128 bits per chunk). [192] conv3,
  [200:193] input width, [208:201] input height, [214:209] input groups,
  [229:215] input row stride. Feeder read port and output: 3-way mux
  (im2col / conv3 / fmap). File lists updated (run_icarus.sh, cosim
  scripts, pr_core.tcl, create_v4_board.tcl).
- Model: `v4_plan.Conv3(cout, act, stride, residual)` (residual = block
  input, as DWPW); a network may start with any layer: without Conv1 the
  input is loaded as the first feature map (channels padded like a layer
  output). Power-of-two group rule only checked on maps larger than 1x1.
  v4_ref `conv3()` (pack record kind 3, weights [cout][(kr*3+kc)*cin+ci]),
  v4_compile (conv3 passes split by Cout like a 1x1), v4_qat (QLayer
  "conv3"). Examples `resnet_s` (64x64 RGB, six 3x3 convolutions with
  residual) and `mlp784` (784 -> 128 -> 64 -> 10, no convolution).
  Limit: Conv3 Cin <= 256 (9*Cin groups <= MAXNGV, power-of-two groups).
- Verification (Icarus 12): tb_conv3_feeder 9 formats (odd sizes, 1x1,
  255 wide, 1..28 groups, s1/s2), 0 errors, three mutations detected.
  v4_qat --selftest resnet_s, mlp784: 0 mismatches (PyTorch vs v4_ref vs
  v4_compile). resnet_s: core 9 passes bit-exact 97,392 cycles; board
  bit-exact 97,327 cycles = 488 us (32x32 3x3 passes at ~98 % of the
  array). mlp784: core bit-exact 11,662; board bit-exact 9,889 cycles =
  49 us (parameter-load bound). MobileFaceNet core 464,019 cycles, board
  460,683 cycles, bit-exact (unchanged).
- Not done yet: P&R (new feeder, 256-bit descriptor register, 3-way
  128-bit feeder mux in front of the engine).

## V4-G4 (2026-10-07) — generic accelerator, step 4: pooling; CPU reference runner for the ESP32-S3

- `rtl/conv3_feeder.v`: window feeder generalised: K = 2 or 3, padding
  0 or 1, and a pooling order (g, kr, kc) next to the convolution order
  (kr, kc, g); out_pad flag per beat. Bug found by the extended unit
  test: -pad was latched at start in the same edge the counters loaded
  it (X in the first frame); now a free-running register like a0.
- `rtl/pool_unit.v` (new): max (out-of-map taps ignored) or average
  (sum of the K*K taps) pooling, y = sat8((acc*mul + round) >>> sh),
  16 lanes, one word per (position, group) to tile_writer.
- `rtl/tile_writer.v`: t_odd input (a tile with no B word written at
  2*pair+1). `rtl/v4_core.v`: descriptor [230] pool, [231] 2x2, [232] no
  padding, [233] max, [241:234] mul, [245:242] shift (window fields
  shared with conv3); engine not started on a pooling pass.
- Model: `v4_plan.Pool(kind, k, stride, pad, mul, sh)` (planner checks,
  lowering looks through pools for the GDConv rule), v4_ref `pool()`,
  v4_compile pooling passes, v4_qat `pool_t` (PyTorch max_pool2d /
  scaled sum, exponent unchanged) and `--pack NET DIR`. Example
  `vgg_pool` (80x80 RGB, 3x3 dense, max 2x2 and average 3x3 pooling).
- `model/s3_export.py` + `firmware/esp32/v4_s3_bench` (new, C++): the
  same network on the ESP32-S3 CPU with the FPGA integer arithmetic
  (v4net.cpp, twin of v4_ref.py), output compared byte for byte, time
  per inference. Host build checked bit-exact vs the FPGA golden on 8
  networks (mfn, demo, odd, fc4096, resnet_s, mlp784, vgg_pool, gray_s1).
  Not built with ESP-IDF here (no toolchain in this environment).
- Verification (Icarus 12): tb_conv3_feeder 15 formats (convolution,
  pooling 2x2 s1/s2 without padding, 3x3 s1/s2 with padding, odd sizes,
  1..32 groups), 0 errors. v4_qat --selftest vgg_pool 0 mismatches, and
  mfn, demo, rgb160, gray_s1, fc4096, odd, resnet_s, mlp784 still 0.
  vgg_pool: core 11 passes bit-exact 308,978 cycles; board bit-exact
  308,810 cycles = 1.549 ms. Full regression 11/11 (MobileFaceNet board
  460,683 cycles, bit-exact, unchanged).
- Not done yet: P&R (pool_unit: 16 12x9-bit multipliers in LUTs, window
  feeder mode muxes, writer t_odd).

## V4-G5 (2026-10-07) — generic accelerator, step 5: 2x upsampling, concatenation, up to 256 passes

- `rtl/conv3_feeder.v`: 1x1 window (copy), up2 (nearest 2x: each
  output column / row read twice) and emitted groups `nge` >= map groups
  (groups >= ng read as padding = zero groups of a concatenation copy).
- `rtl/pool_unit.v`: 1-tap mode (copy / upsampling). Bug found by the
  U-Net core sim (passes 8 and 15, 4800 words): a max window with no tap
  inside the map (the zero groups of a concat copy) gave -128; now 0.
  The board output was bit-exact even before (the next layer's weights
  on those channels are zero), the stored map was not.
- `rtl/v4_core.v`: 256-bit descriptors ([246] 1x1 window, [247] up2,
  [253:248] emitted groups), NDESC 256 (core, core_top, board_top).
  `rtl/v4_boot.v`: header check raised from 64 to 256 passes (found by
  the 78-pass bench_heavy board sim: error flag right after start).
- Model: `v4_plan.Upsample()`, `Concat(src)` (per-tensor channel maps:
  the second part starts at the first part's padded group count, the
  next layer's weights are scattered accordingly), v4_ref, v4_compile
  (copy passes with out offset), v4_qat (exponent tie for concat
  inputs), s3_export + v4net.cpp (types 7, 8). Example `unet_s` (40x40
  RGB -> 40x40x8, two skip connections). Final-test networks
  `bench_small` (32x32), `bench_medium` (96x96 depthwise-separable),
  `bench_heavy` (128x128, 3x3 dense up to 256->256, residual, pooling,
  FC 1024; 78 passes, 2.79 MB parameters).
- Testbenches: generic messages (no "MobileFaceNet"/"embedding"), core
  watchdog 20M cycles, board expected output up to 16384 words, 16 MB
  DDR model in the core TB and the MIG stub (bench_heavy > 2 MB),
  64-bit microseconds print.
- Note: blobs compiled before this step must be recompiled (the
  emitted-groups field reads 0 = 64 groups: a step-4 vgg_pool blob ran
  bit-exact but 32x slower on the pooling passes).
- Verification (Icarus 12): tb_conv3_feeder 20 formats 0 errors. QAT
  selftest 0 mismatches: unet_s, bench_small/medium/heavy, mfn. unet_s:
  core 12 passes bit-exact 421,064 cycles, board bit-exact 419,861 =
  2.106 ms. vgg_pool (recompiled): core 308,978, board 308,810 (= step
  4). bench_small board 10,808 cycles = 54 us; bench_medium board 82,731
  = 415 us (both core and board bit-exact). MobileFaceNet board 460,683
  cycles, bit-exact, unchanged. Full regression 11/11.
- Not done yet: P&R of the steps 3-5 RTL (timing margin unknown).

## V4-B11 (2026-10-06) — one 200 MHz oscillator instead of two

Request (Michele): a single 200 MHz oscillator instead of 310.078 MHz
(sys_clk) + 200 MHz (clk_ref).

- MIG regeneration tests: with a 200 MHz input the MIG accepts no
  memory clock near 310 MHz (its PLL uses DIVCLK = 1: "Invalid Input
  Clock Period 200, nearest 206.654"); 300 MHz memory is refused
  ("Memory Time Period 3333 ps not supported", AR 67179); 350 MHz would
  put ui_clk at 175 MHz. Chosen (Michele: option A): oscillator ->
  IBUFDS -> BUFG = IDELAYCTRL reference; BUFG -> MMCM x31/5/4 = 310.0
  MHz -> BUFG -> MIG sys_clk_i; MIG `NO_BUFFER` for both clocks
  (`vivado/mig_200/mig_a.prj`, tCK 3226 ps, PLL x4 as before); MIG
  sys_rst AND MMCM LOCKED. ui_clk 155.0 MHz, core 199.29 MHz.
- RTL `v4_board_top.v`: clk_ref ports removed, IBUFDS/BUFG/MMCM/BUFG;
  stub and benches updated. Icarus whole board: embedding bit-exact,
  460,683 cycles (unchanged).
- Vivado project `Vivado/v4_board_200`; `create_v4_board.tcl` now does
  reset_target before generate_target (the regenerated MIG failed
  without it). Incremental implementation: refused by the BASIC
  license. Placement reuse by Tcl (`impl_reuse_placement.tcl`): failed
  on LUTRAM packing. ECO (`eco_osc200.tcl`) on the flashcfg checkpoints:
  0 cells moved, 4 new cells placed by hand. Fixes found on the way:
  COMPENSATION INTERNAL (direct feedback), re-apply the CDC
  set_max_delay after the new primary clock, set_clock_groups
  -asynchronous osc_200 / ui_clk (the MIG tempmon / IDELAYCTRL
  syncs failed hold once the clocks became related; also in the XDC).
- Result: 199.29 MHz WNS +0.004 / WHS +0.011 ns, 189.15 MHz +0.034 /
  +0.028 ns; DRC warnings only; bank 34 {SSTL15, DIFF_SSTL15, LVDS_25}.
  Power 5.35 W (+0.12 W, the MMCM). Oscillator SiT9121AC-2CF-33E-200
  (LCSC C835051 out of stock; DigiKey/Mouser).
- Real-MIG xsim of the whole board with the new clocking (MMCM -> MIG,
  real MIG + 2 Micron DDR3 models): calibration complete at 66.3 us, DDR3 preload read back over SPI OK, 40 passes, embedding bit-exact, 460,587 core cycles (6,799 waiting for DDR3), error 0, host start->done 2.342 ms (docs/board_xsim_osc200_run.log, 3.6 h of CPU).

## V4-G6 (2026-10-07) — final test: three generic networks + MobileFaceNet, FPGA and ESP32-S3 files

Michele's acceptance test: a small, a medium and a heavy generic network
plus MobileFaceNet, FPGA timing of each, and the same networks on a
physical ESP32-S3 CPU (C++) to compare values bit for bit and time.

- Networks (v4_plan.py): `bench_small` (32x32x3, 3x3 dense stride 2,
  10 out), `bench_medium` (96x96x3, depthwise-separable, 2 out),
  `bench_heavy` (128x128x3, 3x3 dense up to 256->256, two residual
  blocks, three max pools, FC 256->1024->100; 78 passes, 2.79 MB of
  parameters), `mfn`.
- Whole-board sims (Icarus, output bit-exact): small 10,808 cycles =
  54.2 us; medium 82,731 = 415.0 us; MobileFaceNet 460,683 = 2.311 ms;
  heavy 2,449,064 = 12.286 ms at 199.34 MHz (12.944 ms at 189.20;
  planner estimate 2,453,786). ESP32 view start->done 66.6 us, 437 us,
  2.337 ms, 12.319 ms.
- Bugs found by the test, all fixed: v4_boot still refused > 64 passes
  (4530739); above 64 passes the blob image overwrote the descriptor
  table (391ee0d, image after the table); a residual layer split into
  several passes read the residual without the part's offset (26abbca);
  sim DDR models too small for 2.8 MB (16 MB now, e67d298); 32-bit
  microsecond print overflow (9b4c0e2).
- ESP32 driver generalised (bcd1aed): layout carries img_bytes and
  out_len read from the blob header, fpga_v4_pad_rows / pad_pixels for
  the input layout, output of any size. Driver <-> RTL co-simulation 8/8
  bring-up steps, output identical: MobileFaceNet 460,784 cycles,
  bench_small 10,807, mlp784 9,863.
- Delivery: /mnt/project-files/v4_test_finale/ (per network net.bin for
  v4_s3_bench, fpga_model.bin, model.pack, img.bin, expected.bin;
  v4_s3_bench.tar.gz), files checked identical to the simulated blobs.
  v4_s3_bench (v4net.cpp) bit-exact on the PC on all four networks; not
  yet built with ESP-IDF nor run on a real S3.
- Not done: P&R of the generic RTL (steps 3-5).

## V4-D3 (2026-10-07) — datasheet rev 2.0: generic accelerator

Michele: write the datasheet at the end of the final test, as a senior
electronics engineer, with every chapter needed (processor hardware,
firmware and usage with examples, how to think and create a network).

- `docs/datasheet/FPGA-Neural-V4-Datasheet.md` rewritten (21 chapters,
  PDF 38 pages): processor architecture and the 16 compute units;
  programming model (layers -> passes, data layout, arithmetic);
  hardware rules R1-R21 with who satisfies each (compiler or designer)
  and real planner error messages; performance of 13 simulated
  networks with conditions and the cycle model (estimate within -10 /
  +12 %); absolute maximum ratings, recommended operating conditions
  and LVCMOS33 DC levels (DS181 v1.27, TI SLVSDG1C); blob and
  descriptor formats; generic firmware chapter; design and creation
  chapters (memory and time budgets, layer choice, INT8, guided
  example); usage examples; verification status; 8-layer stack-up.
  Every figure is labelled simulated / Vivado / estimate / datasheet.
  The old appendices A-C (CAP_*.md) are merged into the chapters and
  removed; assemble_datasheet.py now only rebuilds the index (one line
  per chapter: a numbered Markdown list renumbered the chapters);
  build_pdf.py reads the revision for the footer.
- `v4_plan.py` also takes a network file (`v4_plan.py rete.py`, the same
  NET = [...] files v4_compile.py reads); its docstring no longer says
  descriptors cannot be generated.
- Section references in the firmware sources updated to the new numbers.

## V4-B12 (2026-10-07) — whole-board P&R of the generic RTL (steps 3-5): does not fit

Request (coordinator, approved by Michele): full place & route of the
generic v4 RTL (79e8094) on the whole board, 199.29 MHz core then 189.
- Fresh project `Vivado/v4_board_generic` from `create_v4_board.tcl`
  with `vivado/mig_200` (single 200 MHz oscillator, mig_a.prj
  identical); every source a direct reference, conv3_feeder.v and
  pool_unit.v in the list. Flow `impl_v4_board.tcl` (Performance_Explore
  PostRoutePhysOpt, maxThreads 1, CPU capped 2.4 GHz, max 47 °C).
- Synthesis clean (no ERROR / CRITICAL WARNING): LUT 57,251 / 63,400 =
  90.3 % (7,610 LUTRAM), FF 58,578, BRAM 132.5 / 135 (unchanged), DSP
  240 / 240 (pool_unit +16). Reports `docs/pnr/board/generic/199/`.
- place_design fails (Place 30-487): unplaced instances need 5,937
  slices, 5,912 left. The old RTL already used 15,433 / 15,850 slices
  (97.4 %). Not a clock-frequency problem: 189 MHz would fail the same.
- LUT growth vs the old RTL's synthesis checkpoint (v4_board_200,
  MIG excluded, `old_rtl_synth_util_hier.rpt`): +5,987 (52,873 vs
  46,886). v4_core +1,969 (+1,514 LUTRAM: desc_lo/hi/ld 3 x 128 bit x
  NDESC 256, 4 LUT per bit at 256 deep vs 1 at 64), pool_unit +1,844
  (+16 DSP), im2col_feeder +1,214 (+836 logic, +378 LUTRAM),
  conv3_feeder +606, fmap_mem/fmap_feeder/gdconv +445; dwpw_engine and
  tile_writer unchanged.
- Tool-only attempt (no RTL change): synth_design -directive
  AreaOptimized_high + opt_design ExploreArea is worse: DSPs 96 instead
  of 240, multipliers moved to LUTs, 80,121 LUTs (126 %), 136 RAMB36;
  the DRC stops before placement. Area tuning in the tool alone cannot
  make the design fit.
- Decision pending (Michele): an RTL area reduction of about 6,000 LUTs
  is needed to get back to the old RTL's 97 % slices (which, from
  scratch, still missed 199 MHz by 0.474 ns). Candidates: NDESC 128
  (about -770 LUTRAM, bench_heavy needs 78 passes), descriptor table in
  DDR with prefetch (about -2,900 LUTRAM), pool_unit / conv3_feeder as
  build options or a smaller pool_unit, a leaner im2col_feeder. No RTL
  changed, no bitstream.

## V4-B13 (2026-10-07) — area cuts for one bitstream (branch v4-generic-area)

Decision (Michele, decision card): ONE bitstream keeping every function
(pooling, dense 3x3, upsample/concat, 256 passes); recover area in RTL.
Four cuts, each verified in Icarus before the next:
1. Descriptors read from DDR3 per pass (v4_core: 3-word fetch with one
   DDR request at `desc_base + 3*pass`, prefetched while the previous
   pass runs; v4_boot no longer copies the table, it hands
   `desc_base` over). Removes the 3 x 256 x 128-bit LUTRAM tables.
2. pool_unit scaling serialized: 4 lanes per cycle (fast path when
   mul = 1, sh = 0); a sim-only check fires if two windows arrive closer
   than 4 cycles.
3. im2col_feeder without the realign step: rows written at slot word
   k+1, slot word 0 always zero.
4. GDConv uses the engine's pointwise requant (u_rq_pw lanes 0..15
   through an x_acc mux) instead of its own requant_act.
Result (core TB, cycles vs 8d8268d baseline, all bit-exact):
bench_small 10,960 (10,873), bench_medium 82,867 (82,799), resnet_s
97,460 (97,392), vgg_pool 309,115 (308,978), unet_s 421,262 (421,064),
mlp784 11,934 (11,662), MFN 464,359 (464,018, +0.07 %). The LUT saving
is an estimate until the Vivado synthesis on mikilab (about -2,800 LUT
estimated before cut 4; no measured number yet).

## V4-B14 (2026-10-07) — one host link: commands only over Quad-SPI

Request (Michele, 16:10 UTC): commands only via Quad-SPI (I2C only if
cheaper: it is not, the Quad-SPI port already exists).
- qspi_data_port.v: new commands on the same 56-bit header: 0x3A
  REG_WRITE (CONTROL.start, NETWORK_BASE), 0x4A STATUS (one 16-byte
  word: ID 0x4E505604, NETWORK_BASE, calibrated/error/busy/done/flash
  busy; reading it releases data_ready_n), 0x5A FLASH_XFER (1..512
  bytes, ONE flash transaction, responses into a 32-word LUTRAM buffer),
  0x6A FLASH_READ. The flash transaction runs in its own FSM so STATUS
  stays readable while it runs (first version served STATUS only after
  the flash transaction: found by the board TB).
- v4_board_top.v: spi_host_bridge_v3_chained + host_mem_bridge and the
  adapter owner mux removed; ports sclk/mosi/miso/cs_n removed (A15,
  B16, B17, A16 free). XDC, create_v4_board.tcl, sim scripts updated.
- CDC fix found while porting the ESP32 co-simulation: the driver polls
  STATUS right after releasing sys_rst, while ui_clk_sync_rst is still
  high. The three CDC FIFOs were reset on the ui side only (pointer sets
  inconsistent after reset, late answers shifting every later read).
  Now the FIFOs are never reset (INIT values, memory INIT 0) and the ui
  side discards headers/data arriving during reset.
- ESP32 driver: Quad-SPI only (fpga_v4_reg_write, fpga_v4_read_status,
  fpga_v4_wait_calib/run, fpga_v4_flash_xfer, data_ready_n ISR); config
  flash code over FLASH_XFER (no 2-byte trailing margin, no clock
  switching); bring-up app, example and co-simulation mains updated.
- Board TB (tb_v4_board_top.v): image WRITE, REG_WRITE, STATUS, IRQ,
  result READ, FLASH_XFER/FLASH_READ with flash_miso looped back:
  bit-exact on bench_small. Real-MIG xsim bench ported (not run here,
  needs Vivado).
- ESP32 driver co-simulation (run_cosim.sh, MFN, real driver over the
  pins): ALL 8 bring-up steps pass, output identical, 460,899 core
  cycles (7,111 waiting for parameters), 254 Quad-SPI transactions.
- Config-flash co-simulation (run_flash_cosim.sh, SMALL=1): JTAG/XADC
  model 12/12; JEDEC, 1-byte WREN/WRDI (exact transaction length),
  erase, program + verify + PROGRAM_B/DONE, flash array identical to the
  expected image: BENCH PASS.

## V4-B15 (2026-10-07) — timing fixes after the first generic-board P&R

First P&R of v4-generic-area at 199.29 MHz (reports in
pnr/board/area/199/): placed and routed, slices 95.9 % (v4 closed at
97.4 %), core WNS -1.926 ns over 10,012 endpoints, ui_clk -0.222 ns.
The paths are spread over the new generic logic, most with 0-1 logic
levels (route-dominated fanout). One RTL change per failing group:
- pool_unit: scaling split into round-add / shift / saturate stages
  (worst group, -1.93 ns), input registered (conv3 FIFO -> compare ->
  s1_acc, -0.96 ns).
- write ports with a local register copy next to each memory: pw weight
  BRAM banks (-1.32), dw weight / dw requant / pw requant LUTRAM banks
  (-0.75..-1.07), the three fmap banks (-0.77). One more cycle of write
  latency; a pass now ends only when its last fmap write is in the bank
  (new fmap_mem.wr_busy). Without that check the core TB saw the last
  word of each pass missing.
- gdconv_unit: one stage between the accumulator LUTRAM read and the
  requant (eg -> rq_acc, -1.26), q_g delayed by the same cycle; ve/ge/gc
  replicated.
- v4_core: pwq lookup address registered as a whole (d -> add ->
  LUTRAM, -0.68), registered copies of the pass type for the writer and
  engine input muxes (-1.02 / -0.86), idle_h replicated (-1.15),
  w_data_r kept in fabric (merged BRAM -> DSP route, -0.88).
- requant_act: shift2/half1/ash6/halfa6 replicated (-1.01 / -0.82);
  pw_array_packed: tv/tf replicated (-0.84).
- im2col_feeder: ow-1/oh-1/rw-1/rw+1 precomputed, lim registered
  (only grows inside a layer, so a one-cycle-old value is conservative),
  row slots and row-RAM write data replicated.
- conv3_feeder: FIFO room registered conservatively (count + issue).
- async_fifo: read pointer for wr_count decoded and registered once more
  (ui_clk -0.22 ns in the DDR stream credit and the QSPI read FIFO);
  an older read pointer only makes the count larger.
Verification (Icarus): the 7 networks bit-exact, cycles (before): small
10,968 (10,960), medium 82,886 (82,867), resnet_s 97,481 (97,460),
vgg_pool 309,155 (309,115), MFN 464,431 (464,359, +0.016 %), unet_s
421,300 (421,262), mlp784 11,936 (11,934). Full regression passes (11/11); board TB with the real Quad-SPI path: MFN bit-exact, 460,973 core cycles = 2.312 ms at 199.34 MHz (460,683 before). Pooling differential test
against the committed unit: 720 words, 0 errors (spaced and back-to-back
taps). Timing numbers above are from the old run; the effect of these
fixes is only known after the next P&R (PNR_TIMING_TODO.md).

## V4-B16 (2026-10-08) — depthwise path found optimized away; area cuts

Synthesis of the timing fixes (3dc66a1, reports pnr/board/area/199_t1/)
did not fit: LUT 64,973 (102.5 %), BRAM 142.5/135. Cause (mikilab,
dw_check/): in EVERY earlier board synthesis, including the tagged
bitstreams v4-board-199/189, Vivado removed the dw weight memory GEN_DWW
(0 cells; constant propagation starting at we_dww), hence the dw MACs, the
line buffer and the window history. Those bitstreams do not compute
depthwise layers; every earlier area number was without depthwise. The
KEEP write registers of 3dc66a1 stopped the propagation. The logs also
trim loader descriptor fields (segment lengths) in old and new builds:
to be settled by a post-synthesis netlist simulation (NETLIST_SIM_TODO.md)
before any bitstream.
Area cuts, each verified bit-exact on the 7 networks:
1. dwpw_engine s1_y (4 x 320 bit FIFO) forced to distributed RAM: Vivado
   had used 4 RAMB36 + 1 RAMB18.
2. fmap_mem: each bank = two 4K x 128 arrays (expected 4K x 9: 15 RAMB36
   per half, 30 per bank instead of 32), {bank, half} output select.
3. pw_array_packed: adder tree level l is 17+l bits wide, sign-extended
   (yosys estimate per column: -82 LUT, -188 FF; about -1,300 LUT total,
   not the -6,800 first estimated).
4. dwpw_engine: one P_CO-lane pointwise requant used for A then B (the
   core already requires results >= 2 cycles apart, Cin >= 32); A's
   output held one cycle; GDConv keeps the undelayed output. The unit TB
   now models the two-cycle parameter lookup of v4_core and keeps ng >= 2.
Cycles (V4-B15 in brackets): small 10,972 (10,968), medium 82,894
(82,886), resnet_s 97,490 (97,481), vgg_pool 309,168 (309,155), MFN
464,467 (464,431), unet_s 421,310 (421,300), mlp784 11,937 (11,936).
Estimates, not measured: requant -4,300 LUT (plan model: 0 cycles), BRAM
142.5 -> about 132. Real numbers: SYNTH_CUTS_TODO.md. Open: depthwise at
8 lanes (about -8,200 LUT, MFN +10.3 % by the plan model) pending the
real synthesis numbers and Michele's decision.
Full Icarus regression after the cuts: 11/11 pass; board top (real DDR
stream model) bit-exact, MFN 460,983 core cycles = 2,312 us at 199.34 MHz
(V4-B15: 460,973). Michele (2026-10-07 23:22 UTC): depthwise at 8 lanes
approved if the real synthesis needs it; priority is a correct generic
network, timing improved where possible but not blocking.

## V4-B17 (2026-10-08) — depthwise really in the netlist; first generic bitstream (189 MHz)

mikilab session (RTL owner on v4-generic-area since CUTS_NEXT_TODO).
- Netlist sim (Icarus + unisims, xsim BASIC refuses > 50,000 instances;
  `netlist_sim/`): the 3dc66a1 board netlist never wrote the dw weights
  (GEN_DWW WE 0, MAC output 0). Cause in the synthesis checkpoints: Vivado
  moved v4_core's dw weight LUTRAM into u_dw (to merge it with wd_q) and
  lost its write enable (KEEP copies with D = GND, or the RAM removed by
  constant propagation); KEEP/dont_touch also made it copy GEN_WC[10..15]
  with a constant write enable. Fix (576af0d): the dw weight RAM inside
  dw_linebuf_grouped (DWW_INT), written through ports; keep/dont_touch
  removed. A Tcl check (`wechk`) now verifies every parameter RAM's write
  enable in each synthesis. Netlist sim of the fix: dw WE 4 per chunk as
  RTL, MAC output non-zero.
- Area: depthwise at 8 MACs (HALF, 6847a87; mfn +11.8 %, bench_medium
  +15.3 %, 5 nets unchanged) + operand register (5fce52b). 16 lanes did
  not place (272 slices short). GDConv product register and fmap read-
  enable replication (600375f) for the next 199 MHz attempt.
- P&R (from scratch, no ECO), RTL 5fce52b: 199.34 MHz core WNS -0.107 ns
  (24 endpoints), post-route phys_opt/route on the checkpoint -0.014 ns;
  189.15 MHz (O = 7.375, local edit) CLOSED: WNS 0.000, WHS +0.020, LUT
  51,157, BRAM 127.5, DSP 228 -> `bitstream/v4_board_area_189.bit/.bin`.
- Verification of every RTL step: 7 networks bit-exact (`sim/run_nets.sh`),
  Icarus regression 11/11, board MFN 515,968 cycles (2.588 ms at 199.34
  MHz, 2.728 ms at 189.15). The old v4_board_top_199/189 bitstreams do not
  compute depthwise layers.
