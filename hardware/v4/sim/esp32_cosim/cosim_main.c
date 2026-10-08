// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// ============================================================
// v4 -- host program of the ESP32 <-> RTL co-simulation: runs the real
// driver's bring-up self test (fpga_v4_bringup) against
// tb_v4_esp32_cosim.v through idf_cosim.c.
//
// usage: cosim_main <c2v pipe> <v2c pipe> <model.bin> <golden_ref.txt> <load_words>
// load_words: how much of model.bin the driver writes (the bench
// preloads the parameter image to keep the simulation short; header,
// descriptors and image go over the Quad-SPI port); 0 = everything
// before the parameter image (header param_w).
// ============================================================
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fpga_neural_v4.h"

void cosim_open(const char *c2v, const char *v2c);
void cosim_finish(int code);

int main(int argc, char **argv)
{
    if (argc != 6) { fprintf(stderr, "usage: %s c2v v2c model.bin golden_ref.txt load_words\n", argv[0]); return 2; }
    FILE *f = fopen(argv[3], "rb");
    if (!f) { perror(argv[3]); return 2; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *blob = malloc(n);
    if (fread(blob, 1, n, f) != (size_t)n) return 2;
    fclose(f);
    int emb = 0;
    f = fopen(argv[4], "r");
    if (!f || fscanf(f, "%*[^(](%d INT8):", &emb) != 1 || emb <= 0) { fprintf(stderr, "bad %s\n", argv[4]); return 2; }
    int8_t *golden = malloc(emb), *out = malloc(emb);
    for (int i = 0; i < emb; i++) { int v; if (fscanf(f, "%d", &v) != 1) return 2; golden[i] = (int8_t)v; }
    fclose(f);
    size_t load = (size_t)atol(argv[5]) * 16;
    if (load == 0) {        // header w1 [95:64] param_w
        uint32_t param_w;
        memcpy(&param_w, blob + 16 * 16 + 16 + 8, 4);
        load = (size_t)param_w * 16;
    }
    if (load > (size_t)n) load = n;

    cosim_open(argv[1], argv[2]);

    // same configuration as the board (datasheet §14.3): one Quad-SPI link
    fpga_v4_qspi_handle_t q;
    fpga_v4_qspi_config_t qc = {
        .spi_host = SPI2_HOST, .pin_sclk = 12, .pin_cs = 10,
        .pin_io0 = 11, .pin_io1 = 13, .pin_io2 = 14, .pin_io3 = 9,
        .clock_speed_hz = 80 * 1000 * 1000,
        .pin_sys_rst = 15, .pin_data_ready_n = 16,
    };
    esp_err_t err = fpga_v4_qspi_init(&qc, &q);
    if (err != ESP_OK) { fprintf(stderr, "init: %s\n", esp_err_to_name(err)); cosim_finish(1); return 1; }

    fpga_v4_layout_t lay;
    if (fpga_v4_layout_from_blob(blob, n, 16, &lay) != ESP_OK || lay.out_len != (uint32_t)emb) {
        fprintf(stderr, "model.bin header does not match %s\n", argv[4]); cosim_finish(1); return 1;
    }
    fpga_v4_bringup_cfg_t cfg = {
        .blob = blob, .blob_len = load,
        .image = (const int8_t *)(blob + lay.img_w * 16),   // the per-inference image path
        .golden = golden,
        .out = out,
        .lay = lay,
        .scratch_w = 96000,
        .rst_hold_us = 5, .calib_timeout_ms = 50, .infer_timeout_ms = 200,
    };
    fpga_v4_bringup_report_t rep;
    err = fpga_v4_bringup(q, &cfg, &rep);
    printf("bring-up: %s, failed step %d, DEVICE_ID 0x%08x, core cycles %u, param wait %u, mismatches %d\n",
           esp_err_to_name(err), rep.failed_step == FPGA_V4_STEP_DONE ? 0 : (int)rep.failed_step,
           (unsigned)rep.device_id, (unsigned)rep.stats.core_cycles, (unsigned)rep.stats.param_wait_cycles, rep.mismatches);
    if (err == ESP_OK) printf("ALL TESTS PASSED (esp32 driver co-simulation)\n");
    fflush(stdout);
    cosim_finish(err == ESP_OK ? 0 : 1);
    return err == ESP_OK ? 0 : 1;
}
