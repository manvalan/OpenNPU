// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// ================================================================
// FPGA-Neural -- ESP32 (ESP-IDF) host driver implementation. See
// fpga_neural.h for the real, from-spec design rationale.
// ================================================================
#include "fpga_neural.h"

#include <string.h>
#include <stdlib.h>

#include "esp_log.h"
#include "esp_heap_caps.h"
#include "esp_rom_sys.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "fpga_neural";

struct fpga_neural_dev_s {
    spi_device_handle_t spi;
    spi_host_device_t host;
    spi_device_interface_config_t devcfg;   // kept for fpga_neural_set_clock()
    int pin_sys_rst;
    int pin_data_ready_n;
    fpga_neural_variant_t variant;
};

// ---- internal: one full-duplex, CS-framed transaction ----
// tx/rx may each be NULL if that direction isn't needed; when non-NULL
// they must be `len` bytes. ESP-IDF's SPI master already frames CS
// low/high around exactly this transaction, matching the real "one
// opcode byte as the first byte of a CS-low transaction" convention
// this whole protocol assumes (docs/FIRMWARE_SPEC.md SS3).
static esp_err_t xfer(fpga_neural_handle_t h, const uint8_t *tx, uint8_t *rx, size_t len)
{
    if (len == 0) return ESP_OK;
    spi_transaction_t t = {0};
    t.length = len * 8;
    t.tx_buffer = tx;
    t.rx_buffer = rx;
    return spi_device_transmit(h->spi, &t);
}

esp_err_t fpga_neural_init(const fpga_neural_config_t *cfg, fpga_neural_handle_t *out_handle)
{
    if (!cfg || !out_handle) return ESP_ERR_INVALID_ARG;

    fpga_neural_handle_t h = calloc(1, sizeof(*h));
    if (!h) return ESP_ERR_NO_MEM;
    h->pin_sys_rst = cfg->pin_sys_rst;
    h->pin_data_ready_n = cfg->pin_data_ready_n;
    h->variant = cfg->variant;

    spi_bus_config_t buscfg = {
        .mosi_io_num = cfg->pin_mosi,
        .miso_io_num = cfg->pin_miso,
        .sclk_io_num = cfg->pin_sclk,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = 8192, // real headroom for WRITE_MEM/READ_MEM bursts; raise if a
                                  // real workload needs a single transaction bigger than this
    };
    esp_err_t err = spi_bus_initialize(cfg->spi_host, &buscfg, SPI_DMA_CH_AUTO);
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE /* bus already initialized elsewhere */) {
        free(h);
        return err;
    }

    // Real SPI mode: MODE0 (CPOL=0,CPHA=0) -- derived directly from
    // spi_host_bridge_v3.v's own sampling (sclk_rise) / shift
    // (sclk_fall) edges, not assumed (see fpga_neural.h's own header).
    spi_device_interface_config_t devcfg = {
        .clock_speed_hz = cfg->clock_speed_hz,
        .mode = 0,
        .spics_io_num = cfg->pin_cs,
        .queue_size = 1,
        .flags = 0,
    };
    err = spi_bus_add_device(cfg->spi_host, &devcfg, &h->spi);
    if (err != ESP_OK) {
        free(h);
        return err;
    }
    h->host = cfg->spi_host;
    h->devcfg = devcfg;

    if (h->pin_sys_rst >= 0) {
        gpio_config_t io = {
            .pin_bit_mask = 1ULL << h->pin_sys_rst,
            .mode = GPIO_MODE_OUTPUT,
        };
        // sys_rst is active low (MIG reset): latch the released level
        // BEFORE enabling the output, so init never glitches a reset;
        // fpga_neural_board_reset() pulses it low.
        gpio_set_level(h->pin_sys_rst, 1);
        gpio_config(&io);
    }
    if (h->pin_data_ready_n >= 0) {
        gpio_config_t io = {
            .pin_bit_mask = 1ULL << h->pin_data_ready_n,
            .mode = GPIO_MODE_INPUT,
            .pull_up_en = GPIO_PULLUP_ENABLE, // active-low, idle-high signal
        };
        gpio_config(&io);
    }

    *out_handle = h;
    return ESP_OK;
}

esp_err_t fpga_neural_deinit(fpga_neural_handle_t h)
{
    if (!h) return ESP_ERR_INVALID_ARG;
    spi_bus_remove_device(h->spi);
    free(h);
    return ESP_OK;
}

esp_err_t fpga_neural_board_reset(fpga_neural_handle_t h, uint32_t hold_us)
{
    if (!h) return ESP_ERR_INVALID_ARG;
    if (h->pin_sys_rst < 0) return ESP_ERR_NOT_SUPPORTED;
    gpio_set_level(h->pin_sys_rst, 0);     // active low: assert
    ets_delay_us(hold_us);
    gpio_set_level(h->pin_sys_rst, 1);     // release
    return ESP_OK;
}

esp_err_t fpga_neural_reg_write(fpga_neural_handle_t h, uint8_t reg_addr, uint32_t value)
{
    if (!h) return ESP_ERR_INVALID_ARG;
    uint8_t tx[6];
    tx[0] = FPGA_NEURAL_OP_REG_WRITE;
    tx[1] = reg_addr;
    tx[2] = (uint8_t)(value >> 24);
    tx[3] = (uint8_t)(value >> 16);
    tx[4] = (uint8_t)(value >> 8);
    tx[5] = (uint8_t)(value);
    return xfer(h, tx, NULL, sizeof(tx));
}

esp_err_t fpga_neural_reg_read(fpga_neural_handle_t h, uint8_t reg_addr, uint32_t *out_value)
{
    if (!h || !out_value) return ESP_ERR_INVALID_ARG;
    uint8_t tx[6] = {FPGA_NEURAL_OP_REG_READ, reg_addr, 0, 0, 0, 0};
    uint8_t rx[6] = {0};
    esp_err_t err = xfer(h, tx, rx, sizeof(tx));
    if (err != ESP_OK) return err;
    // real response: byte0=echoed opcode-phase junk, byte1=echoed
    // reg_addr-phase junk, bytes2:5=value MSB-first (docs SS3.2).
    *out_value = ((uint32_t)rx[2] << 24) | ((uint32_t)rx[3] << 16) |
                 ((uint32_t)rx[4] << 8)  |  (uint32_t)rx[5];
    return ESP_OK;
}

esp_err_t fpga_neural_reset_pulse(fpga_neural_handle_t h)
{
    if (!h) return ESP_ERR_INVALID_ARG;
    uint8_t tx = FPGA_NEURAL_OP_RESET;
    return xfer(h, &tx, NULL, 1);
}

esp_err_t fpga_neural_check_device_id(fpga_neural_handle_t h, bool *out_match, uint32_t *out_raw)
{
    if (!h || !out_match) return ESP_ERR_INVALID_ARG;
    uint32_t id;
    esp_err_t err = fpga_neural_reg_read(h, FPGA_NEURAL_REG_DEVICE_ID, &id);
    if (err != ESP_OK) return err;
    if (out_raw) *out_raw = id;
    *out_match = (id == ((h->variant == FPGA_NEURAL_VARIANT_CHAINED)
                             ? FPGA_NEURAL_DEVICE_ID_EXPECTED_CHAINED
                             : FPGA_NEURAL_DEVICE_ID_EXPECTED));
    return ESP_OK;
}

esp_err_t fpga_neural_wait_calib_complete(fpga_neural_handle_t h, uint32_t timeout_ms)
{
    if (!h) return ESP_ERR_INVALID_ARG;
    const uint32_t calib_bit = (h->variant == FPGA_NEURAL_VARIANT_CHAINED)
                                   ? FPGA_NEURAL_CH_STATUS_INIT_CALIB_COMPLETE
                                   : FPGA_NEURAL_NC_STATUS_INIT_CALIB_COMPLETE;
    TickType_t start = xTaskGetTickCount();
    for (;;) {
        uint32_t status;
        esp_err_t err = fpga_neural_reg_read(h, FPGA_NEURAL_REG_STATUS, &status);
        if (err != ESP_OK) return err;
        if (status & calib_bit) return ESP_OK;
        if ((xTaskGetTickCount() - start) * portTICK_PERIOD_MS >= timeout_ms) return ESP_ERR_TIMEOUT;
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}

esp_err_t fpga_neural_status_opcode(fpga_neural_handle_t h, uint8_t *out_status)
{
    if (!h || !out_status) return ESP_ERR_INVALID_ARG;
    if (h->variant != FPGA_NEURAL_VARIANT_NONCHAINED) return ESP_ERR_INVALID_STATE;
    uint8_t tx[2] = {FPGA_NEURAL_OP_STATUS, 0};
    uint8_t rx[2] = {0};
    esp_err_t err = xfer(h, tx, rx, sizeof(tx));
    if (err != ESP_OK) return err;
    *out_status = rx[1];
    return ESP_OK;
}

esp_err_t fpga_neural_write_job(fpga_neural_handle_t h, const fpga_neural_job_t *job)
{
    if (!h || !job) return ESP_ERR_INVALID_ARG;
    if (h->variant != FPGA_NEURAL_VARIANT_NONCHAINED) return ESP_ERR_INVALID_STATE;

    uint8_t tx[17];
    tx[0] = FPGA_NEURAL_OP_WRITE_JOB;
    tx[1] = (uint8_t)(job->node_id >> 8);
    tx[2] = (uint8_t)(job->node_id);
    tx[3] = (uint8_t)(job->x_base >> 24) & 0x03; // {6'b0, x_base[25:24]} -- top 6 bits of byte2 are zero
    tx[4] = (uint8_t)(job->x_base >> 16);
    tx[5] = (uint8_t)(job->x_base >> 8);
    tx[6] = (uint8_t)(job->x_base);
    tx[7] = (uint8_t)(job->w_base >> 24) & 0x03;
    tx[8] = (uint8_t)(job->w_base >> 16);
    tx[9] = (uint8_t)(job->w_base >> 8);
    tx[10] = (uint8_t)(job->w_base);
    tx[11] = (uint8_t)(job->n_tiles >> 8);
    tx[12] = (uint8_t)(job->n_tiles);
    tx[13] = (uint8_t)(job->result_addr >> 24) & 0x03;
    tx[14] = (uint8_t)(job->result_addr >> 16);
    tx[15] = (uint8_t)(job->result_addr >> 8);
    tx[16] = (uint8_t)(job->result_addr);
    return xfer(h, tx, NULL, sizeof(tx));
}

esp_err_t fpga_neural_submit_batch(fpga_neural_handle_t h, const fpga_neural_job_t *jobs, size_t count)
{
    if (!h || !jobs || count == 0) return ESP_ERR_INVALID_ARG;
    if (h->variant != FPGA_NEURAL_VARIANT_NONCHAINED) return ESP_ERR_INVALID_STATE;

    // Real SS4.2 discipline: every job in the batch MUST share the
    // same w_base and n_tiles, or neural_director_grouped.v's own
    // queue stalls permanently with no in-band recovery. Check BEFORE
    // submitting anything.
    for (size_t i = 1; i < count; i++) {
        if (jobs[i].w_base != jobs[0].w_base || jobs[i].n_tiles != jobs[0].n_tiles) {
            ESP_LOGE(TAG, "submit_batch: job %zu w_base/n_tiles mismatch (real octet-stall risk, refusing)", i);
            return ESP_ERR_INVALID_ARG;
        }
    }
    for (size_t i = 0; i < count; i++) {
        esp_err_t err = fpga_neural_write_job(h, &jobs[i]);
        if (err != ESP_OK) return err;
    }
    return ESP_OK;
}

esp_err_t fpga_neural_write_mem(fpga_neural_handle_t h, uint32_t word_addr, const uint16_t *words, size_t count)
{
    if (!h || !words || count == 0) return ESP_ERR_INVALID_ARG;
    if (count > 0xFFFF) return ESP_ERR_INVALID_ARG; // real, protocol-limited len_words field is 16 bits

    size_t len = 1 + 4 + 2 + 2 * count;
    uint8_t *tx = heap_caps_malloc(len, MALLOC_CAP_DEFAULT);
    if (!tx) return ESP_ERR_NO_MEM;

    tx[0] = FPGA_NEURAL_OP_WRITE_MEM;
    tx[1] = (uint8_t)(word_addr >> 24) & 0x01; // {7'b0, addr[24]}
    tx[2] = (uint8_t)(word_addr >> 16);
    tx[3] = (uint8_t)(word_addr >> 8);
    tx[4] = (uint8_t)(word_addr);
    tx[5] = (uint8_t)(count >> 8);
    tx[6] = (uint8_t)(count);
    for (size_t i = 0; i < count; i++) {
        tx[7 + 2*i]     = (uint8_t)(words[i] >> 8);
        tx[7 + 2*i + 1] = (uint8_t)(words[i]);
    }

    esp_err_t err = xfer(h, tx, NULL, len);
    free(tx);
    return err;
}

esp_err_t fpga_neural_read_mem(fpga_neural_handle_t h, uint32_t word_addr, uint16_t *out_words, size_t count)
{
    if (!h || !out_words || count == 0) return ESP_ERR_INVALID_ARG;
    if (count > 0xFFFF) return ESP_ERR_INVALID_ARG;

    size_t len = 1 + 4 + 2 + 2 * count;
    uint8_t *tx = heap_caps_calloc(1, len, MALLOC_CAP_DEFAULT);
    uint8_t *rx = heap_caps_calloc(1, len, MALLOC_CAP_DEFAULT);
    if (!tx || !rx) { free(tx); free(rx); return ESP_ERR_NO_MEM; }

    tx[0] = FPGA_NEURAL_OP_READ_MEM;
    tx[1] = (uint8_t)(word_addr >> 24) & 0x01;
    tx[2] = (uint8_t)(word_addr >> 16);
    tx[3] = (uint8_t)(word_addr >> 8);
    tx[4] = (uint8_t)(word_addr);
    tx[5] = (uint8_t)(count >> 8);
    tx[6] = (uint8_t)(count);

    esp_err_t err = xfer(h, tx, rx, len);
    if (err == ESP_OK) {
        // real response starts at payload byte 7 (0-indexed after the
        // opcode byte -- docs SS6.1), i.e. rx[7..].
        for (size_t i = 0; i < count; i++) {
            out_words[i] = ((uint16_t)rx[7 + 2*i] << 8) | rx[7 + 2*i + 1];
        }
    }
    free(tx);
    free(rx);
    return err;
}

esp_err_t fpga_neural_read_result(fpga_neural_handle_t h, uint32_t result_addr,
                                   int8_t *out_value, uint16_t *out_node_id)
{
    if (!h || !out_value || !out_node_id) return ESP_ERR_INVALID_ARG;
    // real result_writeback.v addressing formula, docs SS5.
    uint32_t mem_addr_value   = result_addr * 2;
    uint32_t mem_addr_node_id = result_addr * 2 + 1;

    uint16_t w_value, w_node_id;
    esp_err_t err = fpga_neural_read_mem(h, mem_addr_value, &w_value, 1);
    if (err != ESP_OK) return err;
    err = fpga_neural_read_mem(h, mem_addr_node_id, &w_node_id, 1);
    if (err != ESP_OK) return err;

    *out_value = (int8_t)(w_value & 0xFF); // low byte = real INT8 result, zero-extended (docs SS5)
    *out_node_id = w_node_id;
    return ESP_OK;
}

esp_err_t fpga_neural_set_network_base(fpga_neural_handle_t h, uint32_t network_base_word_addr)
{
    if (!h) return ESP_ERR_INVALID_ARG;
    if (h->variant != FPGA_NEURAL_VARIANT_CHAINED) return ESP_ERR_INVALID_STATE;
    return fpga_neural_reg_write(h, FPGA_NEURAL_REG_NETWORK_BASE, network_base_word_addr);
}

esp_err_t fpga_neural_trigger_network_start(fpga_neural_handle_t h)
{
    if (!h) return ESP_ERR_INVALID_ARG;
    if (h->variant != FPGA_NEURAL_VARIANT_CHAINED) return ESP_ERR_INVALID_STATE;
    return fpga_neural_reg_write(h, FPGA_NEURAL_REG_CONTROL, FPGA_NEURAL_CONTROL_SEQ_START);
}

esp_err_t fpga_neural_wait_seq_done(fpga_neural_handle_t h, uint32_t timeout_ms)
{
    if (!h) return ESP_ERR_INVALID_ARG;
    if (h->variant != FPGA_NEURAL_VARIANT_CHAINED) return ESP_ERR_INVALID_STATE;
    TickType_t start = xTaskGetTickCount();
    for (;;) {
        uint32_t status;
        esp_err_t err = fpga_neural_reg_read(h, FPGA_NEURAL_REG_STATUS, &status);
        if (err != ESP_OK) return err;
        if (status & FPGA_NEURAL_CH_STATUS_SEQ_DONE) return ESP_OK;
        if ((xTaskGetTickCount() - start) * portTICK_PERIOD_MS >= timeout_ms) return ESP_ERR_TIMEOUT;
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}

esp_err_t fpga_neural_flash_xfer(fpga_neural_handle_t h, const uint8_t *tx, size_t tx_len, uint8_t *out_rx)
{
    if (!h || !tx || !out_rx || tx_len == 0) return ESP_ERR_INVALID_ARG;

    size_t total_after_opcode = tx_len + 2; // real, mandatory 2 trailing dummy bytes (docs SS6.2/EXP-0077)
    size_t len = 1 + total_after_opcode;
    uint8_t *txbuf = heap_caps_calloc(1, len, MALLOC_CAP_DEFAULT);
    uint8_t *rxbuf = heap_caps_calloc(1, len, MALLOC_CAP_DEFAULT);
    if (!txbuf || !rxbuf) { free(txbuf); free(rxbuf); return ESP_ERR_NO_MEM; }

    txbuf[0] = FPGA_NEURAL_OP_FLASH_XFER;
    memcpy(&txbuf[1], tx, tx_len);
    // txbuf[1+tx_len .. 1+tx_len+1] already zero (the 2 real trailing dummy bytes)

    esp_err_t err = xfer(h, txbuf, rxbuf, len);
    if (err == ESP_OK) {
        memcpy(out_rx, &rxbuf[1], total_after_opcode);
    }
    free(txbuf);
    free(rxbuf);
    return err;
}

esp_err_t fpga_neural_set_clock(fpga_neural_handle_t h, int clock_speed_hz, int *old_hz)
{
    if (!h || clock_speed_hz <= 0) return ESP_ERR_INVALID_ARG;
    if (old_hz) *old_hz = h->devcfg.clock_speed_hz;
    if (clock_speed_hz == h->devcfg.clock_speed_hz) return ESP_OK;
    esp_err_t err = spi_bus_remove_device(h->spi);
    if (err != ESP_OK) return err;
    h->devcfg.clock_speed_hz = clock_speed_hz;
    return spi_bus_add_device(h->host, &h->devcfg, &h->spi);
}

esp_err_t fpga_neural_flash_xfer_raw(fpga_neural_handle_t h, const uint8_t *tx, size_t len, uint8_t *out_rx)
{
    if (!h || !tx || len == 0) return ESP_ERR_INVALID_ARG;
    uint8_t *txbuf = heap_caps_calloc(1, len + 1, MALLOC_CAP_DEFAULT);
    uint8_t *rxbuf = heap_caps_calloc(1, len + 1, MALLOC_CAP_DEFAULT);
    if (!txbuf || !rxbuf) { free(txbuf); free(rxbuf); return ESP_ERR_NO_MEM; }
    txbuf[0] = FPGA_NEURAL_OP_FLASH_XFER;
    memcpy(&txbuf[1], tx, len);
    esp_err_t err = xfer(h, txbuf, rxbuf, len + 1);
    if (err == ESP_OK && out_rx) memcpy(out_rx, &rxbuf[1], len);
    free(txbuf);
    free(rxbuf);
    return err;
}

esp_err_t fpga_neural_data_ready_isr_add(fpga_neural_handle_t h, gpio_isr_t cb, void *arg)
{
    if (!h || !cb) return ESP_ERR_INVALID_ARG;
    if (h->pin_data_ready_n < 0) return ESP_ERR_NOT_SUPPORTED;

    gpio_config_t io = {
        .pin_bit_mask = 1ULL << h->pin_data_ready_n,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .intr_type = GPIO_INTR_NEGEDGE,
    };
    gpio_config(&io);
    gpio_install_isr_service(0); // safe to call more than once per ESP-IDF docs (returns
                                  // ESP_ERR_INVALID_STATE if already installed -- ignored)
    return gpio_isr_handler_add(h->pin_data_ready_n, cb, arg);
}
