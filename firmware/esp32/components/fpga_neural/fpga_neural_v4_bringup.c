// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// FPGA-Neural v4 first-power-on self test -- see include/fpga_neural_v4.h.
// Runs unchanged on the ESP32 and in the RTL co-simulation
// (hardware/v4/sim/esp32_cosim).
#include <string.h>
#include "esp_log.h"
#include "fpga_neural_v4.h"

static const char *TAG = "fpga_v4_bringup";

#define FAIL_AT(step, err, ...) do { ESP_LOGE(TAG, __VA_ARGS__); rep->failed_step = (step); return (err); } while (0)

esp_err_t fpga_v4_bringup(fpga_v4_qspi_handle_t q,
                          const fpga_v4_bringup_cfg_t *cfg, fpga_v4_bringup_report_t *rep)
{
    if (!q || !cfg || !rep || !cfg->out) return ESP_ERR_INVALID_ARG;
    memset(rep, 0, sizeof(*rep));
    esp_err_t err;

    // 1. reset (sys_rst, active low)
    if (cfg->rst_hold_us) {
        err = fpga_v4_board_reset(q, cfg->rst_hold_us);
        if (err != ESP_OK && err != ESP_ERR_NOT_SUPPORTED) FAIL_AT(FPGA_V4_STEP_RESET, err, "sys_rst pulse: %s", esp_err_to_name(err));
        ESP_LOGI(TAG, "1 reset: %s", err == ESP_OK ? "sys_rst pulsed low" : "sys_rst not wired, skipped");
    }

    // 2. DDR3 calibration (STATUS)
    err = fpga_v4_wait_calib(q, cfg->calib_timeout_ms);
    if (err != ESP_OK) FAIL_AT(FPGA_V4_STEP_CALIB, err, "DDR3 calibration: %s", esp_err_to_name(err));
    ESP_LOGI(TAG, "2 DDR3 calibrated");

    // 3. identity
    fpga_v4_status_t st;
    err = fpga_v4_read_status(q, &st);
    rep->device_id = st.id;
    if (err != ESP_OK || st.id != FPGA_V4_DEVICE_ID)
        FAIL_AT(FPGA_V4_STEP_DEVICE_ID, err != ESP_OK ? err : ESP_ERR_INVALID_RESPONSE,
                "DEVICE_ID 0x%08x (expected 0x%08x)", (unsigned)st.id, (unsigned)FPGA_V4_DEVICE_ID);
    ESP_LOGI(TAG, "3 DEVICE_ID 0x%08x", (unsigned)rep->device_id);

    // 4. Quad-SPI DDR3 access: 2 words, then 1 word at an odd address
    //    (both halves of a 256-bit DDR3 burst, alone and together)
    uint8_t pat[64], back[64];
    for (int i = 0; i < 64; i++) pat[i] = (uint8_t)(0x5A ^ (i * 37) ^ (i >> 2));
    err = fpga_v4_qspi_write(q, cfg->scratch_w, pat, 32);
    if (err == ESP_OK) err = fpga_v4_qspi_write(q, cfg->scratch_w + 3, pat + 32, 16);
    if (err != ESP_OK) FAIL_AT(FPGA_V4_STEP_QSPI_MEM, err, "Quad-SPI write: %s", esp_err_to_name(err));
    memset(back, 0, sizeof back);
    err = fpga_v4_qspi_read(q, cfg->scratch_w, back, 32);
    if (err == ESP_OK) err = fpga_v4_qspi_read(q, cfg->scratch_w + 3, back + 32, 16);
    if (err != ESP_OK) FAIL_AT(FPGA_V4_STEP_QSPI_MEM, err, "Quad-SPI read: %s", esp_err_to_name(err));
    if (memcmp(pat, back, 48)) FAIL_AT(FPGA_V4_STEP_QSPI_MEM, ESP_ERR_INVALID_RESPONSE, "Quad-SPI DDR3 readback differs");
    ESP_LOGI(TAG, "4 DDR3 over Quad-SPI: 48 bytes written and read back");

    // 5. model
    if (cfg->blob) {
        err = fpga_v4_qspi_write(q, 0, cfg->blob, cfg->blob_len);
        if (err != ESP_OK) FAIL_AT(FPGA_V4_STEP_LOAD, err, "model load: %s", esp_err_to_name(err));
        uint8_t hdr[32];
        err = fpga_v4_qspi_read(q, cfg->lay.hdr_w, hdr, 32);
        uint32_t magic;
        memcpy(&magic, hdr + 28, 4);
        if (err != ESP_OK || magic != FPGA_V4_MAGIC)
            FAIL_AT(FPGA_V4_STEP_LOAD, err != ESP_OK ? err : ESP_ERR_INVALID_RESPONSE, "header magic after load: 0x%08x", (unsigned)magic);
        ESP_LOGI(TAG, "5 model loaded: %u bytes, header magic OK", (unsigned)cfg->blob_len);
    }

    // 6. one inference
    if (cfg->image) {
        err = fpga_v4_infer(q, &cfg->lay, cfg->image, cfg->out, &rep->stats, cfg->infer_timeout_ms);
    } else {
        err = fpga_v4_start(q, &cfg->lay);
        if (err == ESP_OK) err = fpga_v4_finish(q, &cfg->lay, cfg->out, &rep->stats, cfg->infer_timeout_ms);
    }
    if (err != ESP_OK) FAIL_AT(FPGA_V4_STEP_INFER, err, "inference: %s", esp_err_to_name(err));
    ESP_LOGI(TAG, "6 inference done: %u core cycles, %u waiting for parameters",
             (unsigned)rep->stats.core_cycles, (unsigned)rep->stats.param_wait_cycles);

    // 7. result
    if (cfg->golden) {
        int n = cfg->lay.out_len ? (int)cfg->lay.out_len : FPGA_V4_MFN_OUT_LEN;
        for (int i = 0; i < n; i++) rep->mismatches += cfg->out[i] != cfg->golden[i];
        if (rep->mismatches) FAIL_AT(FPGA_V4_STEP_COMPARE, ESP_FAIL, "output: %d of %d values differ", rep->mismatches, n);
        ESP_LOGI(TAG, "7 output identical to the expected one (%d values)", n);
    }
    rep->failed_step = FPGA_V4_STEP_DONE;
    return ESP_OK;
}
