# Board LOLIN S3 PRO

Third ESP32-S3 board used for `benchmarks/esp32s3_v4/` (campaigns
`results/*_lolin_s3_pro_*`). Read from the board on 2026-10-07/08 with
esptool v4.12.0 / espefuse (raw outputs in this folder) and, before it
was reflashed, from its MicroPython REPL.

| Item | Value | Source |
|---|---|---|
| Board | LOLIN S3 PRO | Michele; MicroPython machine string "LOLIN S3 PRO with ESP32S3" |
| SoC | ESP32-S3, QFN56, revision v0.1 | `esptool_flash_id.txt`, `espefuse_summary.txt` |
| Features | WiFi, BLE, embedded PSRAM 8 MB (AP_3v3) | esptool |
| PSRAM | 8 MB in-package, AP Memory 3.3 V, octal (ESP32-S3R8), 85 °C grade | eFuse PSRAM_CAP / PSRAM_VENDOR / PSRAM_TEMP |
| Flash | 16 MB external, quad (4 data lines), 3.3 V; JEDEC manufacturer 0xC8 (GigaDevice), device 0x4018 | esptool flash_id, eFuse FLASH_TYPE |
| Crystal | 40 MHz | esptool |
| MAC | f4:12:fa:cd:30:54 | esptool |
| USB | S3 native USB: TinyUSB CDC 303a:4001 under MicroPython, USB-Serial/JTAG 303a:1001 in download mode and with the benchmark, `/dev/cu.usbmodem1101` | macOS ioreg |
| Download mode | BOOT (IO0) held + RST (MicroPython 1.19.1 has no `machine.bootloader()`) | measured |

Firmware found on the board: MicroPython v1.19.1-669-gd4b9df176e
(2022-11-05), filesystem with only `boot.py`. Full 16 MB flash image
saved before reflashing on Michele's Mac,
`test-mac/backups/lolin_s3_pro_micropython_1.19.1_full16MB.bin`
(sha256 ed4f131720427579ccc1ddda6c41e47923b269c07b316f69e5f27339daa6719f,
`esptool verify_flash` OK). Restore:
`esptool.py --port <port> write_flash 0 lolin_s3_pro_micropython_1.19.1_full16MB.bin`.

Configuration used in the benchmarks: `firmware/sdkconfig.lolin_s3_pro`
(16 MB flash), CPU 240 MHz, octal PSRAM at 80 MHz, flash 80 MHz DIO,
ESP-IDF v5.3.5-1074-g045dd779fd3 on macOS (Apple silicon).
