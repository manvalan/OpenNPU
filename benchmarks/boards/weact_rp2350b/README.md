# Board WeAct Studio RP2350B Core Board V1.0

Board used for `benchmarks/rp2350_v4/` (campaigns
`results/*_weact_rp2350b_*`). Read from the board on 2026-10-07 with
picotool 5.0.0 (`picotool info -a`, in BOOTSEL) and from the running
benchmark (heap, PSRAM).

| Item | Value | Source |
|---|---|---|
| Board | WeAct Studio RP2350B Core Board, version 1.0 (factory test sketch printed "WeAct RP235B test") | Michele, factory firmware |
| SoC | Raspberry Pi RP2350, revision A2, package QFN80 (RP2350B) | picotool |
| CPUs | 2x Cortex-M33 or 2x Hazard3 RISC-V (selected at build time); one core used by the benchmark | picotool, arduino-pico |
| Chip id | 0x7a1e47a47214f256 (= USB serial number) | picotool, macOS ioreg |
| Flash | 16 MB (16384 KB), flash devinfo 0x0c00 | picotool |
| PSRAM | none (getPSRAMSize() = 0; no PSRAM defined for this board in arduino-pico 6.2.0) | serial log, boards.txt |
| Internal RAM | 514,480 bytes free heap at sketch start (ARM build) | serial log |
| Security | secure boot 0, debug enabled | picotool |
| USB | RP2350 native USB, `/dev/cu.usbmodem1101` on the Mac (2e8a:f00f with the factory sketch) | macOS ioreg |

Configuration used in the benchmarks: arduino-cli 1.5.0, arduino-pico
6.2.0, FQBN `rp2040:rp2040:weact_rp2350b:arch=<arm|riscv>,freq=150,opt=Optimize2`
(CPU 150 MHz, -O2), flashed with picotool `load -x -f`.
