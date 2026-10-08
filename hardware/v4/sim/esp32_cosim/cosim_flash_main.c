// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// ============================================================
// v4 -- host program of the config-flash co-simulation: runs the real
// driver (fpga_neural_v4_config.c over the Quad-SPI FLASH_XFER command)
// against tb_v4_flash_cosim.v (v4_board_top RTL + W25Q32JV model)
// through idf_cosim.c.
//
// usage: cosim_flash_main <c2v pipe> <v2c pipe> <out_dir>
// Writes <out_dir>/flash_expect.hex (expected flash bytes 0..0x2FFFF)
// for the bench's own backdoor comparison.
// ============================================================
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fpga_neural_v4.h"

void cosim_open(const char *c2v, const char *v2c);
void cosim_finish(int code);

#define AREA 0x30000
static uint8_t expect[AREA];
static int fails;
#define CHECK(c, ...) do { if (c) printf("  ok   " __VA_ARGS__); else { printf("  FAIL " __VA_ARGS__); fails++; } printf("\n"); fflush(stdout); } while (0)

static uint8_t pattern(uint32_t i) { return (uint8_t)((i * 7 + 3) ^ (i >> 8)); }   // bench preload

int main(int argc, char **argv)
{
    if (argc != 4) { fprintf(stderr, "usage: %s c2v v2c out_dir\n", argv[0]); return 2; }
    for (uint32_t i = 0; i < AREA; i++) expect[i] = pattern(i);
    cosim_open(argv[1], argv[2]);

    fpga_v4_qspi_handle_t q;
    fpga_v4_qspi_config_t qc = {
        .spi_host = SPI2_HOST, .pin_sclk = 12, .pin_cs = 10,
        .pin_io0 = 11, .pin_io1 = 13, .pin_io2 = 14, .pin_io3 = 9,
        .clock_speed_hz = 80 * 1000 * 1000,
        .pin_sys_rst = 15, .pin_data_ready_n = 16,
    };
    // JTAG not wired in this bench (checked separately by jtag_tap_test.c)
    const fpga_v4_cfg_pins_t pins = { -1, -1, -1, -1, .pin_program_b = 17, .pin_init_b = 18, .pin_done = 19 };
    esp_err_t err = fpga_v4_qspi_init(&qc, &q);
    if (err == ESP_OK) err = fpga_v4_cfg_pins_init(&pins);
    if (err == ESP_OK) err = fpga_v4_wait_calib(q, 50);
    if (err != ESP_OK) { fprintf(stderr, "init: %s\n", esp_err_to_name(err)); cosim_finish(1); return 1; }
    printf("config-flash co-simulation (Quad-SPI 80 MHz, FLASH_XFER: one flash transaction per command)\n");

    uint32_t id = 0;
    err = fpga_v4_flash_jedec_id(q, &id);
    CHECK(err == ESP_OK && id == FPGA_V4_FLASH_JEDEC, "JEDEC ID 0x%06x", (unsigned)id);

    // exact transaction length: a 1-byte Write Enable takes (WEL = 1),
    // a 1-byte Write Disable clears it
    uint8_t c = 0x06, rx[8], sr[2] = { 0x05, 0xFF }, wel1, wel0;
    err = fpga_v4_flash_xfer(q, &c, 1, rx);
    if (err == ESP_OK) err = fpga_v4_flash_xfer(q, sr, 2, rx);
    wel1 = rx[1];
    c = 0x04;
    if (err == ESP_OK) err = fpga_v4_flash_xfer(q, &c, 1, rx);
    if (err == ESP_OK) err = fpga_v4_flash_xfer(q, sr, 2, rx);
    wel0 = rx[1];
    CHECK(err == ESP_OK && (wel1 & 0x02) && !(wel0 & 0x02), "1-byte WREN / WRDI: SR1 0x%02x then 0x%02x (%s)", wel1, wel0, esp_err_to_name(err));

    // erase only: one 64 KB block + two 4 KB sectors
    err = fpga_v4_flash_erase(q, 0x10000, 0x12000);
    memset(expect + 0x10000, 0xFF, 0x12000);
    uint8_t b[16];
    int ok = err == ESP_OK;
    const uint32_t probe[4] = { 0x10000, 0x1FFF0, 0x21FF0, 0x22000 };
    for (int k = 0; k < 4 && ok; k++) {
        ok = fpga_v4_flash_read(q, probe[k], b, 16) == ESP_OK && !memcmp(b, expect + probe[k], 16);
    }
    CHECK(ok, "erase 0x10000..0x21FFF (D8h + 2 x 20h): erased edges read 0xFF, 0x22000 preserved (%s)", esp_err_to_name(err));

    // a bitstream-like image of 4400 bytes at 0 (two 4 KB sectors): padding,
    // sync, data in pages 0-1 and 15-17 (a partial last page), the other
    // pages left 0xFF (skipped by the driver) to keep the simulation short
#ifdef SMALL_IMAGE
    static uint8_t img[300];       // 2 pages (the second partial), 1 sector: short run
#else
    static uint8_t img[4400];
#endif
    memset(img, 0xFF, sizeof img);
    const uint8_t head[] = { 0x00,0x00,0x00,0xBB, 0x11,0x22,0x00,0x44, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xAA,0x99,0x55,0x66 };
    memcpy(img + 32, head, sizeof head);
    srand(11);
    for (size_t i = 64; i < sizeof img; i++) if (i < 512 || i >= 3840) img[i] = (uint8_t)rand();
    err = fpga_v4_flash_program(q, &pins, 0, img, sizeof img, 200);
    memset(expect, 0xFF, (sizeof img + 0xFFF) & ~0xFFFu);    // the erased 4 KB sectors
    memcpy(expect, img, sizeof img);
    CHECK(err == ESP_OK, "program %u bytes at 0 + verify + PROGRAM_B + DONE: %s", (unsigned)sizeof img, esp_err_to_name(err));

    uint8_t back[64];
    const uint32_t tail = sizeof img - 8;
    err = fpga_v4_flash_read(q, tail, back, 16);
    CHECK(err == ESP_OK && !memcmp(back, expect + tail, 8) && back[8] == 0xFF, "read across the end of the image (0x%x onward erased)", (unsigned)sizeof img);

    // refused: unaligned address, image that does not start like a bitstream is still programmed but DONE stays low
    err = fpga_v4_flash_program(q, &pins, 0x100, img, 16, 200);
    CHECK(err == ESP_ERR_INVALID_ARG, "unaligned address refused (%s)", esp_err_to_name(err));

    char path[512];
    snprintf(path, sizeof path, "%s/flash_expect.hex", argv[3]);
    FILE *f = fopen(path, "w");
    for (uint32_t i = 0; i < AREA; i++) fprintf(f, "%02x\n", expect[i]);
    fclose(f);

    printf(fails ? "FAILED: %d checks\n" : "ALL TESTS PASSED (config-flash co-simulation)\n", fails);
    fflush(stdout);
    cosim_finish(fails ? 1 : 0);
    return fails != 0;
}
