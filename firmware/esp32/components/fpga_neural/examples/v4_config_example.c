// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// FPGA-Neural v4 -- example: FPGA configuration + one inference.
// Not part of the component build (copy what you need into your app).
// Host syntax check against the co-simulation stubs:
//   gcc -c -Wall -I hardware/v4/sim/esp32_cosim/idf
//       -I firmware/esp32/components/fpga_neural/include
//       firmware/esp32/components/fpga_neural/examples/v4_config_example.c
//
// Wiring: datasheet §9.8 (40-pin BTB connector) and §14.10; GPIO numbers below are
// the v4_bringup defaults.
#include <stdbool.h>
#include "esp_log.h"
#include "fpga_neural_v4.h"

static const char *TAG = "v4_example";

static const fpga_v4_cfg_pins_t pins = {
    .pin_tck = 1, .pin_tms = 2, .pin_tdi = 17, .pin_tdo = 18,
    .pin_program_b = 21, .pin_init_b = 47, .pin_done = 48,
};

// The one host link: Quad-SPI (data, registers, status and the config-flash
// pass-through), plus sys_rst and the data_ready_n interrupt line.
static esp_err_t open_link(fpga_v4_qspi_handle_t *q)
{
    fpga_v4_qspi_config_t qc = {
        .spi_host = SPI2_HOST, .pin_sclk = 12, .pin_cs = 10,
        .pin_io0 = 11, .pin_io1 = 13, .pin_io2 = 14, .pin_io3 = 9,
        .clock_speed_hz = 80 * 1000 * 1000,
        .pin_sys_rst = 15, .pin_data_ready_n = 16,
    };
    return fpga_v4_qspi_init(&qc, q);
}

// Power-on: the FPGA configures itself from its flash. Blank or bad flash
// (first power-on, recovery): JTAG load of the bitstream from the "fpga"
// partition, then the same bitstream into the flash, then reboot from it.
static esp_err_t fpga_first_boot(fpga_v4_qspi_handle_t q)
{
    fpga_v4_cfg_pins_init(&pins);
    if (fpga_v4_wait_done(&pins, 2000) == ESP_OK)
        return fpga_v4_wait_calib(q, 1000);         // normal case: nothing else to do

    ESP_LOGW(TAG, "DONE low: flash blank or bad, configuring over JTAG");
    const uint8_t *bit; size_t len;
    esp_err_t err = fpga_v4_bitstream_from_partition("fpga", &bit, &len);
    if (err != ESP_OK) return err;                               // no .bit in the partition
    err = fpga_v4_jtag_load_sram(&pins, bit, len, 1000);
    if (err != ESP_OK) return err;                               // IDCODE / DONE: see the log
    err = fpga_v4_wait_calib(q, 1000);                            // port control runs on the MIG ui_clk
    if (err != ESP_OK) return err;
    err = fpga_v4_flash_program(q, &pins, 0, bit, len, 5000);   // erase, program, verify, PROGRAM_B, DONE
    if (err != ESP_OK) return err;
    return fpga_v4_wait_calib(q, 1000);
}

// Field update: new .bit already written into the "fpga" partition (OTA,
// parttool, ...); the running FPGA rewrites its own flash and reboots.
static esp_err_t fpga_update(fpga_v4_qspi_handle_t q)
{
    const uint8_t *bit; size_t len;
    esp_err_t err = fpga_v4_bitstream_from_partition("fpga", &bit, &len);
    if (err == ESP_OK) err = fpga_v4_flash_program(q, &pins, 0, bit, len, 5000);
    if (err == ESP_OK) err = fpga_v4_wait_calib(q, 1000);
    if (err == ESP_ERR_INVALID_CRC)
        ESP_LOGE(TAG, "flash verify failed: the old image may be damaged, retry before power-off");
    return err;
}

// One inference with a model already in DDR3 (fpga_v4_load_blob).
static esp_err_t fpga_infer_one(fpga_v4_qspi_handle_t q,
                                const fpga_v4_layout_t *lay,
                                const int8_t *image,
                                int8_t *embedding)
{
    fpga_v4_stats_t st;
    esp_err_t err = fpga_v4_infer(q, lay, image, embedding, &st, 100);
    if (err == ESP_OK)
        ESP_LOGI(TAG, "inference: %u core cycles%s", (unsigned)st.core_cycles, st.error ? ", core error" : "");
    return err;
}

esp_err_t v4_example(const uint8_t *model_blob, size_t model_len,
                     const int8_t *image, int8_t *embedding, bool update)
{
    fpga_v4_qspi_handle_t q;
    esp_err_t err = open_link(&q);
    if (err != ESP_OK) return err;
    err = update ? fpga_update(q) : fpga_first_boot(q);
    if (err != ESP_OK) { ESP_LOGE(TAG, "configuration: %s", esp_err_to_name(err)); return err; }

    fpga_v4_layout_t lay;
    err = fpga_v4_layout_from_blob(model_blob, model_len, 16, &lay);
    if (err == ESP_OK) err = fpga_v4_load_blob(q, 0, model_blob, model_len);     // model into DDR3 word 0
    if (err == ESP_OK) err = fpga_infer_one(q, &lay, image, embedding);
    return err;
}
