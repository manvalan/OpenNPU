# rp2350_v4 — v4 networks on the RP2350 CPU

The RP2350 twin of [`../esp32s3_v4/`](../esp32s3_v4/): same `v4net.cpp`
(FPGA integer arithmetic, compiled in from `../esp32s3_v4/firmware/main`),
same `net.bin` inputs (`../esp32s3_v4/nets/`), same capture and statistics
scripts, same serial output (one `CSV,run,us,bit_exact` line per run).
10 runs per network, timed with `time_us_64()`, weights read in place from
flash (XIP), activations in the internal SRAM (`malloc`).

| Path | Content |
|---|---|
| `v4_rp2350/bench.cpp` | the benchmark (setup/loop); the `.ino` is empty on purpose |
| `v4_rp2350/v4net_impl.cpp` | pulls in the shared `v4net.cpp` |
| `run_rp2350.sh` | per network: writes `net_bin.S` (`.incbin` of the net.bin), builds with arduino-cli, reboots the board into BOOTSEL (1200-baud touch), flashes with picotool, captures, then `stats.py` |
| `results/<date>_<board>_<arch>/` | raw serial logs + CSVs |

## Run (Apple silicon)

Needs arduino-cli with the arduino-pico core (`rp2040:rp2040`) and
Homebrew `universal-ctags`: the ctags bundled with arduino-cli (and the
Arduino IDE) is x86-only and does not run without Rosetta.

```
CTAGS_DIR=/opt/homebrew/bin/ ./run_rp2350.sh /dev/cu.usbmodem1101 results/$(date +%F)_weact_rp2350b_arm
```

Options: `FQBN=` (default `rp2040:rp2040:weact_rp2350b`), `ARCH=arm|riscv`,
`FREQ=150`. Build is `-O2` (`opt=Optimize2`).

## Results

Report: [`docs/benchmarks/ESP32S3_V4.md`](../../docs/benchmarks/ESP32S3_V4.md).
Board: [`../boards/weact_rp2350b/`](../boards/weact_rp2350b/).
