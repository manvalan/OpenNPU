#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# ONNX Runtime on a Linux board over SSH: for each network, the float
# ONNX (fp32) and its static INT8 quantization (quantize_ort.py) run with
# 1 and 4 threads, 10 runs each, on the net.bin input. Needs a venv with
# onnxruntime at ~/v4bench/venv on the board.
#   ./run_ort_ssh.sh user@host OUTDIR_PREFIX [net ...]
# -> OUTDIR_PREFIX_fp32/ and OUTDIR_PREFIX_int8/, stats per thread count
#    (summary_CSV1.csv, summary_CSV4.csv). SSHPASS: password login.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
B=$HERE/../..
ssh() { ${SSHPASS:+sshpass -e} /usr/bin/ssh ${SSHPASS:+-o PubkeyAuthentication=no} "$@"; }
scp() { ${SSHPASS:+sshpass -e} /usr/bin/scp ${SSHPASS:+-o PubkeyAuthentication=no} "$@"; }
H=$1; PRE=$2; shift 2
NETS=${@:-bench_small bench_medium bench_heavy mfn}
D=v4bench/ort
ssh "$H" "mkdir -p $D"
scp -q "$HERE/bench_ort.py" "$H:$D/"
for v in fp32 int8; do
  OUT=$(mkdir -p "${PRE}_$v" && cd "${PRE}_$v" && pwd)
  echo "config: ssh $H, ONNX Runtime CPU EP, $v, threads 1 and 4, 10 runs, warm-up run excluded" > "$OUT/config.txt"
  ssh "$H" "~/v4bench/venv/bin/python -c 'import onnxruntime as o; print(\"onnxruntime\", o.__version__)'; cat /proc/device-tree/model; echo; vcgencmd measure_temp; vcgencmd get_throttled" >> "$OUT/config.txt" 2>&1 || true
  for n in $NETS; do
    m=model.onnx; [ $v = int8 ] && m=model_ort_int8.onnx
    ssh "$H" "mkdir -p $D/$n"
    scp -q "$B/espdl_v4/models/$n/$m" "$B/esp32s3_v4/nets/$n/net.bin" "$H:$D/$n/"
    echo "=== $v $n"
    ssh "$H" "cd $D/$n && ~/v4bench/venv/bin/python ../bench_ort.py $m net.bin 10 1 4" > "$OUT/$n.serial.log" 2>&1 || true
    grep RESULT "$OUT/$n.serial.log" || tail -3 "$OUT/$n.serial.log"
  done
  python3 "$B/esp32s3_v4/stats.py" "$OUT" CSV1 > /dev/null
  python3 "$B/esp32s3_v4/stats.py" "$OUT" CSV4 > /dev/null
done
