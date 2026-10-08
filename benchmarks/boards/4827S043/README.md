# Board 4827S043 (ESP32-S3 with display)

Board used for the ESP32-S3 measurements in `benchmarks/esp32s3_v4/`
(campaigns `results/*_4827S043_*`). Read from the board itself on
2026-10-07 with esptool v4.12.0 / espefuse (raw outputs in this folder).

| Item | Value | Source |
|---|---|---|
| Board | 4827S043 (ESP32-S3 board with a display) | board marking |
| SoC | ESP32-S3, QFN56, revision v0.1 (wafer 0.1, PKG_VERSION 0) | `esptool_flash_id.txt`, `espefuse_summary.txt` |
| Features | WiFi, BLE, embedded PSRAM 8 MB (AP_3v3) | esptool |
| PSRAM | 8 MB in-package, AP Memory 3.3 V, octal (ESP32-S3R8), 85 °C grade | eFuse PSRAM_CAP / PSRAM_VENDOR / PSRAM_TEMP |
| Flash | 16 MB external, quad (4 data lines), 3.3 V; JEDEC manufacturer 0xC8 (GigaDevice), device 0x4018 | esptool flash_id, eFuse FLASH_TYPE |
| Crystal | 40 MHz | esptool |
| MAC | f4:12:fa:e1:d6:38 | esptool read_mac |
| USB-serial bridge | WCH CH340 (USB 1a86:7523), `/dev/cu.usbserial-110` on the Mac | macOS ioreg |
| Flashing | 460,800 baud (921,600 fails on this bridge) | measured |

Configuration used in the benchmarks (`benchmarks/esp32s3_v4/firmware`):
CPU 240 MHz, octal PSRAM at 80 MHz, flash 80 MHz DIO, 16 MB flash
(`sdkconfig.4827S043`), ESP-IDF v5.3.5-1074-g045dd779fd3 on macOS
(Apple silicon).

The display and touch controller are not used by the benchmarks.
