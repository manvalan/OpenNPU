# ESPDL_MODEL: the .espdl file (ESP-PPQ output), V4_NETBIN: the v4 net.bin
# of the same network (its INT8 input image and the FPGA's output);
# set by ../run_espdl.sh. Both are linked into flash rodata, 16-byte aligned
# (ESP-DL requirement) by a generated .S file.
if(NOT DEFINED ESPDL_MODEL)
    set(ESPDL_MODEL "${CMAKE_CURRENT_LIST_DIR}/../../models/bench_small/model.espdl")
endif()
if(NOT DEFINED V4_NETBIN)
    set(V4_NETBIN "${CMAKE_CURRENT_LIST_DIR}/../../../esp32s3_v4/nets/bench_small/net.bin")
endif()
set(blob_s "${CMAKE_BINARY_DIR}/v4_blobs.S")
file(WRITE "${blob_s}"
"    .section .rodata.v4_blobs, \"a\"
    .global espdl_model_start
    .global netbin_start
    .global netbin_end
    .balign 16
espdl_model_start:
    .incbin \"${ESPDL_MODEL}\"
    .balign 16
netbin_start:
    .incbin \"${V4_NETBIN}\"
netbin_end:
")
idf_component_register(SRCS "main.cpp" "${blob_s}"
                       INCLUDE_DIRS "."
                       REQUIRES esp_timer esp_psram)
set_property(SOURCE "${blob_s}" APPEND PROPERTY OBJECT_DEPENDS "${ESPDL_MODEL}" "${V4_NETBIN}")
