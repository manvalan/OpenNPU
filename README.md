# OpenNPU

**A generic INT8 neural-network accelerator on a Xilinx Artix-7
XC7A100T with DDR3, driven by an ESP32-S3.**

You design the network (input size, layers, up to 4,096 inputs per
neuron, 256 passes), the tools compile it, the ESP32 loads it, and 16
compute units run it with the data kept on chip between layers.

| | |
|---|---|
| FPGA | Xilinx Artix-7 XC7A100T-CSG324-2 |
| Memory | 2x DDR3 (32-bit), MIG at 310 MHz |
| Compute | 16 compute units, 2 INT8 MACs per DSP48, 3x3 depthwise + 1x1 pointwise fused engine, dense 3x3, pooling, upsample, concat |
| Clock | 189.15 MHz (timing closed; bitstream still under netlist verification) |
| Host link | Quad-SPI to an ESP32-S3 |
| Benchmark | MobileFaceNet in 2.73 ms at 189.15 MHz (full-board RTL simulation), about 91x faster than ESP-DL on the ESP32-S3 (248.8 ms) |

**Status (October 2026):** RTL verified in simulation, bit-exact on 7
networks. A generic build closes timing at 189.15 MHz, but the
simulation of its synthesised netlist does not yet match the RTL, so no
bitstream is published until that is fixed. The 8-layer hardware module
is being routed in KiCad. Nothing has run on real silicon yet.

## Read first

| | |
|---|---|
| 📖 **[The story](STORY.md)** | How a single neuron became a generic accelerator in five weeks, mistakes included. Start here. |
| 📓 **[The lab diary](hardware/v4/docs/PROGRESS_LOG.md)** | Every verified step, one entry each, with the measured numbers, the failed attempts and how each bug was found. |
| 📘 **[The Buildbook](hardware/v4/docs/buildbook/FPGA-Neural-V4-Buildbook.md)** ([PDF](hardware/v4/docs/buildbook/FPGA-Neural-V4-Buildbook.pdf)) | The full technical reference: architecture, programming model, limits, performance, pinout, power, firmware, network design and training (Italian; English translation planned). |
| 🔧 **[How the engine works](hardware/v4/docs/COME_FUNZIONA_G_ESTESO.md)** · **[Pinout](hardware/v4/docs/PINOUT_V4.md)** · **[Bitstream](hardware/v4/bitstream/README.md)** | Focused documents for hardware builders (Italian). |
| 📊 **[Benchmarks](benchmarks/README.md)** | The same networks on ESP32-S3, ESP32-C6, RP2350 and Raspberry Pi 5, raw results included. |

Every number in these documents is measured (simulation, synthesis,
place & route or real CPU runs) unless marked as an estimate.

## Repository layout

| Folder | Content |
|---|---|
| `hardware/v4/rtl` | synthesisable Verilog |
| `hardware/v4/sim` | Icarus and xsim testbenches, regression scripts, ESP32 co-simulation |
| `hardware/v4/model` | C golden model, network planner, compiler, quantisation-aware training |
| `hardware/v4/constr`, `hardware/v4/vivado` | constraints and Vivado scripts |
| `hardware/v4/bitstream` | bitstreams, published once they pass netlist simulation |
| `hardware/v4/docs` | technical documentation (mostly Italian), progress log, Buildbook |
| `firmware/esp32` | ESP-IDF driver and bring-up firmware |
| `benchmarks` | the same networks on ESP32-S3, ESP32-C6, RP2350 and Raspberry Pi 5 |
| `hardware/pcb` | **coming soon:** KiCad files of the 8-layer module, published after bring-up |

OpenNPU grew out of the author's FPGA-Neural research project; this
repository is published automatically from that private working
repository.

## License

| Files | License |
|---|---|
| Hardware: RTL, constraints, PCB | [CERN-OHL-S-2.0](LICENSES/CERN-OHL-S-2.0.txt) |
| Software: tools, firmware, scripts | [MIT](LICENSES/MIT.txt) |
| Documentation and images | [CC BY 4.0](LICENSES/CC-BY-4.0.txt) |

Every source file has an SPDX header. Third-party material is listed in
[NOTICE](NOTICE).

**Commercial licensing available:** to use the hardware design in a
closed product, see [COMMERCIAL_LICENSE.md](COMMERCIAL_LICENSE.md).

Contributions are welcome, see [CONTRIBUTING.md](CONTRIBUTING.md). To
cite the project, use [CITATION.cff](CITATION.cff).
