// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// Host stand-in for ESP-IDF driver/spi_master.h (co-simulation only).
// Field names and flag values are copied from ESP-IDF
// components/esp_driver_spi/include/driver/spi_master.h; idf_cosim.c
// enforces the ESP32-S3 rules the v4 driver depends on (32-bit address
// register, no MOSI + MISO in one half-duplex transaction,
// max_transfer_sz, CS_KEEP_ACTIVE only with the bus acquired).
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "esp_err.h"
#include "freertos/FreeRTOS.h"
typedef enum { SPI1_HOST = 0, SPI2_HOST = 1, SPI3_HOST = 2 } spi_host_device_t;
#define SPI_DMA_CH_AUTO 3
#define SPICOMMON_BUSFLAG_MASTER (1u << 0)
#define SPICOMMON_BUSFLAG_QUAD   (1u << 6)
typedef struct {
    int mosi_io_num, miso_io_num, sclk_io_num, quadwp_io_num, quadhd_io_num;
    int data0_io_num, data1_io_num, data2_io_num, data3_io_num;
    int max_transfer_sz;
    uint32_t flags;
} spi_bus_config_t;
#define SPI_DEVICE_HALFDUPLEX (1u << 4)
#define SPI_DEVICE_NO_DUMMY   (1u << 6)
typedef struct {
    uint8_t command_bits, address_bits, dummy_bits, mode;
    int clock_speed_hz;
    int input_delay_ns;
    int spics_io_num;
    uint32_t flags;
    int queue_size;
} spi_device_interface_config_t;
#define SPI_TRANS_MODE_DIO         (1u << 0)
#define SPI_TRANS_MODE_QIO         (1u << 1)
#define SPI_TRANS_USE_RXDATA       (1u << 2)
#define SPI_TRANS_USE_TXDATA       (1u << 3)
#define SPI_TRANS_MULTILINE_ADDR   (1u << 4)
#define SPI_TRANS_VARIABLE_CMD     (1u << 5)
#define SPI_TRANS_VARIABLE_ADDR    (1u << 6)
#define SPI_TRANS_VARIABLE_DUMMY   (1u << 7)
#define SPI_TRANS_CS_KEEP_ACTIVE   (1u << 8)
#define SPI_TRANS_MULTILINE_CMD    (1u << 9)
typedef struct {
    uint32_t flags;
    uint16_t cmd;
    uint64_t addr;
    size_t length;
    size_t rxlength;
    void *user;
    const void *tx_buffer;
    void *rx_buffer;
} spi_transaction_t;
typedef struct {
    spi_transaction_t base;
    uint8_t command_bits, address_bits, dummy_bits;
} spi_transaction_ext_t;
typedef struct spi_device_t *spi_device_handle_t;
esp_err_t spi_bus_initialize(spi_host_device_t host, const spi_bus_config_t *cfg, int dma);
esp_err_t spi_bus_add_device(spi_host_device_t host, const spi_device_interface_config_t *cfg, spi_device_handle_t *out);
esp_err_t spi_bus_remove_device(spi_device_handle_t dev);
esp_err_t spi_device_transmit(spi_device_handle_t dev, spi_transaction_t *t);
esp_err_t spi_device_polling_transmit(spi_device_handle_t dev, spi_transaction_t *t);
esp_err_t spi_device_acquire_bus(spi_device_handle_t dev, uint32_t wait);
void spi_device_release_bus(spi_device_handle_t dev);
