#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Reads the CSV lines of each <net>.serial.log in a results folder and
   writes runs.csv (every run) and summary.csv (statistics + ratio to the
   FPGA time).  stats.py RESULTS_DIR [TAG]
   TAG: the line prefix to read (default CSV); another tag (e.g. CSV2 =
   ESP-DL on two cores, CSV4 = 4 threads) writes runs_TAG.csv and
   summary_TAG.csv."""
import csv, os, statistics as st, sys
R = sys.argv[1]
TAG = sys.argv[2] if len(sys.argv) > 2 else 'CSV'
SUF = '' if TAG == 'CSV' else '_' + TAG
# FPGA time per inference at 199.34 MHz (ms): cycle counts of the board
# testbench (Icarus + Micron DDR3 models), hardware/v4/docs/PROGRESS_LOG.md
FPGA_MS = {'bench_small': 0.054, 'bench_medium': 0.415, 'bench_heavy': 12.29, 'mfn': 2.311,
           'espressif_mfn': 2.311}   # Espressif's MobileFaceNet (ESP-DL), same architecture as mfn
rows = []
with open(os.path.join(R, 'runs%s.csv' % SUF), 'w', newline='') as f:
    w = csv.writer(f); w.writerow(['net', 'run', 'us', 'bit_exact'])
    for n, fpga in FPGA_MS.items():
        p = os.path.join(R, n + '.serial.log')
        if not os.path.exists(p):
            continue
        t, ok, rows_n = [], 0, []
        for l in open(p, errors='replace'):
            if 'rst:0x' in l:       # the board rebooted (e.g. a crash): keep the last boot only
                t, ok, rows_n = [], 0, []
            if l.startswith(TAG + ','):
                _, r, us, b = l.strip().split(','); rows_n.append([n, r, us, b])
                t.append(int(us) / 1000); ok += int(b)
        for row in rows_n:
            w.writerow(row)
        if len(t) > 1:
            rows.append((n, len(t), ok, min(t), st.mean(t), st.median(t), st.stdev(t), max(t), t[0], fpga, min(t) / fpga))
hdr = 'net,runs,bit_exact,min_ms,mean_ms,median_ms,std_ms,max_ms,run0_ms,fpga_ms,ratio_s3_fpga'
with open(os.path.join(R, 'summary%s.csv' % SUF), 'w') as f:
    f.write(hdr + '\n'); print(hdr)
    for r in rows:
        s = '%s,%d,%d,%.3f,%.3f,%.3f,%.4f,%.3f,%.3f,%.3f,%.1f' % r
        f.write(s + '\n'); print(s)
