idf_component_register(
    SRCS "fpga_neural.c" "fpga_neural_v4.c" "fpga_neural_v4_bringup.c" "fpga_neural_v4_app.c"
         "fpga_neural_v4_config.c" "fpga_neural_v4_partition.c"
    INCLUDE_DIRS "include"
    REQUIRES driver esp_rom esp_partition
)
