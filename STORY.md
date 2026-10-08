# OpenNPU: the story so far

*How a single INT8 neuron in Verilog grew, in five weeks, into a generic
neural-network accelerator on an Artix-7 with DDR3, driven by an
ESP32-S3.*

Every number in this story is measured (simulation, synthesis or place &
route) unless it says *estimate*. Dates come from the project logs.

---

## 1. One neuron on an FPGA

Early September 2026. The project is a single INT8 neuron written in
Verilog: multiply inputs by weights, add them up, add a bias, apply ReLU
and saturate at 127. The target is a Lattice ECP5 with an external
PSRAM; the reference machine is an ESP32.

The first logged bug (2 September) was in the memory-to-neuron path, and
it turned out to live in the testbench, not in the design: a byte/word
addressing mistake when preloading data. It was the first of many times
the rule *find the real cause, don't guess* saved us from fixing the
wrong thing.

## 2. More processors, and the lesson that memory is the limit

From 5 September the neuron became an 8-stage pipelined processor. On
its own, after place & route on the ECP5, it ran at 183 MHz, up from
61.7 MHz for the first parallel neuron.

Then the processors multiplied: 2, 4, 8, with memory arbiters, banks and
prefetch. And the lesson that drove everything afterwards arrived:
**adding compute units is useless if the external memory cannot feed
them.** The mid-September measurements showed that memory bandwidth, not
the number of multipliers, set the time. Simply reusing weights already
loaded on chip gave 7.16x on the memory side with the same hardware.

The ECP5 had few DSP blocks and slow external memory. Version 2 was
frozen as a historical reference.

## 3. Artix-7 and real DDR3

From 16 September the target became the one used today: a **Xilinx
Artix-7 XC7A100T with real DDR3**, on a board designed and hand-assembled
by the author. The first real place & route on Artix-7 reached about
133 MHz: far from the 200 MHz goal, and without the DDR3 controller yet.

The next two weeks were precision work:

- the Xilinx DDR3 controller (MIG) generated for the exact part;
- the first complete system with DDR3 closing timing under the real MIG
  constraints (19 September: DDR3 at 310 MHz, logic at 155 MHz);
- a bridge to the configuration flash, so the ESP32 can update the FPGA;
- 8- and 16-group compute architectures with hierarchical arbiters;
- several layers chained directly on the FPGA (clean timing on
  23 September);
- the first ESP32 firmware component.

This period produced most of the project's hard-won rules: source copies
that Vivado imports and then silently stops updating, races between
testbench and design on the same clock edge, request pulses lost inside
a two-level arbiter. Each one cost at least a day, and each one was
found by following the signals one by one.

## 4. Version 4: an engine that never goes back to memory

On 28 September the approach changed. Version 3 computed in blocks:
read from DDR3, compute, write back to DDR3. On a real network that
traffic is the bottleneck, exactly as version 2 had warned.

Version 4 keeps the data inside the chip. Its heart is an engine that
runs a 3x3 depthwise convolution and hands the result straight to the
1x1 (pointwise) convolution without ever writing it to memory. The
pointwise part is a 16x16 multiplier array using a trick from v3: **two
INT8 multiplications in every DSP48 block**. Those 16 columns are the
accelerator's 16 compute units.

To measure it, we picked a benchmark: **MobileFaceNet**, a
face-recognition network. On an ESP32-S3 with Espressif's optimised
ESP-DL library it takes **248.8 ms**. The target: 100 times faster,
about 2.5 ms.

| Date | Step | Result |
|---|---|---|
| 28 Sep, afternoon | depthwise to pointwise engine, verified | bit-exact |
| 28 Sep, evening | the whole benchmark network in RTL | 451,287 cycles, bit-exact |
| 28 Sep, night | first core place & route | 150 MHz |
| 29 Sep | four rounds of pipelining | 157, 162, then **200 MHz** |
| 29 Sep | parameters streamed from DDR3, im2col on the FPGA | 200 MHz again |
| 29 Sep | full board simulated with the real MIG and Micron DDR3 models | complete network |
| 30 Sep | full board closes | **199.34 MHz** |

A note about the build server. Synthesis runs on "mikilab", an old iMac
running Ubuntu at home. On 28 September it powered off twice without
warning: the fan was stuck at minimum speed and the machine overheated.
Since then Vivado runs with the CPU capped at 2.4 GHz and a watchdog that
stops everything above 85 °C. Heat turned out to be a design constraint
twice over: for the machine that builds the chip, and for the chip
itself.

## 5. From chip to board

From 1 to 6 October the work spread from the chip to everything around
it.

- **ESP32 firmware.** The real ESP32 driver was compiled on a PC and
  made to talk to the board RTL in simulation: all 8 bring-up tests
  pass.
- **A real model.** A pretrained network from Espressif was converted
  for the accelerator, and the RTL produced exactly the same bits as the
  C reference model.
- **Tools.** A pass planner, a bit-exact numerical reference, training
  with the hardware's own arithmetic (quantisation-aware training), and
  a network compiler.
- **Boot.** The configuration flash had been placed on pins the FPGA
  cannot boot from. It moved to the dedicated Master SPI pins; booting
  from flash takes about 0.7 s.
- **One clock.** A single 200 MHz oscillator instead of two.
- **The module.** An 8-layer PCB in KiCad, a 40-pin board-to-board
  connector, a single 5 V input. Vivado's power report says the 1.0 V
  core rail draws 4.13 A (5.24 W total, vectorless *estimate*), so the
  module needs a 6 A regulator and a mandatory heatsink. The prototype
  will be assembled by hand: microscope, stencil, solder paste and a hot
  plate.

## 6. The turn: a generic accelerator

On 6 October everything stopped. The benchmark network was supposed to
be **only the yardstick**, not the product. Yet documents and RTL had
started treating it as the reason the accelerator existed. It was a
framing error, and a serious one: a month of work risked producing a
chip good for a single network.

The fix kept the architecture and removed the limits where they lived:
in counters, addresses and descriptors, not in the datapath. Five steps
over 6 and 7 October, each verified before the next:

1. input of any size;
2. 1 to 4,096 inputs per neuron, any number of channels;
3. dense 3x3 convolution anywhere, networks with no convolutions at all;
4. max and average pooling;
5. x2 upsampling, concatenation, up to 256 passes.

Then a final test: three generic networks (small, medium, heavy) plus
the benchmark, run on the FPGA in simulation and on a real ESP32-S3 CPU
in plain integer C++, producing identical bits. Ten runs each, all
bit-identical to the FPGA:

| Network | ESP32-S3, plain C++ | FPGA, simulated at 199.34 MHz | Ratio |
|---|---|---|---|
| small | 108.98 ms | 54 µs | ~2,000x |
| medium | 2.128 s | 415 µs | ~5,100x |
| heavy | 56.99 s | 12.29 ms | ~4,600x |
| MobileFaceNet | 10.316 s | 2.311 ms | ~4,500x |

Plain C++ is not the fair comparison, and we don't claim it is: the 100x
target stays measured against ESP-DL (248.8 ms), which uses the S3's
vector instructions. The same networks were also benchmarked on a
Raspberry Pi 5. A bit-exact NEON version runs the heavy network in
14.79 ms; ONNX Runtime with int8 (not bit-exact) runs it in 4.48 ms,
faster than the FPGA on that network, while on MobileFaceNet (12.18 ms on the Pi)
the FPGA stays 4 to 5 times ahead. Honest numbers, both ways.

## 7. Paying for area

New features cost silicon. The first place & route of the generic
version (7 October) **did not fit the chip, by 25 slices**. One
bitstream with every feature was the requirement, so the area came back
from the RTL: descriptors fetched from DDR3, a shared requantiser,
slimmer pooling and im2col. 6,774 LUTs saved without removing a single
function. The same day all host commands moved to the Quad-SPI link and
the separate management SPI was dropped.

The new layout fit (95.9% of slices) but missed timing by 1.93 ns at
199.34 MHz. About twenty targeted fixes followed, each verified bit for
bit on seven networks.

## 8. The depthwise that wasn't there

On 8 October, synthesis with the timing fixes stopped fitting: 102.5%
of LUTs, 142.5 of 135 block RAMs. The depthwise block had grown from
219 LUTs to 14,543.

The cause: **in every earlier board synthesis, Vivado had removed the
depthwise weight memory, and with it the whole depthwise path.** That
includes the bitstreams we had celebrated on 30 September. Vivado moved
a copy of the weight memory across module boundaries, lost its write
port on the way, decided the memory was constant, and propagated the
zero downstream. Every simulation had passed, because simulations ran
on the RTL, not on the synthesised netlist. The timing fixes broke that
chain by accident, and the depthwise path came back with its real cost.

No bitstream had ever been loaded on real hardware, so nothing physical
was lost. But every earlier area, timing and power number was a number
without depthwise.

The response:

- a simulation of the synthesised netlist, with the real MIG, that
  counts the weight writes and checks the depthwise multipliers against
  the RTL;
- the weight memory moved inside the module that reads it, so Vivado has
  nothing to move;
- area cuts that keep every function, all bit-exact on seven networks;
- the depthwise engine from 16 lanes down to 8 when 16 would not place.

A new rule came out of it: **no bitstream without a post-synthesis
netlist simulation** proving the parameter memories are actually
written.

The same evening, the first generic build with every parameter memory
driven closed timing at **189.15 MHz**. MobileFaceNet takes
515,968 cycles, **2.73 ms: about 91x faster than ESP-DL** on the
ESP32-S3. Short of 100x, and we say so.

## 9. Where we are (8 October 2026)

| What | Status |
|---|---|
| Generic RTL | verified in simulation, 11/11 tests, 7 networks bit-exact |
| Bitstream | generic build closes timing at 189.15 MHz; 199 MHz in progress |
| Benchmark network | 2.73 ms at 189.15 MHz, about 91x ESP-DL |
| CPU baselines | ESP32-S3, ESP32-C6, RP2350, Raspberry Pi 5, all archived |
| Physical module | 8-layer PCB in KiCad, DDR3 data lanes routed, address/clock routing in progress |
| Next | finish routing, fabricate, hand-assemble, bring up, run the first network on real silicon |

## 10. What we learned

- **Measure, don't estimate.** Every time a number was estimated instead
  of measured, the estimate was optimistic.
- **RTL simulation is not enough.** The synthesiser can remove logic the
  design really uses. Only the netlist tells you what is in the chip.
- **One step at a time.** Every change verified on its own before
  combining it with others. That is why bugs were found in hours, not
  weeks.
- **The example is not the product.** A benchmark is there to measure.
  If it becomes the project, the project shrinks without anyone deciding
  it.
- **Heat is a design constraint**, for the server that builds the chip
  and for the chip that computes.

---

*OpenNPU (born as FPGA-Neural) is designed and built by Michele (GitHub: manvalan). The RTL, tools and
documentation were developed with the help of Claude Code, an AI coding
assistant; every result was checked in simulation or on real tools
before it was written down.*
