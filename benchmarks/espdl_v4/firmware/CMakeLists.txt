# FPGA-Neural v4 -- the same networks on the ESP32-S3 with ESP-DL (SIMD
# kernels, Espressif's own int8 quantization). See ../README.md.
cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(v4_espdl_bench)
