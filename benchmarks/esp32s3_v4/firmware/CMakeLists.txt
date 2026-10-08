# FPGA-Neural v4 -- the same network on the ESP32-S3 CPU, with the FPGA
# integer arithmetic: output compared bit for bit, time measured. See README.md.
cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(v4_s3_bench)
