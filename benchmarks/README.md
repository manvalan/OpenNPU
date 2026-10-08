# Benchmarks

Every performance number quoted in this project that was **measured on
real hardware** comes from a folder here: the code that ran, the exact
inputs, and the raw logs. Nothing in here is an estimate.

| Folder | What | Hardware |
|---|---|---|
| `espdl_v4/` | the v4 nets with ESP-DL on the S3 (accelerated, not bit-exact): ONNX/ESP-PPQ export, bench app, accuracy | ESP32-S3: LilyGo T5 4.7" |
| `linux_v4/` | same v4 bench on a Linux board over SSH (shares v4net.cpp, nets, stats with esp32s3_v4) | Raspberry Pi 5 8 GB |
| `rp2350_v4/` | same v4 bench on the RP2350 CPU (shares v4net.cpp, nets, scripts with esp32s3_v4) | RP2350: WeAct RP2350B Core Board V1.0 |
| `esp32s3_v4/` | v4 networks on the ESP32-S3 CPU, FPGA integer arithmetic, bit-exact check | ESP32-S3: 4827S043, LilyGo T5 4.7" (2 units), LOLIN S3 PRO; ESP32-C6: Michele's board |

`ALL_RESULTS.csv` (rebuilt by `make_all_results.py`): every campaign in one table (one row per board, variant and network, with status, statistics, FPGA ratio and the folder it comes from). Archived campaigns are tagged in git (`bench-cpu-2026-10-08`: all plain C++ CPU measurements of 2026-10-07/08; `bench-accel-2026-10-08`: adds the accelerated ones).

Boards used, with their identity read from the chip: `boards/<board>/`.

Written reports: `../docs/benchmarks/`.

FPGA synthesis/P&R sweeps are in `../benchmark_results/`; FPGA cycle
counts come from the board testbench, logged in
`../hardware/v4/docs/PROGRESS_LOG.md`.
