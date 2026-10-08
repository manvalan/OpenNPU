# FPGA-Neural v4 first-power-on test app (ESP32-S3). See README.md.
cmake_minimum_required(VERSION 3.16)
set(EXTRA_COMPONENT_DIRS ../components)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(v4_bringup)
