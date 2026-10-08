// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// ============================================================
// v4 -- ESP-IDF stand-in for the ESP32 <-> RTL co-simulation.
//
// The real ESP32 driver (firmware/esp32/components/fpga_neural) is
// compiled for the host against the headers in idf/, and every SPI
// transaction, GPIO change and delay is turned into a wire-level request
// to the Icarus testbench tb_v4_esp32_cosim.v over two named pipes:
//
//   C -> V (cosim_c2v)                      V -> C (cosim_v2c)
//   S n b0 .. b(n-1)    mgmt SPI, 1 line,    n bytes read on MISO
//                       mode 0, CS framed
//   Q k nout o.. d nin  Quad-SPI wire:       nin nibbles read
//                       k = keep CS low after, nout nibbles driven
//                       (high nibble first), d dummy clocks, nin read
//   G pin level         GPIO output          "0"
//   L pin               GPIO input level     level
//   D us                wait                 "0"
//   T                   time                 simulated time in us
//   X code              end of test          (none)
//
// The ESP32-S3 rules the v4 driver depends on are enforced here as
// ESP-IDF does (see driver/spi_master.h): a 32-bit address register,
// no MOSI + MISO data in one half-duplex transaction, max_transfer_sz,
// SPI_TRANS_CS_KEEP_ACTIVE only with the bus acquired. A violation
// prints the rule and returns ESP_ERR_INVALID_ARG, like the real driver
// (or, for the address width, instead of the garbage the hardware sends).
// ============================================================
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "esp_err.h"
#include "esp_rom_sys.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "driver/spi_master.h"

static FILE *c2v, *v2c;
static int bus_max[3];
static int bus_quad[3];

struct spi_device_t {
    spi_host_device_t host;
    spi_device_interface_config_t cfg;
    int acquired;
    int cs_low;
};

void cosim_open(const char *c2v_path, const char *v2c_path)
{
    c2v = fopen(c2v_path, "w");
    v2c = fopen(v2c_path, "r");
    if (!c2v || !v2c) { perror("cosim pipes"); exit(2); }
}

void cosim_finish(int code)
{
    fprintf(c2v, "X %d\n", code);
    fflush(c2v);
}

static long ask(void)
{
    fflush(c2v);
    long v;
    if (fscanf(v2c, "%ld", &v) != 1) { fprintf(stderr, "cosim: testbench gone\n"); exit(3); }
    return v;
}

const char *esp_err_to_name(esp_err_t c)
{
    switch (c) {
    case ESP_OK: return "ESP_OK";
    case ESP_FAIL: return "ESP_FAIL";
    case ESP_ERR_NO_MEM: return "ESP_ERR_NO_MEM";
    case ESP_ERR_INVALID_ARG: return "ESP_ERR_INVALID_ARG";
    case ESP_ERR_INVALID_STATE: return "ESP_ERR_INVALID_STATE";
    case ESP_ERR_NOT_SUPPORTED: return "ESP_ERR_NOT_SUPPORTED";
    case ESP_ERR_TIMEOUT: return "ESP_ERR_TIMEOUT";
    case ESP_ERR_INVALID_RESPONSE: return "ESP_ERR_INVALID_RESPONSE";
    case ESP_ERR_INVALID_SIZE: return "ESP_ERR_INVALID_SIZE";
    case ESP_ERR_NOT_FOUND: return "ESP_ERR_NOT_FOUND";
    case ESP_ERR_INVALID_CRC: return "ESP_ERR_INVALID_CRC";
    default: return "ESP_ERR_?";
    }
}

// ---------------- time ----------------
void ets_delay_us(uint32_t us) { fprintf(c2v, "D %u\n", us); ask(); }
TickType_t xTaskGetTickCount(void) { fprintf(c2v, "T\n"); return (TickType_t)(ask() / 1000); }
void vTaskDelay(TickType_t t) { fprintf(c2v, "D %u\n", (unsigned)t * 1000u); ask(); }

// ---------------- GPIO ----------------
esp_err_t gpio_config(const gpio_config_t *c) { (void)c; return ESP_OK; }
esp_err_t gpio_set_level(gpio_num_t pin, uint32_t level) { fprintf(c2v, "G %d %u\n", pin, level & 1); ask(); return ESP_OK; }
int gpio_get_level(gpio_num_t pin) { fprintf(c2v, "L %d\n", pin); return (int)ask(); }
esp_err_t gpio_install_isr_service(int f) { (void)f; return ESP_OK; }
esp_err_t gpio_isr_handler_add(gpio_num_t p, gpio_isr_t i, void *a) { (void)p; (void)i; (void)a; return ESP_OK; }
esp_err_t gpio_set_intr_type(gpio_num_t p, gpio_int_type_t t) { (void)p; (void)t; return ESP_OK; }

// ---------------- SPI ----------------
#define RULE(cond, msg) do { if (!(cond)) { fprintf(stderr, "cosim: ESP-IDF rule violated: %s\n", msg); return ESP_ERR_INVALID_ARG; } } while (0)

esp_err_t spi_bus_initialize(spi_host_device_t host, const spi_bus_config_t *cfg, int dma)
{
    (void)dma;
    if (bus_max[host]) return ESP_ERR_INVALID_STATE;
    bus_max[host] = cfg->max_transfer_sz ? cfg->max_transfer_sz : 4092;
    bus_quad[host] = (cfg->flags & SPICOMMON_BUSFLAG_QUAD) != 0;
    return ESP_OK;
}

esp_err_t spi_bus_add_device(spi_host_device_t host, const spi_device_interface_config_t *cfg, spi_device_handle_t *out)
{
    RULE(bus_max[host], "bus not initialized");
    RULE(cfg->mode == 0, "cosim models SPI mode 0 only");
    struct spi_device_t *d = calloc(1, sizeof(*d));
    d->host = host; d->cfg = *cfg;
    *out = d;
    return ESP_OK;
}

esp_err_t spi_bus_remove_device(spi_device_handle_t d) { free(d); return ESP_OK; }
esp_err_t spi_device_acquire_bus(spi_device_handle_t d, uint32_t w) { (void)w; d->acquired = 1; return ESP_OK; }
void spi_device_release_bus(spi_device_handle_t d)
{
    d->acquired = 0;
    if (d->cs_low) {    // the real driver deasserts a kept CS on release
        fprintf(c2v, "Q 0 0 0 0\n"); ask(); d->cs_low = 0;
    }
}

static void put_nibbles(const uint8_t *p, size_t nbits, int lines)
{
    // MSB first; with 4 lines one nibble per clock, with 1 line one bit
    // per clock (sent as a nibble whose bit 0 is the MOSI value)
    if (lines == 4) for (size_t i = 0; i < nbits / 4; i++) fprintf(c2v, " %x", (p[i / 2] >> ((i & 1) ? 0 : 4)) & 15);
    else            for (size_t i = 0; i < nbits; i++) fprintf(c2v, " %x", (p[i / 8] >> (7 - (i & 7))) & 1);
}

esp_err_t spi_device_transmit(spi_device_handle_t d, spi_transaction_t *t)
{
    const int hd = (d->cfg.flags & SPI_DEVICE_HALFDUPLEX) != 0;
    const int qio = (t->flags & SPI_TRANS_MODE_QIO) != 0;
    spi_transaction_ext_t *e = (spi_transaction_ext_t *)t;
    int cmd_bits = (t->flags & SPI_TRANS_VARIABLE_CMD) ? e->command_bits : d->cfg.command_bits;
    int addr_bits = (t->flags & SPI_TRANS_VARIABLE_ADDR) ? e->address_bits : d->cfg.address_bits;
    int dummy = (t->flags & SPI_TRANS_VARIABLE_DUMMY) ? e->dummy_bits : d->cfg.dummy_bits;
    size_t rxlen = t->rxlength;
    if (!hd && rxlen == 0) rxlen = t->length;

    RULE(t->length <= (size_t)bus_max[d->host] * 8, "txdata transfer > host maximum (max_transfer_sz)");
    RULE(t->rxlength <= (size_t)bus_max[d->host] * 8, "rxdata transfer > host maximum (max_transfer_sz)");
    RULE(!qio || hd, "multi-line mode needs half duplex");
    RULE(!qio || bus_quad[d->host], "QIO on a bus without SPICOMMON_BUSFLAG_QUAD");
    RULE(!hd || !t->tx_buffer || !t->rx_buffer || !t->length || !t->rxlength,
         "ESP32-S3: half duplex cannot have both MOSI and MISO phases (SOC_SPI_HD_BOTH_INOUT_SUPPORTED unset)");
    RULE(addr_bits <= 32, "ESP32-S3: address phase longer than the 32-bit address register (spi_ll_set_address)");
    RULE(!(t->flags & SPI_TRANS_CS_KEEP_ACTIVE) || d->acquired, "SPI_TRANS_CS_KEEP_ACTIVE without spi_device_acquire_bus");
    RULE(t->length % 8 == 0 && rxlen % 8 == 0, "cosim models whole bytes only");

    if (!hd) {
        // management SPI: full duplex, 1 line, CS around the transaction
        RULE(cmd_bits == 0 && addr_bits == 0 && dummy == 0 && !(t->flags & SPI_TRANS_CS_KEEP_ACTIVE),
             "cosim: plain full-duplex transactions only on the management bus");
        size_t n = t->length / 8;
        const uint8_t *tx = t->tx_buffer;
        // 10 MHz: "S" (the original bench timing); any other clock: "F hz"
        if (d->cfg.clock_speed_hz == 10 * 1000 * 1000) fprintf(c2v, "S %zu", n);
        else fprintf(c2v, "F %d %zu", d->cfg.clock_speed_hz, n);
        for (size_t i = 0; i < n; i++) fprintf(c2v, " %x", tx ? tx[i] : 0);
        fprintf(c2v, "\n");
        long got = ask();
        if (got != (long)n) { fprintf(stderr, "cosim: SPI length mismatch\n"); exit(3); }
        uint8_t *rx = t->rx_buffer;
        for (size_t i = 0; i < n; i++) { long b = ask(); if (rx) rx[i] = (uint8_t)b; }
        return ESP_OK;
    }

    // half duplex: cmd, addr, dummy, MOSI, MISO; lines per phase
    RULE(qio, "cosim: half duplex only in QIO on the data port");
    int cmd_lines = (t->flags & SPI_TRANS_MULTILINE_CMD) ? 4 : 1;
    int addr_lines = (t->flags & SPI_TRANS_MULTILINE_ADDR) ? 4 : 1;
    size_t nout = cmd_bits / cmd_lines + addr_bits / addr_lines + t->length / 4;
    size_t nin = t->rx_buffer ? t->rxlength / 4 : 0;
    fprintf(c2v, "Q %d %zu", (t->flags & SPI_TRANS_CS_KEEP_ACTIVE) ? 1 : 0, nout);
    uint8_t cb[2] = { (uint8_t)(t->cmd >> 8), (uint8_t)t->cmd };
    if (cmd_bits) put_nibbles(cmd_bits == 16 ? cb : cb + 1, cmd_bits, cmd_lines);
    if (addr_bits) {
        uint8_t ab[8];
        uint64_t a = t->addr << (64 - addr_bits);
        for (int i = 0; i < 8; i++) ab[i] = (uint8_t)(a >> (56 - 8 * i));
        put_nibbles(ab, addr_bits, addr_lines);
    }
    if (t->length) put_nibbles(t->tx_buffer, t->length, 4);
    fprintf(c2v, " %d %zu\n", dummy, nin);
    long got = ask();
    if (got != (long)nin) { fprintf(stderr, "cosim: QSPI length mismatch\n"); exit(3); }
    uint8_t *rx = t->rx_buffer;
    for (size_t i = 0; i < nin; i++) {
        long v = ask();
        if (i & 1) rx[i / 2] |= (uint8_t)v; else rx[i / 2] = (uint8_t)(v << 4);
    }
    d->cs_low = (t->flags & SPI_TRANS_CS_KEEP_ACTIVE) != 0;
    return ESP_OK;
}

esp_err_t spi_device_polling_transmit(spi_device_handle_t d, spi_transaction_t *t) { return spi_device_transmit(d, t); }
