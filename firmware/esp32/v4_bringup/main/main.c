// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// FPGA-Neural v4 -- first power-on of the real board (datasheet §14.11).
//
// 0. FPGA configuration: waits DONE (the FPGA boots from its flash); with
//    a blank/bad flash (or CONFIG_V4_FPGA_FLASH_MODE 2) the bitstream from
//    the "fpga" partition goes into the FPGA over JTAG and into the flash
//    (fpga_neural_v4_config.c).
// 1. fpga_v4_bringup(): reset, DDR3 calibration, DEVICE_ID, DDR3 write/read,
//    model load (everything over the one Quad-SPI link), one inference compared with the
//    compiler's / C model's expected output (model/golden.bin, bit-exact).
// 2. CONFIG_V4_BENCH_RUNS timed inferences (image in, output out over
//    Quad-SPI): ESP32-side time per inference, FPGA core cycles, and a
//    check that every result is still identical to the golden one.
//
// model/model.bin and model/golden.bin come from ../make_model.sh.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "esp_log.h"
#include "esp_timer.h"
#include "fpga_neural_v4.h"

static const char *TAG = "v4_bringup";

extern const uint8_t model_bin_start[]  asm("_binary_model_bin_start");
extern const uint8_t model_bin_end[]    asm("_binary_model_bin_end");
extern const uint8_t golden_bin_start[] asm("_binary_golden_bin_start");
extern const uint8_t golden_bin_end[]   asm("_binary_golden_bin_end");

#define HDR_W 16        // v4_compile / gen_mfn: boot header at DDR3 word 16

void app_main(void)
{
    size_t blob_len = model_bin_end - model_bin_start;
    size_t golden_len = golden_bin_end - golden_bin_start;
    fpga_v4_layout_t lay;
    esp_err_t err = fpga_v4_layout_from_blob(model_bin_start, blob_len, HDR_W, &lay);
    if (err != ESP_OK || golden_len != lay.out_len) {
        ESP_LOGE(TAG, "model.bin / golden.bin do not match (%s, golden %u bytes)", esp_err_to_name(err), (unsigned)golden_len);
        return;
    }
    ESP_LOGI(TAG, "model: %u bytes, image @%u (%u bytes), result @%u, output %u values",
             (unsigned)blob_len, (unsigned)lay.img_w, (unsigned)lay.img_bytes, (unsigned)lay.result_w,
             (unsigned)lay.out_len);
    int8_t *out = malloc(lay.out_len);
    if (!out) { ESP_LOGE(TAG, "no memory for the output (%u bytes)", (unsigned)lay.out_len); return; }

    fpga_v4_qspi_handle_t q;
    fpga_v4_qspi_config_t qc = {
        .spi_host = SPI2_HOST, .pin_sclk = 12, .pin_cs = 10,
        .pin_io0 = 11, .pin_io1 = 13, .pin_io2 = 14, .pin_io3 = 9,
        .clock_speed_hz = CONFIG_V4_QSPI_MHZ * 1000 * 1000,
        .pin_sys_rst = CONFIG_V4_SYS_RST, .pin_data_ready_n = CONFIG_V4_DATA_READY,
    };
    err = fpga_v4_qspi_init(&qc, &q);
    if (err != ESP_OK) { ESP_LOGE(TAG, "SPI init: %s", esp_err_to_name(err)); return; }

    // 0. configuration: the FPGA boots by itself from the flash (DONE)
    const fpga_v4_cfg_pins_t pins = {
        .pin_tck = CONFIG_V4_TCK, .pin_tms = CONFIG_V4_TMS, .pin_tdi = CONFIG_V4_TDI, .pin_tdo = CONFIG_V4_TDO,
        .pin_program_b = CONFIG_V4_PROGRAM_B, .pin_init_b = CONFIG_V4_INIT_B, .pin_done = CONFIG_V4_DONE,
    };
    fpga_v4_cfg_pins_init(&pins);
    bool booted = fpga_v4_wait_done(&pins, 2000) == ESP_OK;
    ESP_LOGI(TAG, "FPGA %s", booted ? "configured from flash (DONE high)" : "NOT configured (DONE low after 2 s)");
    if (CONFIG_V4_FPGA_FLASH_MODE == 2 || (!booted && CONFIG_V4_FPGA_FLASH_MODE == 1)) {
        const uint8_t *bit; size_t bit_len;
        err = fpga_v4_bitstream_from_partition("fpga", &bit, &bit_len);
        if (err == ESP_OK && !booted) {
            ESP_LOGI(TAG, "loading the bitstream over JTAG ...");
            int64_t t = esp_timer_get_time();
            err = fpga_v4_jtag_load_sram(&pins, bit, bit_len, 1000);
            ESP_LOGI(TAG, "JTAG load: %s (%lld ms)", esp_err_to_name(err), (long long)((esp_timer_get_time() - t) / 1000));
        }
        if (err == ESP_OK) err = fpga_v4_wait_calib(q, 1000);   // Quad-SPI port control logic runs on the MIG ui_clk
        if (err == ESP_OK) {
            int64_t t = esp_timer_get_time();
            err = fpga_v4_flash_program(q, &pins, 0, bit, bit_len, 5000);
            ESP_LOGI(TAG, "flash write + verify + reboot: %s (%lld ms)", esp_err_to_name(err), (long long)((esp_timer_get_time() - t) / 1000));
        }
        if (err != ESP_OK) { ESP_LOGE(TAG, "FPGA configuration failed: %s", esp_err_to_name(err)); return; }
    } else if (!booted) {
        ESP_LOGE(TAG, "FPGA not configured and CONFIG_V4_FPGA_FLASH_MODE = 0: stop");
        return;
    }

    const int8_t *image = (const int8_t *)(model_bin_start + lay.img_w * 16);
    fpga_v4_bringup_cfg_t cfg = {
        .blob = model_bin_start, .blob_len = blob_len,
        .image = image,
        .golden = (const int8_t *)golden_bin_start,
        .out = out,
        .lay = lay,
        .scratch_w = (lay.result_w + lay.out_len / 16 + 1 + 15) / 16 * 16,   // free words after the result
        .rst_hold_us = CONFIG_V4_SYS_RST >= 0 ? 100 : 0,
        .calib_timeout_ms = 1000, .infer_timeout_ms = 100,
    };
    static fpga_v4_bringup_report_t rep;
    int64_t t0 = esp_timer_get_time();
    err = fpga_v4_bringup(q, &cfg, &rep);
    ESP_LOGI(TAG, "self test: %s (%lld ms), DEVICE_ID 0x%08x", err == ESP_OK ? "PASSED" : "FAILED",
             (long long)((esp_timer_get_time() - t0) / 1000), (unsigned)rep.device_id);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "stopped at step %d (%s), %d output values differ", (int)rep.failed_step,
                 esp_err_to_name(err), rep.mismatches);
        return;
    }

#if CONFIG_V4_TEMP_MONITOR
    fpga_v4_sensors_t sens;
    if (fpga_v4_read_sensors(&pins, &sens) == ESP_OK)
        ESP_LOGI(TAG, "FPGA %.1f C, VCCINT %.3f V, VCCAUX %.3f V, VCCBRAM %.3f V",
                 sens.temp_c, sens.vccint_v, sens.vccaux_v, sens.vccbram_v);
    else
        ESP_LOGW(TAG, "XADC over JTAG not readable (JTAG wired?)");
#endif

    // timed inferences
    int64_t best = INT64_MAX, total = 0;
    uint32_t cyc = 0, wait = 0;
    int bad = 0;
    for (int i = 0; i < CONFIG_V4_BENCH_RUNS; i++) {
#if CONFIG_V4_TEMP_MONITOR
        if (i % CONFIG_V4_TEMP_EVERY == 0 && fpga_v4_read_sensors(&pins, &sens) == ESP_OK) {
            ESP_LOGI(TAG, "run %d: FPGA %.1f C, VCCINT %.3f V", i, sens.temp_c, sens.vccint_v);
            if (sens.temp_c >= CONFIG_V4_TEMP_ALARM_C) {
                ESP_LOGE(TAG, "FPGA at %.1f C >= %d C: benchmark stopped (check the heatsink)",
                         sens.temp_c, CONFIG_V4_TEMP_ALARM_C);
                return;
            }
        }
#endif
        fpga_v4_stats_t st;
        int64_t a = esp_timer_get_time();
        err = fpga_v4_infer(q, &lay, image, out, &st, 1000);
        int64_t dt = esp_timer_get_time() - a;
        if (err != ESP_OK) { ESP_LOGE(TAG, "inference %d: %s", i, esp_err_to_name(err)); return; }
        bad += memcmp(out, golden_bin_start, lay.out_len) != 0;
        total += dt; if (dt < best) best = dt;
        cyc = st.core_cycles; wait = st.param_wait_cycles;
    }
    ESP_LOGI(TAG, "%d inferences: ESP32 view %lld us average, %lld us best (image write + start + done + result read)",
             CONFIG_V4_BENCH_RUNS, (long long)(total / CONFIG_V4_BENCH_RUNS), (long long)best);
    ESP_LOGI(TAG, "FPGA core: %u cycles (%u waiting for parameters) = %u us at 199.34 MHz, %u us at 189.20 MHz",
             (unsigned)cyc, (unsigned)wait, (unsigned)(cyc / 199.34), (unsigned)(cyc / 189.20));
    ESP_LOGI(TAG, "results different from golden: %d of %d", bad, CONFIG_V4_BENCH_RUNS);
}
