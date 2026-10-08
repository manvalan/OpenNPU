#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Rebuilds ALL_RESULTS.csv: one row per campaign x network (x thread /
core count), from every results folder's summary*.csv, with status
(ok / out of memory / not run), bit-exactness and the source folder.
Run after adding a campaign:  python3 make_all_results.py"""
import csv
import glob
import os

HERE = os.path.dirname(os.path.abspath(__file__))
NETS = ['bench_small', 'bench_medium', 'bench_heavy', 'mfn', 'espressif_mfn']
P = 'plain C++ v4net.cpp (FPGA arithmetic, bit-exact)'
# folder, board, chip, implementation, variant, {summary tag: parallelism}
CAMPAIGNS = [
    ('esp32s3_v4/results/2026-10-07_4827S043_flash', '4827S043', 'ESP32-S3 240 MHz', P, 'weights in flash', {'': '1 core'}),
    ('esp32s3_v4/results/2026-10-07_4827S043_psram', '4827S043', 'ESP32-S3 240 MHz', P, 'weights in PSRAM', {'': '1 core'}),
    ('esp32s3_v4/results/2026-10-07_lilygo_t5_47_flash', 'lilygo_t5_47', 'ESP32-S3 240 MHz', P, 'weights in flash', {'': '1 core'}),
    ('esp32s3_v4/results/2026-10-07_lilygo_t5_47_psram', 'lilygo_t5_47', 'ESP32-S3 240 MHz', P, 'weights in PSRAM', {'': '1 core'}),
    ('esp32s3_v4/results/2026-10-08_lolin_s3_pro_flash', 'lolin_s3_pro', 'ESP32-S3 240 MHz', P, 'weights in flash', {'': '1 core'}),
    ('esp32s3_v4/results/2026-10-08_lolin_s3_pro_psram', 'lolin_s3_pro', 'ESP32-S3 240 MHz', P, 'weights in PSRAM', {'': '1 core'}),
    ('esp32s3_v4/results/2026-10-08_lilygo_t5_47_b_flash', 'lilygo_t5_47_b', 'ESP32-S3 240 MHz', P, 'weights in flash', {'': '1 core'}),
    ('esp32s3_v4/results/2026-10-08_lilygo_t5_47_b_psram', 'lilygo_t5_47_b', 'ESP32-S3 240 MHz', P, 'weights in PSRAM', {'': '1 core'}),
    ('esp32s3_v4/results/2026-10-07_esp32c6_qfn40_r02_8mb_flash', 'esp32c6_qfn40_r02_8mb', 'ESP32-C6 160 MHz', P, 'weights in flash', {'': '1 core'}),
    ('rp2350_v4/results/2026-10-07_weact_rp2350b_arm', 'weact_rp2350b', 'RP2350 Cortex-M33 150 MHz', P, 'weights in flash', {'': '1 core'}),
    ('linux_v4/results/2026-10-08_rpi5_8gb', 'rpi5_8gb', 'BCM2712 Cortex-A76 2.4 GHz', P, 'g++ -O2', {'': '1 thread'}),
    ('linux_v4/results/2026-10-08_rpi5_8gb_o3neon_1t', 'rpi5_8gb', 'BCM2712 Cortex-A76 2.4 GHz', P, 'g++ -O3 -mcpu=cortex-a76 (NEON)', {'': '1 thread'}),
    ('linux_v4/results/2026-10-08_rpi5_8gb_o3neon_omp4t', 'rpi5_8gb', 'BCM2712 Cortex-A76 2.4 GHz', P, 'g++ -O3 -mcpu=cortex-a76 (NEON) + OpenMP', {'': '4 threads'}),
    ('linux_v4/results/2026-10-08_rpi5_8gb_ort_fp32', 'rpi5_8gb', 'BCM2712 Cortex-A76 2.4 GHz', 'ONNX Runtime 1.30 fp32 (not bit-exact)', 'CPU EP', {'_CSV1': '1 thread', '_CSV4': '4 threads'}),
    ('linux_v4/results/2026-10-08_rpi5_8gb_ort_int8', 'rpi5_8gb', 'BCM2712 Cortex-A76 2.4 GHz', 'ONNX Runtime 1.30 int8 QDQ (not bit-exact)', 'CPU EP', {'_CSV1': '1 thread', '_CSV4': '4 threads'}),
    ('espdl_v4/results/2026-10-08_4827S043_espdl', '4827S043', 'ESP32-S3 240 MHz', 'ESP-DL 3.3.13 int8, ESP-PPQ (not bit-exact)', 'SIMD/PIE', {'': '1 core', '_CSV2': '2 cores (MobileFaceNet unstable: crashes, wrong output)'}),
    ('espdl_v4/results/2026-10-08_lilygo_t5_47_b_espdl', 'lilygo_t5_47_b', 'ESP32-S3 240 MHz', 'ESP-DL 3.3.13 int8, ESP-PPQ (not bit-exact)', 'SIMD/PIE', {'': '1 core', '_CSV2': '2 cores (MobileFaceNet unstable: crash loop)'}),
    ('espdl_v4/results/2026-10-08_lilygo_t5_47_espdl', 'lilygo_t5_47', 'ESP32-S3 240 MHz', 'ESP-DL 3.3.13 int8, ESP-PPQ (not bit-exact)', 'SIMD/PIE', {'': '1 core', '_CSV2': '2 cores'}),
]
cols = ['date', 'board', 'chip', 'impl', 'variant', 'parallel', 'net', 'status', 'runs', 'bit_exact', 'min_ms',
        'mean_ms', 'std_ms', 'fpga_ms', 'ratio_vs_fpga', 'source']
rows = []
for d, board, chip, impl, var, tags in CAMPAIGNS:
    for suf, par in tags.items():
        s = {r['net']: r for r in csv.DictReader(open(os.path.join(HERE, d, 'summary%s.csv' % suf)))}
        for n in NETS:
            log = os.path.join(HERE, d, n + '.serial.log')
            if n not in s and not os.path.exists(log):
                continue
            row = dict(date=os.path.basename(d)[:10], board=board, chip=chip, impl=impl, variant=var, parallel=par,
                       net=n, source=d)
            if n in s:
                r = s[n]
                row.update(status='ok', runs=r['runs'], bit_exact=r['bit_exact'] if 'bit-exact' in impl else 'n/a',
                           min_ms=r['min_ms'], mean_ms=r['mean_ms'], std_ms=r['std_ms'], fpga_ms=r['fpga_ms'],
                           ratio_vs_fpga=r['ratio_s3_fpga'])
            else:
                row.update(status='out of memory' if 'out of memory' in open(log, errors='replace').read() else 'failed')
            rows.append(row)
with open(os.path.join(HERE, 'ALL_RESULTS.csv'), 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=cols)
    w.writeheader()
    for r in rows:
        w.writerow(r)
print(len(rows), 'rows')
