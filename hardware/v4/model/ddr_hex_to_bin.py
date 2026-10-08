#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Convert gen_mfn's ddr_full.hex into the binary blob the ESP32 writes to DDR3.

ddr_full.hex has "@<word address in hex>" section lines followed by one
128-bit word per line, printed most significant byte first. The blob is
the DDR3 content from word 0 up to the last word written, little-endian
(byte k of a word = bits [8k+7:8k]); gaps are zero. Write it at DDR3
word 0 (fpga_v4_qspi_write(q, 0, blob, len) or fpga_v4_load_blob(h, 0, ...)).

Usage: ddr_hex_to_bin.py ddr_full.hex model.bin
"""
import struct
import sys


def main(src, dst):
    words = {}
    addr = 0
    with open(src) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("@"):
                addr = int(line[1:], 16)
                continue
            words[addr] = bytes.fromhex(line)[::-1]   # MSB-first text -> byte k at offset k
            addr += 1
    n = max(words) + 1
    blob = bytearray(16 * n)
    for a, w in words.items():
        blob[16 * a:16 * a + 16] = w
    with open(dst, "wb") as f:
        f.write(blob)

    # sanity check on the boot header (v4_boot.v)
    hdr_w = 16
    w0, w1 = blob[16 * hdr_w:16 * hdr_w + 16], blob[16 * hdr_w + 16:16 * hdr_w + 32]
    n_pass, = struct.unpack_from("<H", w0, 0)
    desc_w, img_w = struct.unpack_from("<II", w0, 2)
    result_w, = struct.unpack_from("<I", w1, 0)
    param_w, magic = struct.unpack_from("<II", w1, 8)
    print(f"{dst}: {len(blob)} bytes ({n} words); header @{hdr_w}: {n_pass} passes, "
          f"desc @{desc_w}, image @{img_w}, params @{param_w}, result @{result_w}, "
          f"magic 0x{magic:08X} {'OK' if magic == 0x344E4E56 else 'WRONG'}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
