#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# Builds, flashes and measures each model with ESP-DL on an ESP32-S3:
# 10 runs on one core (CSV) and 10 on both cores (CSV2), then statistics
# and accuracy (compare.py). Needs ESP-IDF 5.3+ (IDF_PATH) and pyserial;
# compare.py needs numpy.
#   ./run_espdl.sh PORT OUTDIR [model ...]
# model = a folder of models/: bench_small bench_medium bench_heavy mfn
# (export_espdl.py) or espressif_mfn (Espressif's own trained MobileFaceNet,
# fed the mfn net.bin image: timing only).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
S3=$HERE/../esp32s3_v4
PORT=$1; OUT=$(mkdir -p "$2" && cd "$2" && pwd); shift 2
MODELS=${@:-bench_small bench_medium bench_heavy mfn espressif_mfn}
PY=${PY:-python3}
source "$IDF_PATH/export.sh" >/dev/null 2>&1
cd "$HERE/firmware"
echo "config: ESP-DL $(grep '^version' managed_components/espressif__esp-dl/idf_component.yml | awk '{print $2}' | tr -d \"\'), sdkconfig.defaults (240 MHz, octal PSRAM 80 MHz, QIO flash 80 MHz, 64 KB D-cache)" | tee "$OUT/config.txt"
for m in $MODELS; do
  net=$m; [ $m = espressif_mfn ] && net=mfn
  echo "=== $m"
  idf.py -D ESPDL_MODEL="$HERE/models/$m/model.espdl" -D V4_NETBIN="$S3/nets/$net/net.bin" build > "$OUT/$m.build.log" 2>&1
  idf.py -p "$PORT" -b 460800 flash > "$OUT/$m.flash.log" 2>&1
  $PY "$S3/capture.py" "$PORT" "$OUT/$m.serial.log" 1800 | grep -E "test\(\)|input |RESULT|E \(" || true
done
python3 "$S3/stats.py" "$OUT" CSV > /dev/null
python3 "$S3/stats.py" "$OUT" CSV2 > /dev/null
${PYNUM:-python3} "$HERE/compare.py" "$OUT" || true
