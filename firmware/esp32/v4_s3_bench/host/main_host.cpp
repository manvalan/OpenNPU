// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// PC build of the CPU reference runner, to check v4net.cpp before
// flashing: g++ -O2 -I../main main_host.cpp ../main/v4net.cpp -o v4net_host
//   ./v4net_host net.bin [runs]
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "v4net.hpp"

int main(int argc, char **argv)
{
    if (argc < 2) { std::printf("usage: %s net.bin [runs]\n", argv[0]); return 2; }
    FILE *f = std::fopen(argv[1], "rb");
    if (!f) { std::perror(argv[1]); return 2; }
    std::vector<uint8_t> blob;
    uint8_t buf[65536];
    size_t n;
    while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) blob.insert(blob.end(), buf, buf + n);
    std::fclose(f);
    v4net::Net net;
    std::string err;
    if (!net.load(blob.data(), blob.size(), err)) { std::printf("load: %s\n", err.c_str()); return 1; }
    int runs = argc > 2 ? std::atoi(argv[2]) : 1;
    int bad = 0;
    double best = 1e30;
    for (int r = 0; r < runs; r++) {
        auto t0 = std::chrono::steady_clock::now();
        const v4net::Tensor &y = net.run();
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        if (ms < best) best = ms;
        if (y.size() != net.expected_len() || std::memcmp(y.d, net.expected(), y.size()) != 0) bad++;
    }
    std::printf("%s: %zu layers, output %zu values, %s (%d/%d runs bit-exact), best %.3f ms on this PC, "
                "peak activations %zu bytes\n", argv[1], net.layers(), net.expected_len(),
                bad ? "MISMATCH" : "bit-exact vs FPGA", runs - bad, runs, best, net.peak_bytes());
    return bad ? 1 : 0;
}
