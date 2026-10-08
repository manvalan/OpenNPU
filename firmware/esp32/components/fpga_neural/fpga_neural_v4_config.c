// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// FPGA-Neural v4 -- FPGA configuration from the ESP32: JTAG load of the
// SRAM, config-flash programming through FLASH_XFER, PROGRAM_B / DONE.
// See include/fpga_neural_v4.h. Runs unchanged on the ESP32 and in the
// host tests (hardware/v4/sim/esp32_cosim: flash path against the RTL +
// a W25Q model, JTAG path against a C model of the 7-series TAP).
#include <string.h>
#include <stdlib.h>
#include "esp_log.h"
#include "esp_rom_sys.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "fpga_neural_v4.h"

static const char *TAG = "fpga_v4_config";

// ---------------- pins ----------------

esp_err_t fpga_v4_cfg_pins_init(const fpga_v4_cfg_pins_t *p)
{
    if (!p || p->pin_program_b < 0 || p->pin_done < 0) return ESP_ERR_INVALID_ARG;
    const int outs[3] = { p->pin_tck, p->pin_tms, p->pin_tdi };
    for (int i = 0; i < 3; i++) {
        if (outs[i] < 0) continue;
        gpio_config_t io = { .pin_bit_mask = 1ULL << outs[i], .mode = GPIO_MODE_OUTPUT };
        gpio_set_level(outs[i], 0);
        gpio_config(&io);
    }
    const int ins[3] = { p->pin_tdo, p->pin_init_b, p->pin_done };
    for (int i = 0; i < 3; i++) {
        if (ins[i] < 0) continue;
        gpio_config_t io = { .pin_bit_mask = 1ULL << ins[i], .mode = GPIO_MODE_INPUT };
        gpio_config(&io);
    }
    // PROGRAM_B: open drain, released (the module pulls it up)
    gpio_config_t io = { .pin_bit_mask = 1ULL << p->pin_program_b, .mode = GPIO_MODE_INPUT_OUTPUT_OD };
    gpio_set_level(p->pin_program_b, 1);
    gpio_config(&io);
    return ESP_OK;
}

static esp_err_t wait_pin_high(int pin, uint32_t timeout_ms)
{
    TickType_t start = xTaskGetTickCount();
    for (;;) {
        if (gpio_get_level(pin)) return ESP_OK;
        if ((xTaskGetTickCount() - start) * portTICK_PERIOD_MS >= timeout_ms) return ESP_ERR_TIMEOUT;
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}

esp_err_t fpga_v4_wait_done(const fpga_v4_cfg_pins_t *p, uint32_t timeout_ms)
{
    if (!p || p->pin_done < 0) return ESP_ERR_INVALID_ARG;
    return wait_pin_high(p->pin_done, timeout_ms);
}

esp_err_t fpga_v4_reconfigure(const fpga_v4_cfg_pins_t *p, uint32_t timeout_ms)
{
    if (!p || p->pin_program_b < 0 || p->pin_done < 0) return ESP_ERR_INVALID_ARG;
    gpio_set_level(p->pin_program_b, 0);    // TPROGRAM >= 250 ns (DS181)
    ets_delay_us(10);
    gpio_set_level(p->pin_program_b, 1);
    if (p->pin_init_b >= 0) {
        esp_err_t err = wait_pin_high(p->pin_init_b, 100);
        if (err != ESP_OK) { ESP_LOGE(TAG, "INIT_B stuck low after PROGRAM_B"); return err; }
    }
    esp_err_t err = wait_pin_high(p->pin_done, timeout_ms);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "DONE low %u ms after PROGRAM_B (INIT_B %d): flash image not accepted",
                 (unsigned)timeout_ms, p->pin_init_b >= 0 ? gpio_get_level(p->pin_init_b) : -1);
        return err;
    }
    ESP_LOGI(TAG, "FPGA configured from flash (DONE high)");
    return ESP_OK;
}

// ---------------- bitstream image ----------------

esp_err_t fpga_v4_bitstream_payload(const uint8_t *img, size_t len, const uint8_t **data, size_t *data_len)
{
    if (!img || !data || !data_len) return ESP_ERR_INVALID_ARG;
    if (len >= 4 && img[0] == 0xFF && img[1] == 0xFF && img[2] == 0xFF && img[3] == 0xFF) {
        *data = img; *data_len = len;        // already a bare payload (.bin)
        return ESP_OK;
    }
    // .bit: 2-byte length + 9-byte field, 2-byte 0x0001, then keyed fields
    // 'a'..'d' (2-byte big-endian length) and 'e' (4-byte length + payload)
    if (len < 13 || img[0] != 0x00 || img[1] != 0x09) return ESP_ERR_INVALID_ARG;
    size_t i = 13;
    while (i < len) {
        uint8_t key = img[i++];
        if (key == 'e') {
            if (i + 4 > len) return ESP_ERR_INVALID_SIZE;
            size_t n = ((size_t)img[i] << 24) | ((size_t)img[i + 1] << 16) | ((size_t)img[i + 2] << 8) | img[i + 3];
            i += 4;
            if (i + n > len) return ESP_ERR_INVALID_SIZE;
            *data = img + i; *data_len = n;
            return ESP_OK;
        }
        if (key < 'a' || key > 'd' || i + 2 > len) return ESP_ERR_INVALID_ARG;
        i += 2 + (((size_t)img[i] << 8) | img[i + 1]);
    }
    return ESP_ERR_INVALID_SIZE;
}

// sync word 0xAA995566 near the start: rejects a wrong or corrupted image
static bool has_sync(const uint8_t *d, size_t n)
{
    for (size_t i = 0; i + 4 <= n && i < 256; i++)
        if (d[i] == 0xAA && d[i + 1] == 0x99 && d[i + 2] == 0x55 && d[i + 3] == 0x66) return true;
    return false;
}

// ---------------- JTAG (7-series TAP, IR length 6) ----------------

#define IR_CFG_IN   0x05
#define IR_IDCODE   0x09
#define IR_JPROGRAM 0x0B
#define IR_JSTART   0x0C
#define IR_ISC_NOOP 0x14
#define IR_BYPASS   0x3F
// IR capture value: bit5 DONE, bit4 INIT complete, bits 1:0 = 01
#define CAP_DONE    0x20
#define CAP_INIT    0x10

// One TCK cycle: TMS/TDI set while TCK is low, TDO read before the rising
// edge (the TAP drives it on the previous falling edge), TCK high, TCK low.
static int tck(const fpga_v4_cfg_pins_t *p, int tms, int tdi)
{
    gpio_set_level(p->pin_tms, tms);
    gpio_set_level(p->pin_tdi, tdi);
    int tdo = gpio_get_level(p->pin_tdo);
    gpio_set_level(p->pin_tck, 1);
    gpio_set_level(p->pin_tck, 0);
    return tdo;
}

static void tap_reset_to_idle(const fpga_v4_cfg_pins_t *p)
{
    for (int i = 0; i < 5; i++) tck(p, 1, 0);   // Test-Logic-Reset
    tck(p, 0, 0);                               // Run-Test/Idle
}

// From Run-Test/Idle: loads `ir`, returns the captured IR value, back in Run-Test/Idle.
static uint8_t shift_ir(const fpga_v4_cfg_pins_t *p, uint8_t ir)
{
    tck(p, 1, 0); tck(p, 1, 0); tck(p, 0, 0); tck(p, 0, 0);   // Select-DR, Select-IR, Capture-IR, Shift-IR
    uint8_t cap = 0;
    for (int i = 0; i < 6; i++)                                // LSB first, last bit exits to Exit1-IR
        cap |= (uint8_t)(tck(p, i == 5, (ir >> i) & 1) << i);
    tck(p, 1, 0); tck(p, 0, 0);                                // Update-IR, Run-Test/Idle
    return cap;
}

static void enter_shift_dr(const fpga_v4_cfg_pins_t *p)
{
    tck(p, 1, 0); tck(p, 0, 0); tck(p, 0, 0);                 // Select-DR, Capture-DR, Shift-DR
}

static void exit_dr_to_idle(const fpga_v4_cfg_pins_t *p)
{
    tck(p, 1, 0); tck(p, 0, 0);                                // (from Exit1-DR) Update-DR, Run-Test/Idle
}

static bool jtag_wired(const fpga_v4_cfg_pins_t *p)
{
    return p && p->pin_tck >= 0 && p->pin_tms >= 0 && p->pin_tdi >= 0 && p->pin_tdo >= 0;
}

esp_err_t fpga_v4_jtag_idcode(const fpga_v4_cfg_pins_t *p, uint32_t *idcode)
{
    if (!jtag_wired(p) || !idcode) return ESP_ERR_INVALID_ARG;
    tap_reset_to_idle(p);
    shift_ir(p, IR_IDCODE);
    enter_shift_dr(p);
    uint32_t v = 0;
    for (int i = 0; i < 32; i++) v |= (uint32_t)tck(p, i == 31, 0) << i;
    exit_dr_to_idle(p);
    *idcode = v;
    return ESP_OK;
}

esp_err_t fpga_v4_jtag_load_sram(const fpga_v4_cfg_pins_t *p, const uint8_t *bit, size_t len, uint32_t timeout_ms)
{
    if (!jtag_wired(p) || !bit) return ESP_ERR_INVALID_ARG;
    const uint8_t *d; size_t n;
    esp_err_t err = fpga_v4_bitstream_payload(bit, len, &d, &n);
    if (err != ESP_OK || n == 0 || !has_sync(d, n)) {
        ESP_LOGE(TAG, "not a 7-series bitstream (no sync word)");
        return err != ESP_OK ? err : ESP_ERR_INVALID_ARG;
    }

    uint32_t id;
    fpga_v4_jtag_idcode(p, &id);              // ends in Run-Test/Idle
    if ((id & 0x0FFFFFFFu) != FPGA_V4_IDCODE) {
        ESP_LOGE(TAG, "JTAG IDCODE 0x%08x, expected XC7A100T 0x%08x", (unsigned)id, (unsigned)FPGA_V4_IDCODE);
        return ESP_ERR_INVALID_RESPONSE;
    }

    // JPROGRAM: clears the configuration memory (INIT_B low, then high)
    shift_ir(p, IR_JPROGRAM);
    TickType_t start = xTaskGetTickCount();
    if (p->pin_init_b >= 0) {
        err = wait_pin_high(p->pin_init_b, 100);
        if (err != ESP_OK) { ESP_LOGE(TAG, "INIT_B stuck low after JPROGRAM"); return err; }
    }
    for (;;) {                                // INIT complete in the IR capture value
        uint8_t cap = shift_ir(p, IR_ISC_NOOP);
        if ((cap & 0x03) != 0x01) { ESP_LOGE(TAG, "IR capture 0x%02x: TAP not responding", cap); return ESP_ERR_INVALID_RESPONSE; }
        if (cap & CAP_INIT) break;
        if ((xTaskGetTickCount() - start) * portTICK_PERIOD_MS >= 100) { ESP_LOGE(TAG, "INIT not complete after JPROGRAM"); return ESP_ERR_TIMEOUT; }
        vTaskDelay(pdMS_TO_TICKS(1));
    }

    // CFG_IN: the payload, MSB of each byte first; TMS high on the very last bit
    shift_ir(p, IR_CFG_IN);
    enter_shift_dr(p);
    for (size_t i = 0; i < n; i++) {
        uint8_t b = d[i];
        for (int k = 7; k >= 0; k--) tck(p, i == n - 1 && k == 0, (b >> k) & 1);
    }
    exit_dr_to_idle(p);

    // JSTART: start-up sequence clocked by TCK in Run-Test/Idle
    shift_ir(p, IR_JSTART);
    for (int i = 0; i < 2000; i++) tck(p, 0, 0);
    tap_reset_to_idle(p);

    uint8_t cap = shift_ir(p, IR_BYPASS);
    if (!(cap & CAP_DONE)) {
        ESP_LOGE(TAG, "DONE not set after JSTART (IR capture 0x%02x): bitstream rejected", cap);
        return ESP_ERR_INVALID_RESPONSE;
    }
    if (p->pin_done >= 0 && (err = wait_pin_high(p->pin_done, timeout_ms)) != ESP_OK) {
        ESP_LOGE(TAG, "DONE pin low although the TAP reports DONE");
        return err;
    }
    ESP_LOGI(TAG, "FPGA configured over JTAG (%u bytes)", (unsigned)n);
    return ESP_OK;
}

// ---------------- XADC through JTAG (UG480 ch. 3, DRP JTAG interface) ----------------

#define IR_XADC_DRP 0x37        // 110111
#define XADC_RTI    20          // >= 10 Run-Test/Idle cycles between DRP transactions (UG480)

// One 32-bit XADC DR scan from Run-Test/Idle: shifts `cmd` in (LSB first),
// returns the captured word (result of the PREVIOUS read command), then
// XADC_RTI cycles in Run-Test/Idle for the arbiter to complete this one.
static uint32_t xadc_scan(const fpga_v4_cfg_pins_t *p, uint32_t cmd)
{
    enter_shift_dr(p);
    uint32_t v = 0;
    for (int i = 0; i < 32; i++) v |= (uint32_t)tck(p, i == 31, (cmd >> i) & 1) << i;
    exit_dr_to_idle(p);
    for (int i = 0; i < XADC_RTI; i++) tck(p, 0, 0);
    return v;
}

static uint32_t xadc_read_cmd(uint8_t addr) { return (1u << 26) | ((uint32_t)addr << 16); }   // CMD 0001 = read

esp_err_t fpga_v4_read_sensors(const fpga_v4_cfg_pins_t *p, fpga_v4_sensors_t *out)
{
    if (!jtag_wired(p) || !out) return ESP_ERR_INVALID_ARG;
    static const uint8_t addr[4] = { 0x00, 0x01, 0x02, 0x06 };
    uint16_t code[4];
    tap_reset_to_idle(p);
    shift_ir(p, IR_XADC_DRP);
    xadc_scan(p, xadc_read_cmd(addr[0]));                         // reads are pipelined:
    for (int k = 0; k < 4; k++)                                    // each scan returns the previous one
        code[k] = (uint16_t)(xadc_scan(p, k < 3 ? xadc_read_cmd(addr[k + 1]) : 0) >> 4) & 0x0FFF;
    tap_reset_to_idle(p);
    if (code[0] == 0 || code[0] == 0x0FFF) return ESP_ERR_INVALID_RESPONSE;   // JTAG_XADC disabled / no answer
    out->temp_c = code[0] * 503.975f / 4096.0f - 273.15f;
    out->vccint_v = code[1] * 3.0f / 4096.0f;
    out->vccaux_v = code[2] * 3.0f / 4096.0f;
    out->vccbram_v = code[3] * 3.0f / 4096.0f;
    return ESP_OK;
}

esp_err_t fpga_v4_read_temp_c(const fpga_v4_cfg_pins_t *p, float *temp_c)
{
    if (!temp_c) return ESP_ERR_INVALID_ARG;
    fpga_v4_sensors_t s;
    esp_err_t err = fpga_v4_read_sensors(p, &s);
    if (err == ESP_OK) *temp_c = s.temp_c;
    return err;
}

// ---------------- config flash (W25Q32JV) through Quad-SPI FLASH_XFER ----------------

#define F_WREN  0x06
#define F_RDSR1 0x05
#define F_READ  0x03
#define F_PP    0x02
#define F_SE    0x20
#define F_BE64  0xD8
#define F_JEDEC 0x9F
#define RD_CHUNK (FPGA_V4_FLASH_XFER_MAX - 16)   // data bytes per Read Data transaction (4-byte command)

// One flash transaction = one fpga_v4_flash_xfer(): the FPGA keeps CS low
// for all the bytes and stores the flash's response to each byte; the
// response to byte k is rx[k].

static esp_err_t jedec_id(fpga_v4_qspi_handle_t q, uint32_t *id)
{
    uint8_t tx[4] = { F_JEDEC }, rx[4];
    esp_err_t err = fpga_v4_flash_xfer(q, tx, sizeof tx, rx);
    if (err == ESP_OK) *id = ((uint32_t)rx[1] << 16) | ((uint32_t)rx[2] << 8) | rx[3];
    return err;
}

esp_err_t fpga_v4_flash_jedec_id(fpga_v4_qspi_handle_t q, uint32_t *id)
{
    if (!q || !id) return ESP_ERR_INVALID_ARG;
    return jedec_id(q, id);
}

static esp_err_t read_status(fpga_v4_qspi_handle_t q, uint8_t *sr)
{
    uint8_t tx[2] = { F_RDSR1, 0xFF }, rx[2];
    esp_err_t err = fpga_v4_flash_xfer(q, tx, sizeof tx, rx);
    if (err == ESP_OK) *sr = rx[1];
    return err;
}

// BUSY (SR1 bit0) low: polled every 20 us for the first 50 polls (page
// program, tPP 0.4 ms typ.), then every 1 ms (erase, tSE up to 400 ms).
static esp_err_t wait_ready(fpga_v4_qspi_handle_t q, uint32_t timeout_ms)
{
    TickType_t start = xTaskGetTickCount();
    for (int poll = 0;; poll++) {
        uint8_t sr;
        esp_err_t err = read_status(q, &sr);
        if (err != ESP_OK) return err;
        if (!(sr & 0x01)) return ESP_OK;
        if ((xTaskGetTickCount() - start) * portTICK_PERIOD_MS >= timeout_ms) return ESP_ERR_TIMEOUT;
        if (poll < 50) ets_delay_us(20); else vTaskDelay(pdMS_TO_TICKS(1));
    }
}

static esp_err_t write_enable(fpga_v4_qspi_handle_t q)
{
    uint8_t c = F_WREN, sr;
    esp_err_t err = fpga_v4_flash_xfer(q, &c, 1, NULL);
    if (err == ESP_OK) err = read_status(q, &sr);
    if (err == ESP_OK && !(sr & 0x02)) {     // WEL not set: write protected or command not taken
        ESP_LOGE(TAG, "flash WEL not set after Write Enable (SR1 0x%02x)", sr);
        return ESP_ERR_INVALID_STATE;
    }
    return err;
}

static esp_err_t cmd_addr(fpga_v4_qspi_handle_t q, uint8_t cmd, uint32_t addr, const uint8_t *data, size_t n)
{
    uint8_t buf[4 + 256];
    buf[0] = cmd; buf[1] = (uint8_t)(addr >> 16); buf[2] = (uint8_t)(addr >> 8); buf[3] = (uint8_t)addr;
    if (n) memcpy(buf + 4, data, n);
    return fpga_v4_flash_xfer(q, buf, 4 + n, NULL);
}

static esp_err_t flash_read(fpga_v4_qspi_handle_t q, uint32_t addr, uint8_t *out, size_t len)
{
    uint8_t tx[4 + RD_CHUNK], rx[4 + RD_CHUNK];
    esp_err_t err = ESP_OK;
    while (len && err == ESP_OK) {
        size_t n = len < RD_CHUNK ? len : RD_CHUNK;
        memset(tx, 0xFF, 4 + n);
        tx[0] = F_READ; tx[1] = (uint8_t)(addr >> 16); tx[2] = (uint8_t)(addr >> 8); tx[3] = (uint8_t)addr;
        err = fpga_v4_flash_xfer(q, tx, 4 + n, rx);
        if (err == ESP_OK) memcpy(out, rx + 4, n);
        addr += n; out += n; len -= n;
    }
    return err;
}

esp_err_t fpga_v4_flash_read(fpga_v4_qspi_handle_t q, uint32_t addr, uint8_t *out, size_t len)
{
    if (!q || !out || addr + len > FPGA_V4_FLASH_SIZE) return ESP_ERR_INVALID_ARG;
    return flash_read(q, addr, out, len);
}

static esp_err_t flash_erase(fpga_v4_qspi_handle_t q, uint32_t addr, size_t len)
{
    uint32_t a = addr & ~0xFFFu, end = (uint32_t)((addr + len + 0xFFF) & ~0xFFFu);
    if (end > FPGA_V4_FLASH_SIZE) return ESP_ERR_INVALID_ARG;
    while (a < end) {
        bool block = !(a & 0xFFFF) && end - a >= 0x10000;
        esp_err_t err = write_enable(q);
        if (err == ESP_OK) err = cmd_addr(q, block ? F_BE64 : F_SE, a, NULL, 0);
        if (err == ESP_OK) err = wait_ready(q, block ? 2500 : 500);   // tBE2 2 s, tSE 400 ms max
        if (err != ESP_OK) { ESP_LOGE(TAG, "erase at 0x%06x: %s", (unsigned)a, esp_err_to_name(err)); return err; }
        a += block ? 0x10000 : 0x1000;
    }
    return ESP_OK;
}

esp_err_t fpga_v4_flash_erase(fpga_v4_qspi_handle_t q, uint32_t addr, size_t len)
{
    if (!q) return ESP_ERR_INVALID_ARG;
    return flash_erase(q, addr, len);
}

static esp_err_t flash_program(fpga_v4_qspi_handle_t q, uint32_t addr, const uint8_t *data, size_t len)
{
    uint32_t id;
    esp_err_t err = jedec_id(q, &id);
    if (err != ESP_OK) return err;
    if (id != FPGA_V4_FLASH_JEDEC) {
        ESP_LOGE(TAG, "flash JEDEC ID 0x%06x, expected W25Q32JV 0x%06x", (unsigned)id, (unsigned)FPGA_V4_FLASH_JEDEC);
        return ESP_ERR_INVALID_RESPONSE;
    }
    ESP_LOGI(TAG, "flash W25Q32JV: erase + program %u bytes at 0x%06x", (unsigned)len, (unsigned)addr);
    if ((err = flash_erase(q, addr, len)) != ESP_OK) return err;

    size_t pages = 0;
    for (size_t off = 0; off < len;) {
        size_t n = 256 - ((addr + off) & 0xFF);       // never cross a page (it would wrap)
        if (n > len - off) n = len - off;
        bool blank = true;
        for (size_t k = 0; k < n && blank; k++) blank = data[off + k] == 0xFF;
        if (!blank) {
            err = write_enable(q);
            if (err == ESP_OK) err = cmd_addr(q, F_PP, addr + off, data + off, n);
            if (err == ESP_OK) err = wait_ready(q, 10);   // tPP 3 ms max
            if (err != ESP_OK) { ESP_LOGE(TAG, "page program at 0x%06x: %s", (unsigned)(addr + off), esp_err_to_name(err)); return err; }
            pages++;
        }
        off += n;
    }

    uint8_t back[RD_CHUNK];
    for (size_t off = 0; off < len && err == ESP_OK; off += RD_CHUNK) {
        size_t n = len - off < RD_CHUNK ? len - off : RD_CHUNK;
        err = flash_read(q, addr + off, back, n);
        if (err == ESP_OK && memcmp(back, data + off, n)) {
            size_t k = 0;
            while (back[k] == data[off + k]) k++;
            ESP_LOGE(TAG, "verify: flash 0x%06x = 0x%02x, expected 0x%02x",
                     (unsigned)(addr + off + k), back[k], data[off + k]);
            err = ESP_ERR_INVALID_CRC;
        }
    }
    if (err != ESP_OK) return err;
    ESP_LOGI(TAG, "flash programmed and verified (%u pages written)", (unsigned)pages);
    return ESP_OK;
}

esp_err_t fpga_v4_flash_program(fpga_v4_qspi_handle_t q, const fpga_v4_cfg_pins_t *p,
                                uint32_t addr, const uint8_t *data, size_t len,
                                uint32_t reboot_timeout_ms)
{
    if (!q || !data || !len || (addr & 0xFFF) || addr + len > FPGA_V4_FLASH_SIZE) return ESP_ERR_INVALID_ARG;
    esp_err_t err = flash_program(q, addr, data, len);
    if (err != ESP_OK) return err;
    return p ? fpga_v4_reconfigure(p, reboot_timeout_ms) : ESP_OK;
}
