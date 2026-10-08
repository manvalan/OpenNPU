# Board ESP32-C6 QFN40 rev 0.2, 8 MB flash, no PSRAM

Board designed by Michele, used for `benchmarks/esp32s3_v4/` (campaign
`results/*_esp32c6_qfn40_r02_8mb_*`). Read from the board itself on
2026-10-07 with esptool v4.12.0 / espefuse (raw outputs in this folder).

| Item | Value | Source |
|---|---|---|
| Board | custom board designed by Michele | Michele |
| SoC | ESP32-C6, QFN40, revision v0.2 (PKG_VERSION 0); single RISC-V HP core 160 MHz + LP core | `esptool_flash_id.txt`, `espefuse_summary.txt` |
| Features | Wi-Fi 6, BT 5 (LE), IEEE 802.15.4 | esptool |
| PSRAM | none (the ESP32-C6 has no PSRAM interface) | |
| Internal RAM | 451,104 bytes free heap at app start | measured, serial log |
| Flash | 8 MB external; JEDEC manufacturer 0x20, device 0x4017 | esptool flash_id |
| Crystal | 40 MHz | esptool |
| MAC | e8:f6:0a:fa:eb:a0 (EUI-64 e8:f6:0a:ff:fe:fa:eb:a0) | esptool read_mac |
| USB | the C6's own USB-Serial/JTAG (Espressif 303a:1001), `/dev/cu.usbmodem1101` on the Mac | esptool, macOS ioreg |
| Flashing | 460,800 baud | measured |

Configuration used in the benchmarks: `TARGET=esp32c6`,
`firmware/sdkconfig.defaults.esp32c6` (CPU 160 MHz) +
`firmware/sdkconfig.esp32c6_qfn40_r02_8mb` (8 MB flash), flash 80 MHz
DIO, ESP-IDF v5.3.5-1074-g045dd779fd3 on macOS (Apple silicon).
