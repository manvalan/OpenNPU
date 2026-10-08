// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// FPGA-Neural v4 -- bitstream from an ESP32 data partition (ESP32 only,
// not part of the host co-simulation). See include/fpga_neural_v4.h.
//
// partitions.csv:   fpga, data, 0x40, , 4M
// write the .bit:   parttool.py write_partition --partition-name fpga \
//                       --input v4_board_top_199.bit
#include "esp_log.h"
#include "esp_partition.h"
#include "fpga_neural_v4.h"

static const char *TAG = "fpga_v4_config";

esp_err_t fpga_v4_bitstream_from_partition(const char *label, const uint8_t **data, size_t *data_len)
{
    if (!label || !data || !data_len) return ESP_ERR_INVALID_ARG;
    const esp_partition_t *part = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, label);
    if (!part) { ESP_LOGE(TAG, "no data partition \"%s\"", label); return ESP_ERR_NOT_FOUND; }
    const void *map;
    esp_partition_mmap_handle_t mh;
    esp_err_t err = esp_partition_mmap(part, 0, part->size, ESP_PARTITION_MMAP_DATA, &map, &mh);
    if (err != ESP_OK) return err;
    err = fpga_v4_bitstream_payload(map, part->size, data, data_len);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "partition \"%s\" does not hold a .bit file", label);
        esp_partition_munmap(mh);
        return err;
    }
    ESP_LOGI(TAG, "bitstream in \"%s\": %u bytes", label, (unsigned)*data_len);
    return ESP_OK;
}
