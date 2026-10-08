#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# Builds, flashes and measures each network on the ESP32-S3, then writes
# the statistics. Needs ESP-IDF 5.x (IDF_PATH set) and pyserial.
#   ./run_all.sh PORT OUTDIR [net ...]    default nets: all four in nets/
# TARGET=esp32c6 builds for another chip (default esp32s3; sdkconfig.defaults.<target>)
# BOARD=<name> uses firmware/sdkconfig.<name> (default 4827S043)
# OVERLAY=sdkconfig.psram ./run_all.sh ... adds a config overlay (e.g. the
# network copied to PSRAM instead of read from flash)
# Example: ./run_all.sh /dev/cu.usbserial-110 results/$(date +%F)_myboard
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PORT=$1; OUT=$(mkdir -p "$2" && cd "$2" && pwd); shift 2
NETS=${@:-bench_small bench_medium bench_heavy mfn}
source "$IDF_PATH/export.sh" >/dev/null 2>&1
cd "$HERE/firmware"
mkdir -p net
rm -f sdkconfig   # rebuild the config from the defaults + overlays
DEFAULTS="sdkconfig.defaults;sdkconfig.${BOARD:-4827S043}${OVERLAY:+;$OVERLAY}"
echo "config: ${TARGET:-esp32s3}, $DEFAULTS" | tee "$OUT/config.txt"
idf.py -D SDKCONFIG_DEFAULTS="$DEFAULTS" set-target ${TARGET:-esp32s3} > "$OUT/set-target.log" 2>&1
for n in $NETS; do
  echo "=== $n"
  cp "$HERE/nets/$n/net.bin" net/net.bin
  idf.py -D SDKCONFIG_DEFAULTS="$DEFAULTS" build > "$OUT/$n.build.log" 2>&1
  idf.py -p "$PORT" -b 460800 flash > "$OUT/$n.flash.log" 2>&1
  python "$HERE/capture.py" "$PORT" "$OUT/$n.serial.log" | grep -E 'chip |network:|net.bin|RESULT|DIFFERENT|out of memory' || true
done
python3 "$HERE/stats.py" "$OUT"
