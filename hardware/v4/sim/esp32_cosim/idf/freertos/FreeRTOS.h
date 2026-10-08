// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// Host stand-in for FreeRTOS.h (co-simulation only): 1 tick = 1 ms of
// simulated time.
#pragma once
#include <stdint.h>
typedef uint32_t TickType_t;
#define portTICK_PERIOD_MS 1
#define portMAX_DELAY      0xFFFFFFFFu
#define pdMS_TO_TICKS(ms)  ((TickType_t)(ms))
