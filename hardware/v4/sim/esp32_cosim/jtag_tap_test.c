// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// ============================================================
// v4 -- host test of the ESP32 JTAG configuration code
// (fpga_v4_jtag_load_sram / fpga_v4_jtag_idcode in
// firmware/esp32/components/fpga_neural/fpga_neural_v4_config.c)
// against a C model of the XC7A100T TAP.
//
// The model is written from IEEE 1149.1 (16-state TAP, TMS/TDI sampled
// on the rising TCK edge, TDO driven on the falling edge, IR loaded in
// Update-IR) and UG470 ch. 6 (IR length 6, IDCODE 0x09, JPROGRAM 0x0B,
// CFG_IN 0x05, JSTART 0x0C, BYPASS 0x3F, ISC_NOOP 0x14; IR capture =
// {DONE, INIT complete, ..., 0, 1}). Its "configuration engine" only
// checks transport: the bits shifted through CFG_IN after a JPROGRAM and
// after INIT completed must equal the payload MSB first per byte, and
// JSTART must be followed by >= 2000 TCK in Run-Test/Idle; then DONE.
// It does NOT model the real configuration logic (CRC, frames, start-up
// sequence): that part is only checked on the real board.
//
//   gcc -I idf -I <fw>/include jtag_tap_test.c <fw>/fpga_neural_v4_config.c
// ============================================================
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "esp_err.h"
#include "esp_rom_sys.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "fpga_neural_v4.h"

enum { TLR, RTI, SELDR, CAPDR, SHDR, EX1DR, PADR, EX2DR, UPDR,
       SELIR, CAPIR, SHIR, EX1IR, PAIR, EX2IR, UPIR };
static const int next_state[16][2] = {   // [state][tms]
    [TLR] = {RTI, TLR},     [RTI] = {RTI, SELDR},
    [SELDR] = {CAPDR, SELIR}, [CAPDR] = {SHDR, EX1DR}, [SHDR] = {SHDR, EX1DR},
    [EX1DR] = {PADR, UPDR}, [PADR] = {PADR, EX2DR}, [EX2DR] = {SHDR, UPDR}, [UPDR] = {RTI, SELDR},
    [SELIR] = {CAPIR, TLR}, [CAPIR] = {SHIR, EX1IR}, [SHIR] = {SHIR, EX1IR},
    [EX1IR] = {PAIR, UPIR}, [PAIR] = {PAIR, EX2IR}, [EX2IR] = {SHIR, UPIR}, [UPIR] = {RTI, SELDR},
};

enum { P_TCK = 1, P_TMS, P_TDI, P_TDO, P_PROG, P_INIT, P_DONE };

static struct {
    int state, tck, tms, tdi, tdo;
    uint8_t ir, ir_sr;
    uint32_t dr_sr, idcode;
    int init, done;
    long t_us, init_at_us;            // simulated time; INIT completes 2 ms after JPROGRAM
    int programmed, cfg_ok_start;
    uint8_t *rx; size_t rx_bits, rx_cap;
    int jstart, rti_after_jstart;
    long rising_edges;
    const uint8_t *expect; size_t expect_len;
    // XADC DRP through JTAG (UG480): a read command is executed at Update-DR
    // and its result is captured by the NEXT Capture-DR only if >= 10 TCK
    // have passed (the model's stand-in for the arbiter latency).
    uint16_t xadc_reg[128];
    uint16_t xadc_out, xadc_pending;
    long xadc_ready_at;
    int xadc_reads;
} m;

static void model_reset(uint32_t idcode, const uint8_t *expect, size_t n)
{
    free(m.rx);
    memset(&m, 0, sizeof m);
    m.state = TLR; m.ir = 0x09; m.idcode = idcode;
    m.init = 1;                       // power-on configuration already cleared (flash blank)
    m.expect = expect; m.expect_len = n;
    m.rx_cap = n * 8 + 64;
    m.rx = calloc(1, m.rx_cap / 8 + 1);
}

static void update_init(void)
{
    if (!m.init && m.t_us >= m.init_at_us) m.init = 1;
}

static void rising(void)
{
    m.rising_edges++;
    update_init();
    int s = m.state;
    if (s == CAPIR) m.ir_sr = (uint8_t)(0x01 | (m.init << 4) | (m.done << 5));
    if (s == SHIR)  m.ir_sr = (uint8_t)((m.ir_sr >> 1) | (m.tdi << 5));
    if (s == CAPDR) {
        if (m.ir == 0x37) {
            if (m.xadc_ready_at && m.rising_edges >= m.xadc_ready_at) { m.xadc_out = m.xadc_pending; m.xadc_ready_at = 0; }
            m.dr_sr = m.xadc_out;
        } else m.dr_sr = m.ir == 0x09 ? m.idcode : 0;
    }
    if (s == SHDR) {
        if (m.ir == 0x05) {
            if (m.rx_bits == 0) m.cfg_ok_start = m.programmed && m.init;
            if (m.rx_bits < m.rx_cap) {
                if (m.tdi) m.rx[m.rx_bits / 8] |= (uint8_t)(0x80 >> (m.rx_bits % 8));
                m.rx_bits++;
            }
        } else m.dr_sr = (m.dr_sr >> 1) | ((uint32_t)m.tdi << 31);
    }
    if (s == RTI && m.jstart) m.rti_after_jstart++;
    int ns = next_state[s][m.tms];
    if (ns == UPIR) {
        m.ir = m.ir_sr;
        if (m.ir == 0x0B) {           // JPROGRAM: clear, INIT low for 2 ms
            m.programmed = 1; m.init = 0; m.done = 0; m.init_at_us = m.t_us + 2000;
            m.rx_bits = 0; memset(m.rx, 0, m.rx_cap / 8 + 1); m.jstart = 0;
        }
        if (m.ir == 0x0C) { m.jstart = 1; m.rti_after_jstart = 0; }
    }
    if (ns == UPDR && m.ir == 0x37) {
        uint32_t cmd = (m.dr_sr >> 26) & 15, addr = (m.dr_sr >> 16) & 0x3FF;
        if (cmd == 1) { m.xadc_pending = m.xadc_reg[addr & 127]; m.xadc_ready_at = m.rising_edges + 10; m.xadc_reads++; }
    }
    if (ns == TLR) m.ir = 0x09;
    m.state = ns;
    if (m.jstart && m.rti_after_jstart >= 2000 && m.cfg_ok_start &&
        m.rx_bits == m.expect_len * 8 && !memcmp(m.rx, m.expect, m.expect_len))
        m.done = 1;
}

static void falling(void)
{
    if (m.state == SHIR) m.tdo = m.ir_sr & 1;
    else if (m.state == SHDR) m.tdo = (m.ir == 0x09 || m.ir == 0x37) ? (int)(m.dr_sr & 1) : 0;
}

// ---- ESP-IDF stand-ins ----
const char *esp_err_to_name(esp_err_t c)
{
    static char b[16]; snprintf(b, sizeof b, "0x%x", c); return c == ESP_OK ? "ESP_OK" : b;
}
void ets_delay_us(uint32_t us) { m.t_us += us; }
TickType_t xTaskGetTickCount(void) { return (TickType_t)(m.t_us / 1000); }
void vTaskDelay(TickType_t t) { m.t_us += (long)t * 1000; }
esp_err_t gpio_config(const gpio_config_t *c) { (void)c; return ESP_OK; }
esp_err_t gpio_set_level(gpio_num_t pin, uint32_t lv)
{
    lv &= 1;
    if (pin == P_TMS) m.tms = lv;
    else if (pin == P_TDI) m.tdi = lv;
    else if (pin == P_TCK) {
        if (lv && !m.tck) rising();
        if (!lv && m.tck) falling();
        m.tck = lv;
    }
    return ESP_OK;
}
int gpio_get_level(gpio_num_t pin)
{
    update_init();
    if (pin == P_TDO) return m.tdo;
    if (pin == P_INIT) return m.init;
    if (pin == P_DONE) return m.done;
    return 0;
}
esp_err_t fpga_v4_flash_xfer(fpga_v4_qspi_handle_t q, const uint8_t *tx, size_t n, uint8_t *rx)
{ (void)q; (void)tx; (void)n; (void)rx; return ESP_ERR_NOT_SUPPORTED; }

// ---- tests ----
static int fails;
#define CHECK(c, ...) do { if (c) printf("  ok   " __VA_ARGS__); else { printf("  FAIL " __VA_ARGS__); fails++; } printf("\n"); } while (0)

int main(void)
{
    const fpga_v4_cfg_pins_t pins = { P_TCK, P_TMS, P_TDI, P_TDO, P_PROG, P_INIT, P_DONE };
    // payload shaped like a 7-series bitstream: padding, bus width, sync, data
    size_t n = 60000;
    uint8_t *pay = malloc(n);
    memset(pay, 0xFF, 32);
    const uint8_t head[] = { 0x00,0x00,0x00,0xBB, 0x11,0x22,0x00,0x44, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xAA,0x99,0x55,0x66 };
    memcpy(pay + 32, head, sizeof head);
    srand(7);
    for (size_t i = 32 + sizeof head; i < n; i++) pay[i] = (uint8_t)rand();
    // .bit file around it
    const char *f[4] = { "v4_board_top;UserID=0XFFFFFFFF", "7a100tcsg324", "2026/10/05", "21:00:00" };
    uint8_t *bit = malloc(n + 256); size_t bl = 0;
    const uint8_t pre[13] = { 0x00,0x09, 0x0f,0xf0,0x0f,0xf0,0x0f,0xf0,0x0f,0xf0,0x00, 0x00,0x01 };
    memcpy(bit, pre, 13); bl = 13;
    for (int k = 0; k < 4; k++) {
        size_t l = strlen(f[k]) + 1;
        bit[bl++] = (uint8_t)('a' + k); bit[bl++] = (uint8_t)(l >> 8); bit[bl++] = (uint8_t)l;
        memcpy(bit + bl, f[k], l); bl += l;
    }
    bit[bl++] = 'e'; bit[bl++] = (uint8_t)(n >> 24); bit[bl++] = (uint8_t)(n >> 16); bit[bl++] = (uint8_t)(n >> 8); bit[bl++] = (uint8_t)n;
    memcpy(bit + bl, pay, n); bl += n;

    printf("jtag_tap_test: fpga_v4_jtag_* against the TAP model\n");

    const uint8_t *d; size_t dl;
    esp_err_t e = fpga_v4_bitstream_payload(bit, bl, &d, &dl);
    CHECK(e == ESP_OK && d == bit + bl - n && dl == n, ".bit header parsed: payload %zu bytes at offset %zu", dl, (size_t)(d - bit));

    model_reset(0x13631093, pay, n);
    uint32_t id = 0;
    e = fpga_v4_jtag_idcode(&pins, &id);
    CHECK(e == ESP_OK && id == 0x13631093, "IDCODE read 0x%08x", (unsigned)id);

    model_reset(0x13631093, pay, n);
    e = fpga_v4_jtag_load_sram(&pins, bit, bl, 100);
    CHECK(e == ESP_OK && m.done, "load_sram: %s, DONE %d, %zu CFG_IN bits (payload %zu), %ld TCK, INIT waited until %ld us",
          esp_err_to_name(e), m.done, m.rx_bits, n * 8, m.rising_edges, m.init_at_us);
    CHECK(m.cfg_ok_start, "CFG_IN data started after JPROGRAM and INIT complete");
    CHECK(m.rti_after_jstart >= 2000 && m.state == RTI, "JSTART then %d TCK in Run-Test/Idle, TAP left in Run-Test/Idle", m.rti_after_jstart);

    model_reset(0x13631093, pay, n);
    e = fpga_v4_jtag_load_sram(&pins, pay, n, 100);
    CHECK(e == ESP_OK && m.done, "load_sram with a bare payload (.bin): %s", esp_err_to_name(e));

    model_reset(0x13636093, pay, n);   // XC7A200T-like IDCODE
    e = fpga_v4_jtag_load_sram(&pins, bit, bl, 100);
    CHECK(e == ESP_ERR_INVALID_RESPONSE && !m.programmed, "wrong IDCODE refused before JPROGRAM (%s)", esp_err_to_name(e));

    uint8_t *bad = malloc(n); memcpy(bad, pay, n); bad[n / 2] ^= 0x10;
    model_reset(0x13631093, pay, n);
    e = fpga_v4_jtag_load_sram(&pins, bad, n, 100);
    CHECK(e == ESP_ERR_INVALID_RESPONSE && !m.done, "corrupted payload: DONE stays low, error reported (%s)", esp_err_to_name(e));

    memset(bad, 0x00, 64);
    e = fpga_v4_jtag_load_sram(&pins, bad, n, 100);
    CHECK(e != ESP_OK, "image without sync word refused (%s)", esp_err_to_name(e));

    // XADC: 55.0 C, VCCINT 1.000 V, VCCAUX 1.800 V, VCCBRAM 0.990 V (12-bit codes in [15:4])
    model_reset(0x13631093, pay, n);
    m.xadc_reg[0x00] = (uint16_t)((int)((55.0 + 273.15) * 4096 / 503.975 + 0.5) << 4);
    m.xadc_reg[0x01] = (uint16_t)(1365 << 4);
    m.xadc_reg[0x02] = (uint16_t)(2458 << 4);
    m.xadc_reg[0x06] = (uint16_t)(1352 << 4);
    m.xadc_reg[0x03] = 0xDEAD;          // must not be returned
    fpga_v4_sensors_t se;
    e = fpga_v4_read_sensors(&pins, &se);
    CHECK(e == ESP_OK && se.temp_c > 54.8f && se.temp_c < 55.2f && se.vccint_v > 0.999f && se.vccint_v < 1.001f &&
          se.vccaux_v > 1.799f && se.vccaux_v < 1.801f && se.vccbram_v > 0.989f && se.vccbram_v < 0.991f && m.xadc_reads == 4,
          "XADC over JTAG: %.2f C, VCCINT %.3f V, VCCAUX %.3f V, VCCBRAM %.3f V (%d DRP reads)",
          se.temp_c, se.vccint_v, se.vccaux_v, se.vccbram_v, m.xadc_reads);
    float tc = 0;
    e = fpga_v4_read_temp_c(&pins, &tc);
    CHECK(e == ESP_OK && tc > 54.8f && tc < 55.2f, "fpga_v4_read_temp_c: %.2f C", tc);
    memset(m.xadc_reg, 0, sizeof m.xadc_reg);
    e = fpga_v4_read_sensors(&pins, &se);
    CHECK(e == ESP_ERR_INVALID_RESPONSE, "XADC answering 0 (JTAG_XADC disabled) reported as error (%s)", esp_err_to_name(e));

    printf(fails ? "FAILED: %d checks\n" : "ALL TESTS PASSED (JTAG TAP model)\n", fails);
    return fails != 0;
}
