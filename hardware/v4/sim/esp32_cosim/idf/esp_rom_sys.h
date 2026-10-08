// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// Host stand-in for ESP-IDF esp_rom_sys.h (co-simulation only).
#pragma once
#include <stdint.h>
void ets_delay_us(uint32_t us);
static inline void esp_rom_delay_us(uint32_t us) { ets_delay_us(us); }
