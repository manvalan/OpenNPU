// SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
// SPDX-License-Identifier: MIT
// Source location: https://github.com/manvalan/OpenNPU
// Host stand-in for ESP-IDF esp_heap_caps.h (co-simulation only).
#pragma once
#include <stdlib.h>
#define MALLOC_CAP_DEFAULT 0
#define MALLOC_CAP_DMA     0
#define heap_caps_malloc(n, caps)    malloc(n)
#define heap_caps_calloc(c, n, caps) calloc(c, n)
