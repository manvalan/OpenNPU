// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// FPGA-Neural v4 host API -- see include/fpga_neural_v4.h.
#include <string.h>
#include "fpga_neural_v4.h"

static size_t out_len(const fpga_v4_layout_t *lay)
{
    return lay->out_len ? lay->out_len : FPGA_V4_MFN_OUT_LEN;
}

static size_t img_bytes(const fpga_v4_layout_t *lay)
{
    return lay->img_bytes ? lay->img_bytes : FPGA_V4_MFN_IMAGE_BYTES;
}

static bool layout_ok(const fpga_v4_layout_t *lay)
{
    return out_len(lay) % 16 == 0 && img_bytes(lay) % 16 == 0;
}

void fpga_v4_pad_rows(const int8_t *src, int h, int w, int c, int8_t *dst)
{
    size_t row = (size_t)w * c, prow = (row + 15) / 16 * 16;
    for (int y = 0; y < h; y++) {
        memcpy(dst + y * prow, src + y * row, row);
        memset(dst + y * prow + row, 0, prow - row);
    }
}

void fpga_v4_pad_pixels(const int8_t *src, int h, int w, int c, int cpad, int8_t *dst)
{
    for (size_t p = 0; p < (size_t)h * w; p++) {
        memcpy(dst + p * cpad, src + p * c, c);
        memset(dst + p * cpad + c, 0, cpad - c);
    }
}

esp_err_t fpga_v4_layout_from_blob(const uint8_t *blob, size_t len, uint32_t hdr_w, fpga_v4_layout_t *lay)
{
    if (!blob || !lay || (size_t)(hdr_w + 2) * 16 > len) return ESP_ERR_INVALID_ARG;
    const uint8_t *w0 = blob + hdr_w * 16, *w1 = w0 + 16;
    // w0: [15:0] passes [47:16] desc_w [79:48] img_w [95:80] img_words
    // w1: [31:0] result_w [63:48] out_words [127:96] magic (v4_boot.v)
    uint32_t magic, img_w, result_w;
    memcpy(&magic, w1 + 12, 4);
    if (magic != FPGA_V4_MAGIC) return ESP_ERR_INVALID_RESPONSE;
    memcpy(&img_w, w0 + 6, 4);
    memcpy(&result_w, w1, 4);
    uint32_t img_words = w0[10] | (uint32_t)w0[11] << 8;
    uint32_t out_words = w1[6] | (uint32_t)w1[7] << 8;
    if (out_words == 0) return ESP_ERR_NOT_SUPPORTED;
    lay->hdr_w = hdr_w; lay->img_w = img_w; lay->result_w = result_w;
    lay->img_bytes = img_words * 16;
    lay->out_len = out_words * 16;
    return ESP_OK;
}

// ======================= the Quad-SPI link =======================
#include <stdlib.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_rom_sys.h"

#define V4_QSPI_CHUNK 16384u      // bytes per transaction (DMA-friendly)

struct fpga_v4_qspi_s {
    spi_device_handle_t dev;
    int pin_sys_rst, pin_data_ready_n;
};

esp_err_t fpga_v4_qspi_init(const fpga_v4_qspi_config_t *cfg, fpga_v4_qspi_handle_t *out)
{
    if (!cfg || !out) return ESP_ERR_INVALID_ARG;
    spi_bus_config_t bus = {
        .sclk_io_num = cfg->pin_sclk,
        .data0_io_num = cfg->pin_io0,
        .data1_io_num = cfg->pin_io1,
        .data2_io_num = cfg->pin_io2,
        .data3_io_num = cfg->pin_io3,
        .max_transfer_sz = V4_QSPI_CHUNK,
        .flags = SPICOMMON_BUSFLAG_MASTER | SPICOMMON_BUSFLAG_QUAD,
    };
    esp_err_t err = spi_bus_initialize(cfg->spi_host, &bus, SPI_DMA_CH_AUTO);
    if (err != ESP_OK) return err;
    spi_device_interface_config_t dev = {
        .command_bits = 0,          // header goes out as QIO data, see the header file
        .address_bits = 0,
        .mode = 0,
        .clock_speed_hz = cfg->clock_speed_hz,
        .spics_io_num = cfg->pin_cs,
        // HALFDUPLEX: QIO needs it. NO_DUMMY: the 64 dummy cycles of a read
        // are part of the FPGA protocol, ESP-IDF must not add its own
        // timing-compensation cycles on top. The FPGA launches each read
        // nibble a full clock before the edge it is sampled on
        // (qspi_data_port.v): no input-delay compensation needed.
        .flags = SPI_DEVICE_HALFDUPLEX | SPI_DEVICE_NO_DUMMY,
        .input_delay_ns = 0,
        .queue_size = 2,
    };
    struct fpga_v4_qspi_s *q = calloc(1, sizeof(*q));
    if (!q) return ESP_ERR_NO_MEM;
    err = spi_bus_add_device(cfg->spi_host, &dev, &q->dev);
    if (err != ESP_OK) { free(q); return err; }
    q->pin_sys_rst = cfg->pin_sys_rst;
    q->pin_data_ready_n = cfg->pin_data_ready_n;
    if (q->pin_sys_rst >= 0) {
        // released level latched before the output is enabled: init never
        // glitches a reset
        gpio_config_t io = { .pin_bit_mask = 1ULL << q->pin_sys_rst, .mode = GPIO_MODE_OUTPUT };
        gpio_set_level(q->pin_sys_rst, 1);
        gpio_config(&io);
    }
    if (q->pin_data_ready_n >= 0) {
        gpio_config_t io = { .pin_bit_mask = 1ULL << q->pin_data_ready_n, .mode = GPIO_MODE_INPUT,
                             .pull_up_en = GPIO_PULLUP_ENABLE };
        gpio_config(&io);
    }
    *out = q;
    return ESP_OK;
}

// One Quad-SPI command: the 7-byte header, then (if len) the payload
// transaction with CS kept low in between: write data, or 64 dummy
// cycles + read data. f16 = the header's 16-bit field.
static esp_err_t qspi_cmd(fpga_v4_qspi_handle_t q, uint8_t cmd, uint32_t w, uint16_t f16,
                          const void *tx, void *rx, size_t len)
{
    uint8_t hdr[8] = { cmd, (uint8_t)(w >> 24), (uint8_t)(w >> 16), (uint8_t)(w >> 8), (uint8_t)w,
                       (uint8_t)(f16 >> 8), (uint8_t)f16, 0 };
    spi_transaction_ext_t th = {0};
    th.base.flags = SPI_TRANS_MODE_QIO | (len ? SPI_TRANS_CS_KEEP_ACTIVE : 0);
    th.base.length = 7 * 8;
    th.base.tx_buffer = hdr;
    spi_transaction_ext_t td = {0};
    td.base.flags = SPI_TRANS_MODE_QIO | SPI_TRANS_VARIABLE_DUMMY;
    if (tx) { td.base.length = len * 8; td.base.tx_buffer = tx; td.dummy_bits = 0; }
    else    { td.base.rxlength = len * 8; td.base.rx_buffer = rx; td.dummy_bits = FPGA_V4_QSPI_DUMMY; }

    esp_err_t err = spi_device_acquire_bus(q->dev, portMAX_DELAY);
    if (err != ESP_OK) return err;
    err = spi_device_polling_transmit(q->dev, (spi_transaction_t *)&th);
    if (err == ESP_OK && len) err = spi_device_transmit(q->dev, (spi_transaction_t *)&td);
    spi_device_release_bus(q->dev);
    return err;
}

static esp_err_t qspi_xfer(fpga_v4_qspi_handle_t q, uint8_t cmd, uint32_t w, const void *tx, void *rx, size_t len)
{
    return qspi_cmd(q, cmd, w, (uint16_t)(len / 16), tx, rx, len);
}

esp_err_t fpga_v4_qspi_write(fpga_v4_qspi_handle_t q, uint32_t dst_w, const void *data, size_t len)
{
    if (!q || !data || (len % 16)) return ESP_ERR_INVALID_ARG;
    const uint8_t *p = data;
    while (len) {
        size_t k = len > V4_QSPI_CHUNK ? V4_QSPI_CHUNK : len;
        esp_err_t err = qspi_xfer(q, FPGA_V4_QSPI_CMD_WRITE, dst_w, p, NULL, k);
        if (err != ESP_OK) return err;
        p += k; dst_w += k / 16; len -= k;
    }
    return ESP_OK;
}

esp_err_t fpga_v4_qspi_read(fpga_v4_qspi_handle_t q, uint32_t src_w, void *out, size_t len)
{
    if (!q || !out || (len % 16)) return ESP_ERR_INVALID_ARG;
    uint8_t *p = out;
    while (len) {
        size_t k = len > V4_QSPI_CHUNK ? V4_QSPI_CHUNK : len;
        esp_err_t err = qspi_xfer(q, FPGA_V4_QSPI_CMD_READ, src_w, NULL, p, k);
        if (err != ESP_OK) return err;
        p += k; src_w += k / 16; len -= k;
    }
    return ESP_OK;
}

esp_err_t fpga_v4_stage_image(fpga_v4_qspi_handle_t q, const fpga_v4_layout_t *lay,
                              const int8_t *image)
{
    if (!lay) return ESP_ERR_INVALID_ARG;
    return fpga_v4_qspi_write(q, lay->img_w, image, img_bytes(lay));
}

esp_err_t fpga_v4_reg_write(fpga_v4_qspi_handle_t q, uint16_t reg, uint32_t value)
{
    if (!q) return ESP_ERR_INVALID_ARG;
    return qspi_cmd(q, FPGA_V4_QSPI_CMD_REG_WRITE, value, reg, NULL, NULL, 0);
}

esp_err_t fpga_v4_read_status(fpga_v4_qspi_handle_t q, fpga_v4_status_t *st)
{
    if (!q || !st) return ESP_ERR_INVALID_ARG;
    uint8_t w[16];
    esp_err_t err = qspi_cmd(q, FPGA_V4_QSPI_CMD_STATUS, 0, 1, NULL, w, 16);
    if (err != ESP_OK) return err;
    memcpy(&st->id, w, 4);
    memcpy(&st->network_base, w + 4, 4);
    st->calibrated = w[8] & 1;
    st->error      = (w[8] >> 1) & 1;
    st->busy       = (w[8] >> 2) & 1;
    st->done       = (w[8] >> 3) & 1;
    st->flash_busy = (w[8] >> 4) & 1;
    return ESP_OK;
}

esp_err_t fpga_v4_board_reset(fpga_v4_qspi_handle_t q, uint32_t hold_us)
{
    if (!q) return ESP_ERR_INVALID_ARG;
    if (q->pin_sys_rst < 0) return ESP_ERR_NOT_SUPPORTED;
    gpio_set_level(q->pin_sys_rst, 0);
    esp_rom_delay_us(hold_us);
    gpio_set_level(q->pin_sys_rst, 1);
    return ESP_OK;
}

esp_err_t fpga_v4_wait_calib(fpga_v4_qspi_handle_t q, uint32_t timeout_ms)
{
    TickType_t t0 = xTaskGetTickCount();
    for (;;) {
        fpga_v4_status_t st;
        esp_err_t err = fpga_v4_read_status(q, &st);
        if (err != ESP_OK) return err;
        if (st.id == FPGA_V4_DEVICE_ID && st.calibrated) return ESP_OK;
        if ((xTaskGetTickCount() - t0) * portTICK_PERIOD_MS >= timeout_ms) return ESP_ERR_TIMEOUT;
        vTaskDelay(1);
    }
}

esp_err_t fpga_v4_wait_run(fpga_v4_qspi_handle_t q, uint32_t timeout_ms)
{
    TickType_t t0 = xTaskGetTickCount();
    for (;;) {
        fpga_v4_status_t st;
        esp_err_t err = fpga_v4_read_status(q, &st);
        if (err != ESP_OK) return err;
        if (st.error) return ESP_FAIL;
        if (st.done) return ESP_OK;
        if ((xTaskGetTickCount() - t0) * portTICK_PERIOD_MS >= timeout_ms) return ESP_ERR_TIMEOUT;
        // runs last 50 us .. tens of ms: poll at the bus rate, not per tick
        esp_rom_delay_us(20);
    }
}

esp_err_t fpga_v4_data_ready_isr_add(fpga_v4_qspi_handle_t q, gpio_isr_t cb, void *arg)
{
    if (!q || !cb) return ESP_ERR_INVALID_ARG;
    if (q->pin_data_ready_n < 0) return ESP_ERR_NOT_SUPPORTED;
    gpio_set_intr_type(q->pin_data_ready_n, GPIO_INTR_NEGEDGE);
    esp_err_t err = gpio_install_isr_service(0);
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err;
    return gpio_isr_handler_add(q->pin_data_ready_n, cb, arg);
}

esp_err_t fpga_v4_flash_xfer(fpga_v4_qspi_handle_t q, const uint8_t *tx, size_t n, uint8_t *rx)
{
    if (!q || !tx || n == 0 || n > FPGA_V4_FLASH_XFER_MAX) return ESP_ERR_INVALID_ARG;
    static uint8_t buf[FPGA_V4_FLASH_XFER_MAX];
    size_t padded = (n + 15) / 16 * 16;
    memcpy(buf, tx, n);
    memset(buf + n, 0, padded - n);
    esp_err_t err = qspi_cmd(q, FPGA_V4_QSPI_CMD_FLASH_XFER, 0, (uint16_t)n, buf, NULL, padded);
    if (err != ESP_OK) return err;
    // the transaction runs inside the FPGA at ~19 MHz: ~0.5 us per byte
    for (int tries = 0; ; tries++) {
        fpga_v4_status_t st;
        err = fpga_v4_read_status(q, &st);
        if (err != ESP_OK) return err;
        if (!st.flash_busy) break;
        if (tries > 1000) return ESP_ERR_TIMEOUT;
        esp_rom_delay_us(2);
    }
    if (!rx) return ESP_OK;
    err = qspi_cmd(q, FPGA_V4_QSPI_CMD_FLASH_READ, 0, (uint16_t)(padded / 16), NULL, buf, padded);
    if (err != ESP_OK) return err;
    memcpy(rx, buf, n);
    return ESP_OK;
}

esp_err_t fpga_v4_load_blob(fpga_v4_qspi_handle_t q, uint32_t dst_w, const uint8_t *blob, size_t len)
{
    return fpga_v4_qspi_write(q, dst_w, blob, len);
}

esp_err_t fpga_v4_start(fpga_v4_qspi_handle_t q, const fpga_v4_layout_t *lay)
{
    if (!q || !lay) return ESP_ERR_INVALID_ARG;
    esp_err_t err = fpga_v4_reg_write(q, FPGA_V4_REG_NETWORK_BASE, lay->hdr_w * 4);
    if (err != ESP_OK) return err;
    return fpga_v4_reg_write(q, FPGA_V4_REG_CONTROL, FPGA_V4_CONTROL_START);
}

esp_err_t fpga_v4_finish(fpga_v4_qspi_handle_t q, const fpga_v4_layout_t *lay,
                         int8_t *out, fpga_v4_stats_t *stats, uint32_t timeout_ms)
{
    if (!q || !lay || !out || !layout_ok(lay)) return ESP_ERR_INVALID_ARG;
    esp_err_t err = fpga_v4_wait_run(q, timeout_ms);
    if (err != ESP_OK && err != ESP_FAIL) return err;
    // output straight into the caller's buffer, then the statistics word
    size_t n = out_len(lay);
    err = fpga_v4_qspi_read(q, lay->result_w, out, n);
    if (err != ESP_OK) return err;
    uint8_t st[16];
    err = fpga_v4_qspi_read(q, lay->result_w + n / 16, st, 16);
    if (err != ESP_OK) return err;
    uint32_t magic;
    memcpy(&magic, st + 12, 4);
    if (magic != FPGA_V4_MAGIC) return ESP_ERR_INVALID_RESPONSE;
    if (stats) {
        memcpy(&stats->core_cycles, st, 4);
        memcpy(&stats->param_wait_cycles, st + 4, 4);
        stats->error = st[8] & 1;
    }
    return (st[8] & 1) ? ESP_FAIL : ESP_OK;
}

esp_err_t fpga_v4_infer(fpga_v4_qspi_handle_t q, const fpga_v4_layout_t *lay,
                        const int8_t *image,
                        int8_t *out, fpga_v4_stats_t *stats,
                        uint32_t timeout_ms)
{
    esp_err_t err = fpga_v4_stage_image(q, lay, image);
    if (err != ESP_OK) return err;
    err = fpga_v4_start(q, lay);
    if (err != ESP_OK) return err;
    return fpga_v4_finish(q, lay, out, stats, timeout_ms);
}
