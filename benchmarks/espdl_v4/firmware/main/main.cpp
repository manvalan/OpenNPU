// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// FPGA-Neural v4 -- the same networks on the ESP32-S3 with ESP-DL: the
// accelerated (SIMD) counterpart of ../../esp32s3_v4. The model is the
// ESP-PPQ quantization of the same float network (../export_espdl.py), so
// the output is NOT bit-exact with the FPGA (different rounding and
// exponents): the app prints the time per inference and the raw output,
// and ../compare.py measures how close it is to the FPGA and float outputs.
//   - model->test(): ESP-DL output vs ESP-PPQ's own simulation (test values
//     exported with the model) -- checks that ESP-DL ran the model correctly
//   - 10 runs on one core, then 10 runs on both cores (RUNTIME_MODE_MULTI_CORE)
//   - input: the v4 net.bin INT8 image (exponent -6), requantized to the
//     model's input exponent (identical when that exponent is -6)
#include <cmath>
#include <cstdio>
#include <cstring>

#include "dl_model_base.hpp"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "sdkconfig.h"

static const char *TAG = "v4_espdl";

extern const uint8_t espdl_model_start[] asm("espdl_model_start");
extern const uint8_t netbin_start[] asm("netbin_start");
extern const uint8_t netbin_end[] asm("netbin_end");

static constexpr int RUNS = 10;
static constexpr int E_IN_V4 = -6;

static uint32_t rd32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

// ESP-DL's memory planner may reuse the input buffer for intermediate
// tensors, so the input is written again before every run (not timed).
static int8_t *g_input;
static int g_input_len;

static void bench(dl::Model *model, dl::runtime_mode_t mode, const char *tag)
{
    int64_t best = INT64_MAX, total = 0;
    for (int r = 0; r < RUNS; r++) {
        std::memcpy(model->get_input()->get_element_ptr(), g_input, g_input_len);
        int64_t t0 = esp_timer_get_time();
        model->run(mode);
        int64_t us = esp_timer_get_time() - t0;
        total += us;
        if (us < best) best = us;
        printf("%s,%d,%lld,0\n", tag, r, (long long)us);
    }
    ESP_LOGI(TAG, "RESULT %s: best %.3f ms, mean %.3f ms over %d runs", tag, best / 1000.0, total / 1000.0 / RUNS, RUNS);
}

extern "C" void app_main(void)
{
    ESP_LOGI(TAG, "chip %s, CPU %d MHz, free heap %u (internal %u, PSRAM %u)", CONFIG_IDF_TARGET,
             CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ, (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
    // v4 net.bin header: "V4S3", ver, n_layers, h, w, c, 0, pack_len, img_len, out_len
    const uint8_t *nb = netbin_start;
    uint32_t n = rd32(nb + 8);
    int h = nb[12] | nb[13] << 8, w = nb[14] | nb[15] << 8, c = nb[16] | nb[17] << 8;
    uint32_t pack_len = rd32(nb + 20), img_len = rd32(nb + 24);
    const int8_t *img = (const int8_t *)(nb + 32 + 12 * n + pack_len);

    int64_t t0 = esp_timer_get_time();
    dl::Model *model = new dl::Model((const char *)espdl_model_start, fbs::MODEL_LOCATION_IN_FLASH_RODATA);
    ESP_LOGI(TAG, "model loaded in %.1f ms, free heap %u (internal %u, PSRAM %u)",
             (esp_timer_get_time() - t0) / 1000.0, (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
    ESP_LOGI(TAG, "model->test() (ESP-DL vs ESP-PPQ test values): %s", model->test() == ESP_OK ? "PASS" : "FAIL");

    dl::TensorBase *in = model->get_input();
    int e_in = in->exponent;
    if (in->get_dtype() != dl::DATA_TYPE_INT8 || in->get_size() != (int)img_len) {
        ESP_LOGE(TAG, "input: dtype %s, %d values, net.bin has %u (%dx%dx%d)", in->get_dtype_string(),
                 in->get_size(), (unsigned)img_len, h, w, c);
        return;
    }
    int8_t *d = (int8_t *)heap_caps_malloc(img_len, MALLOC_CAP_8BIT);
    g_input = d;
    g_input_len = img_len;
    for (uint32_t i = 0; i < img_len; i++) {      // NHWC both; value = img * 2^E_IN_V4
        float v = std::ldexp((float)img[i], E_IN_V4 - e_in);
        int q = (int)std::floor(v + 0.5f);
        d[i] = q > 127 ? 127 : (q < -128 ? -128 : q);
    }
    ESP_LOGI(TAG, "input %dx%dx%d, exponent %d (v4: %d)", h, w, c, e_in, E_IN_V4);

    bench(model, dl::RUNTIME_MODE_SINGLE_CORE, "CSV");
    bench(model, dl::RUNTIME_MODE_MULTI_CORE, "CSV2");

    dl::TensorBase *out = model->get_output();
    printf("OUT,%s,%d", out->get_dtype_string(), (int)out->exponent);
    if (out->get_dtype() == dl::DATA_TYPE_INT8) {
        const int8_t *o = (const int8_t *)out->get_element_ptr();
        for (int i = 0; i < out->get_size(); i++) printf(",%d", o[i]);
    } else if (out->get_dtype() == dl::DATA_TYPE_INT16) {
        const int16_t *o = (const int16_t *)out->get_element_ptr();
        for (int i = 0; i < out->get_size(); i++) printf(",%d", o[i]);
    }
    printf("\n");
    ESP_LOGI(TAG, "RESULT: done");
}
