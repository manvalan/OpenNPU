# Board Raspberry Pi 5 Model B, 8 GB

Linux board used for `benchmarks/linux_v4/` (campaign
`results/2026-10-08_rpi5_8gb/`). Read from the board over SSH on
2026-10-08 (raw output in `board_info.txt`, collected by `run_ssh.sh`).

| Item | Value | Source |
|---|---|---|
| Board | Raspberry Pi 5 Model B Rev 1.0, revision code d04170 (8 GB) | /proc/device-tree/model, /proc/cpuinfo |
| SoC | BCM2712, 4x Cortex-A76, 2.4 GHz (vcgencmd arm = 2,400,020,480 Hz), governor ondemand; the benchmark is single-threaded | sysfs, vcgencmd |
| RAM | 8 GB (8,454,733,824 bytes) | free |
| OS | Debian 12 (bookworm), kernel 6.12.87+rpt-rpi-2712, aarch64; hostname plastico | uname |
| Compiler | g++ 12.2.0 (Debian), `-O2 -std=c++17` | g++ --version |
| Serial | b8e976d92aee37f2 | /proc/cpuinfo |
| Thermal | 43.3 °C before and after the runs, get_throttled = 0x0 | vcgencmd |
| Address | 192.168.x.x on Michele's LAN (user rail) | |
