#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# Builds, flashes and measures each network on an RP2350 board, then
# writes the statistics (same nets, capture and stats as ../esp32s3_v4).
#   ./run_rp2350.sh PORT OUTDIR [net ...]
# FQBN=rp2040:rp2040:weact_rp2350b (default), ARCH=arm|riscv (default arm),
# FREQ=150 (MHz, default). Needs arduino-cli with the arduino-pico core.
# CTAGS_DIR=/opt/homebrew/bin on Apple silicon without Rosetta (Homebrew
# universal-ctags instead of the x86 ctags bundled with arduino-cli).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
S3=$HERE/../esp32s3_v4
PORT=$1; OUT=$(mkdir -p "$2" && cd "$2" && pwd); shift 2
NETS=${@:-bench_small bench_medium bench_heavy mfn}
FQBN="${FQBN:-rp2040:rp2040:weact_rp2350b}:arch=${ARCH:-arm},freq=${FREQ:-150},opt=Optimize2"
PICOTOOL=$(ls -d ~/Library/Arduino15/packages/rp2040/tools/pqt-picotool/*/ | tail -1)picotool
PY=${PY:-python3}
echo "config: $FQBN, arduino-pico $(ls ~/Library/Arduino15/packages/rp2040/hardware/rp2040/)" | tee "$OUT/config.txt"
SK=$HERE/v4_rp2350
for n in $NETS; do
  echo "=== $n"
  printf '    .section .rodata.net_bin, "a"\n    .global net_bin_start\n    .global net_bin_end\n    .balign 4\nnet_bin_start:\n    .incbin "%s"\nnet_bin_end:\n' "$S3/nets/$n/net.bin" > "$SK/net_bin.S"
  arduino-cli compile -b "$FQBN" --build-path "$HERE/build" \
      --build-property "compiler.cpp.extra_flags=-I$S3/firmware/main" \
      ${CTAGS_DIR:+--build-property "tools.ctags.path=$CTAGS_DIR"} "$SK" > "$OUT/$n.build.log" 2>&1
  # 1200-baud touch: the running sketch reboots into BOOTSEL
  [ -e "$PORT" ] && $PY -c "import serial,time; s=serial.Serial('$PORT',1200); s.dtr=False; time.sleep(0.2); s.close()" || true
  for i in $(seq 1 50); do "$PICOTOOL" info > /dev/null 2>&1 && break; sleep 0.2; done
  "$PICOTOOL" load -x "$HERE/build/v4_rp2350.ino.uf2" > "$OUT/$n.flash.log" 2>&1
  sleep 2
  for i in $(seq 1 50); do [ -e "$PORT" ] && break; sleep 0.2; done
  $PY "$S3/capture.py" "$PORT" "$OUT/$n.serial.log" 1800 --no-reset | grep -E 'chip |network:|RESULT|DIFFERENT|out of memory' || true
done
rm -f "$SK/net_bin.S"
python3 "$S3/stats.py" "$OUT"
