#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Resets the ESP32 and saves its serial output until the RESULT line.
   capture.py PORT OUT.log [timeout_s] [--no-reset]
   --no-reset: just open the port (DTR high), e.g. an RP2350 sketch that
   waits for the host before running
   If the port drops (native USB re-enumerating during boot, e.g. the
   ESP32-C6), it is reopened without resetting again."""
import os, serial, sys, time
port, out = sys.argv[1], sys.argv[2]
args = [a for a in sys.argv[3:] if not a.startswith('--')]
timeout = float(args[0]) if args else 900
reset = '--no-reset' not in sys.argv

def open_port():
    while True:
        try:
            return serial.Serial(port, 115200, timeout=0.5)
        except (serial.SerialException, OSError):
            time.sleep(0.1)

s = open_port()
if reset:
    s.dtr = False; s.rts = True; time.sleep(0.2); s.rts = False  # pulse EN
t0 = time.time()
with open(out, 'w') as f:
    while time.time() - t0 < timeout:
        try:
            l = s.readline().decode(errors='replace').rstrip()
        except (serial.SerialException, OSError):
            s.close(); time.sleep(0.2); s = open_port()
            f.write('[capture: port dropped, reopened]\n')
            continue
        if not l:
            continue
        f.write(l + '\n'); f.flush(); print(l)
        if 'RESULT:' in l or ('E (' in l and 'v4_s3_bench' in l) or l.startswith('E v4_'):
            break
