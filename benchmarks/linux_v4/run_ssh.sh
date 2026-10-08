#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# Measures the v4 networks on a Linux board over SSH (e.g. a Raspberry Pi):
# copies v4net.cpp + the host runner + the net.bin inputs, builds with the
# board's own g++ -O2, runs each network 10 times, saves the logs and the
# board identity, then writes the statistics (same format as esp32s3_v4).
#   ./run_ssh.sh user@host OUTDIR [net ...]
# CXXFLAGS="-O3 -mcpu=native -fopenmp" THREADS=4 ...  build flags and OpenMP
# threads (default -O2, 1 thread; the OpenMP build stays bit-exact).
# With SSHPASS set (and sshpass installed) it logs in with that password.
set -e
ssh() { ${SSHPASS:+sshpass -e} /usr/bin/ssh ${SSHPASS:+-o PubkeyAuthentication=no} "$@"; }
scp() { ${SSHPASS:+sshpass -e} /usr/bin/scp ${SSHPASS:+-o PubkeyAuthentication=no} "$@"; }
HERE=$(cd "$(dirname "$0")" && pwd)
S3=$HERE/../esp32s3_v4
H=$1; OUT=$(mkdir -p "$2" && cd "$2" && pwd); shift 2
NETS=${@:-bench_small bench_medium bench_heavy mfn}
RUNS=${RUNS:-10}
CXXFLAGS=${CXXFLAGS:--O2}
THREADS=${THREADS:-1}
D=v4bench
ssh "$H" "mkdir -p $D/nets"
scp -q "$S3/firmware/main/v4net.cpp" "$S3/firmware/main/v4net.hpp" "$S3/firmware/host/main_host.cpp" "$H:$D/"
for n in $NETS; do ssh "$H" "mkdir -p $D/nets/$n"; scp -q "$S3/nets/$n/net.bin" "$H:$D/nets/$n/"; done
ssh "$H" "cd $D && g++ $CXXFLAGS -std=c++17 -I. main_host.cpp v4net.cpp -o v4net_host" 2>&1 | tee "$OUT/build.log"
ssh "$H" "cat /proc/device-tree/model 2>/dev/null; echo; uname -a; g++ --version | head -1; grep -m1 -iE 'model name|Processor' /proc/cpuinfo; grep -iE 'Hardware|Revision|Serial' /proc/cpuinfo; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null; free -b | head -2; vcgencmd measure_clock arm 2>/dev/null; vcgencmd measure_temp 2>/dev/null" > "$OUT/board.txt" 2>&1
echo "config: ssh $H, g++ $CXXFLAGS on the board, OMP_NUM_THREADS=$THREADS, $RUNS runs" > "$OUT/config.txt"
for n in $NETS; do
  echo "=== $n"
  ssh "$H" "cd $D && OMP_NUM_THREADS=$THREADS OMP_PROC_BIND=true ./v4net_host nets/$n/net.bin $RUNS" > "$OUT/$n.serial.log" 2>&1 || true
  tail -1 "$OUT/$n.serial.log"
done
ssh "$H" "vcgencmd measure_temp 2>/dev/null; vcgencmd get_throttled 2>/dev/null" >> "$OUT/board.txt" 2>&1 || true
python3 "$S3/stats.py" "$OUT"
