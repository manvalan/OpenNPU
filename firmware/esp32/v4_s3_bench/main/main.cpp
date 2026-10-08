// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// FPGA-Neural v4 -- CPU reference on the ESP32-S3: runs the network of
// net/net.bin (../make_net.sh) with the FPGA integer arithmetic,
// compares the output with the FPGA's expected output byte for byte and
// prints the time per inference (esp_timer, CPU at 240 MHz, activations
// in PSRAM when they do not fit the internal RAM).
#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <string>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "v4net.hpp"

static const char *TAG = "v4_s3_bench";

extern const uint8_t net_bin_start[] asm("_binary_net_bin_start");
extern const uint8_t net_bin_end[]   asm("_binary_net_bin_end");

static constexpr int RUNS = 5;

// internal RAM first (faster), PSRAM for the large tensors
static void *alloc_any(size_t n)
{
    void *p = heap_caps_malloc(n, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (!p) p = heap_caps_malloc(n, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    return p;
}

extern "C" void app_main(void)
{
    v4net::Net::alloc = alloc_any;
    v4net::Net::release = heap_caps_free;
    v4net::Net net;
    std::string err;
    if (!net.load(net_bin_start, net_bin_end - net_bin_start, err)) {
        ESP_LOGE(TAG, "net.bin: %s", err.c_str());
        return;
    }
    ESP_LOGI(TAG, "network: %u layers, output %u values, %u bytes of net.bin",
             (unsigned)net.layers(), (unsigned)net.expected_len(), (unsigned)(net_bin_end - net_bin_start));
    int64_t best = INT64_MAX, total = 0;
    int bad = 0;
    for (int r = 0; r < RUNS; r++) {
        int64_t t0 = esp_timer_get_time();
        const v4net::Tensor &y = net.run();
        int64_t us = esp_timer_get_time() - t0;
        total += us;
        if (us < best) best = us;
        bool ok = y.size() == net.expected_len() && std::memcmp(y.d, net.expected(), y.size()) == 0;
        if (!ok) bad++;
        ESP_LOGI(TAG, "run %d: %.3f ms, output %s", r, us / 1000.0, ok ? "identical to the FPGA" : "DIFFERENT");
    }
    ESP_LOGI(TAG, "RESULT: best %.3f ms, mean %.3f ms over %d runs, %d/%d bit-exact, peak activations %u bytes",
             best / 1000.0, total / 1000.0 / RUNS, RUNS, RUNS - bad, RUNS, (unsigned)net.peak_bytes());
}
