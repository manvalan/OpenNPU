# Board LilyGo T5 4.7" e-paper, second unit (ESP32-S3, native USB)

Second LilyGo T5 4.7" (same model as ../lilygo_t5_47/), used for `benchmarks/esp32s3_v4/` (campaigns
`results/*_lilygo_t5_47_b_*`). Read from the board itself on
2026-10-08 with esptool v4.12.0 / espefuse (raw outputs in this folder).

| Item | Value | Source |
|---|---|---|
| Board | LilyGo T5 4.7 inch e-paper, ESP32-S3 version | Michele |
| SoC | ESP32-S3, QFN56, revision v0.1 (wafer 0.1, PKG_VERSION 0) | `esptool_flash_id.txt`, `espefuse_summary.txt` |
| Features | WiFi, BLE, embedded PSRAM 8 MB (AP_3v3) | esptool |
| PSRAM | 8 MB in-package, AP Memory 3.3 V, octal (ESP32-S3R8), 85 °C grade | eFuse PSRAM_CAP / PSRAM_VENDOR / PSRAM_TEMP |
| Flash | 16 MB external, quad (4 data lines), 3.3 V; JEDEC manufacturer 0xC8 (GigaDevice), device 0x4018 | esptool flash_id, eFuse FLASH_TYPE |
| Crystal | 40 MHz | esptool |
| MAC | 34:85:18:9d:ec:c0 | esptool read_mac |
| USB | the S3's own USB-Serial/JTAG (Espressif 303a:1001), `/dev/cu.usbmodem1101` on the Mac; console on the secondary USB-Serial/JTAG output | esptool, macOS ioreg |
| Flashing | 460,800 baud | measured |

Configuration used in the benchmarks: `firmware/sdkconfig.lilygo_t5_47_b`
(16 MB flash), CPU 240 MHz, octal PSRAM at 80 MHz, flash 80 MHz DIO,
ESP-IDF v5.3.5-1074-g045dd779fd3 on macOS (Apple silicon). Same chip
configuration as `../4827S043/`.

Original firmware: full 16 MB flash image saved before the benchmarks on Michele's Mac, `test-mac/backups/s3_349decc0_full.bin` (sha256 96acb9f6f61283da842f84a6c76761248adfac2f2869bd343003aa8502d31290, `verify_flash` OK), and written back after them (`verify_flash` OK).
