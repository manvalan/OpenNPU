# esp32s3_v4 — v4 networks on the ESP32-S3 (and ESP32-C6) CPU

Same network, same integer arithmetic as the FPGA (`firmware/main/v4net.cpp`,
C++ twin of `hardware/v4/model/v4_ref.py`): the S3 output is compared byte
for byte with the FPGA's expected output, and each inference is timed with
`esp_timer`. Plain portable C++ (no SIMD, no ESP-DL), CPU at 240 MHz.

## Layout

| Path | Content |
|---|---|
| `firmware/` | ESP-IDF app (see `firmware/README.md`); 10 runs per network, one `CSV,run,us,bit_exact` line per run |
| `firmware/sdkconfig.defaults.<target>` | per-chip settings: esp32s3 (240 MHz, octal PSRAM), esp32c6 (160 MHz) |
| `firmware/sdkconfig.<board>` | board overlay (`BOARD=<board>`, default 4827S043): 16 MB flash; PSRAM 8 MB octal is the default |
| `firmware/sdkconfig.psram` | variant overlay: net.bin copied to PSRAM at boot instead of read from flash |
| `nets/<net>/net.bin` | the exact inputs measured: network + parameters + input + expected FPGA output (from `v4_test_finale`, same files as the FPGA test) |
| `run_all.sh` | build + flash + capture for each network, then `stats.py` |
| `capture.py` | resets the board, saves the serial log until `RESULT` |
| `stats.py` | `runs.csv` (every run) + `summary.csv` (min/mean/median/std/max, ratio to FPGA) |
| `results/<date>_<board>_<variant>/` | raw serial logs + CSVs of one measurement campaign |

## Run

```
./run_all.sh /dev/cu.usbserial-110 results/$(date +%F)_4827S043_flash
OVERLAY=sdkconfig.psram ./run_all.sh /dev/cu.usbserial-110 results/$(date +%F)_4827S043_psram
BOARD=lilygo_t5_47 ./run_all.sh /dev/cu.usbmodem1101 results/$(date +%F)_lilygo_t5_47_flash
TARGET=esp32c6 BOARD=esp32c6_qfn40_r02_8mb ./run_all.sh /dev/cu.usbmodem1101 results/$(date +%F)_esp32c6_qfn40_r02_8mb_flash
```

## Results

Report with tables and sources: [`docs/benchmarks/ESP32S3_V4.md`](../../docs/benchmarks/ESP32S3_V4.md).

| Campaign | Variant |
|---|---|
| `results/2026-10-07_4827S043_flash/` | weights read from flash (default) |
| `results/2026-10-07_4827S043_psram/` | weights copied to PSRAM (`OVERLAY=sdkconfig.psram`) |
| `results/2026-10-07_lilygo_t5_47_flash/` | LilyGo T5 4.7", weights read from flash |
| `results/2026-10-07_lilygo_t5_47_psram/` | LilyGo T5 4.7", weights copied to PSRAM |
| `results/2026-10-08_lolin_s3_pro_flash/`, `_psram/` | LOLIN S3 PRO, weights from flash / in PSRAM |
| `results/2026-10-08_lilygo_t5_47_b_flash/`, `_psram/` | second LilyGo T5 4.7", weights from flash / in PSRAM |
| `results/2026-10-07_esp32c6_qfn40_r02_8mb_flash/` | ESP32-C6 (no PSRAM): bench_small only, the other three out of memory |
