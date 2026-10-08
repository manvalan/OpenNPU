# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Source location: https://github.com/manvalan/OpenNPU
# v4 board top -- same physical pins as v3 (docs/PHYSICAL_REALIZATION.md
# on v3-artix7, hardware/v3/constraints/n2_system_ddr3_top.xdc); the
# DDR3 pins come from the MIG IP's own constraints; the board clock is
# constrained here (MIG sys_clk_i / clk_ref_i are NO_BUFFER).
set_property BITSTREAM.CONFIG.PERSIST NO [current_design]
# bank 0 (configuration) at 3.3 V: CFGBVS pin tied to VCCO_0 on the board
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
# boot from the W25Q32JV, Master SPI x1 (Fast Read 0Bh, UG470): CCLK 33 MHz
# nominal, +50% FMCCKTOL -> <= 49.5 MHz (W25Q32JV Fast Read: 133 MHz),
# FPGA samples on the falling edge, compressed bitstream (shorter boot)
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# config flash on the dedicated Master SPI configuration pins (bank 14,
# VCCO 3.3 V), so the FPGA boots from it on its own (M[2:0] = 001):
# FCS_B L13 -> flash /CS, D00_MOSI K17 -> flash DI, D01_DIN K18 <- flash
# DO, CCLK E9 -> flash CLK (through STARTUPE2 after configuration).
# PERSIST NO: the three pins become user I/O once configuration is done.
set_property PACKAGE_PIN K17 [get_ports flash_mosi]
set_property PACKAGE_PIN K18 [get_ports flash_miso]
set_property PACKAGE_PIN L13 [get_ports flash_cs_n]
set_property IOSTANDARD LVCMOS33 [get_ports {flash_mosi flash_miso flash_cs_n}]
set_property PROHIBIT true [get_sites -of_objects [get_package_pins {L16 R16 V15}]]

# board clock: ONE 200 MHz LVDS oscillator on N5/P5 (bank 34, 1.5 V, CC
# pair). LVDS_25 is allowed as an input in a bank at another VCCO only
# without the internal termination (UG471): DIFF_TERM FALSE + an external
# 100 ohm resistor across N5/P5. IBUFDS -> BUFG = MIG clk_ref_i (200 MHz)
# and -> MMCM (x31/5/4) -> MIG sys_clk_i 310 MHz (rtl/v4_board_top.v).
# T14/T15 (former clk_ref) are free.
set_property PACKAGE_PIN N5 [get_ports sys_clk_p]
set_property PACKAGE_PIN P5 [get_ports sys_clk_n]
set_property IOSTANDARD LVDS_25 [get_ports {sys_clk_p sys_clk_n}]
set_property DIFF_TERM FALSE [get_ports {sys_clk_p sys_clk_n}]
create_clock -period 5.000 -name osc_200 [get_ports sys_clk_p]
# the 200 MHz domain (IDELAYCTRL reference, MIG temperature monitor) meets
# ui_clk only through the MIG's own synchronizers, as with the former
# separate clk_ref oscillator: asynchronous (now they are related through
# the MMCM, and the clock skew would make the 2-flop syncs fail hold)
set_clock_groups -asynchronous -group [get_clocks osc_200] -group [get_clocks -of_objects [get_nets ui_clk]]

# reset and done interrupt from/to the ESP32 (bank 15, 3.3 V). The
# management SPI (A15/B16/B17/A16) is gone since 2026-10-07: every
# command goes over the Quad-SPI port below; those four pins are free.
set_property PACKAGE_PIN G13 [get_ports sys_rst]
set_property PACKAGE_PIN D14 [get_ports data_ready_n]
set_property IOSTANDARD LVCMOS33 [get_ports {sys_rst data_ready_n}]

# asynchronous to every internal clock
set_false_path -from [get_ports sys_rst]
set_false_path -to   [get_ports data_ready_n]

# clock-domain crossings between ui_clk and the core MMCM clock go only
# through async_fifo.v (Gray pointers, ASYNC_REG) and 2/3-flop
# synchronizers: constrain the Gray buses to at most one destination
# period instead of cutting them completely
set_max_delay -datapath_only -from [get_clocks -of_objects [get_nets ui_clk]] -to [get_clocks -of_objects [get_nets core_clk]] 5.000
set_max_delay -datapath_only -from [get_clocks -of_objects [get_nets core_clk]] -to [get_clocks -of_objects [get_nets ui_clk]] 6.450

# fast Quad-SPI data port (qspi_data_port.v) -- bank 15, byte group T1,
# pins on the 40-pin board-to-board connector (QSCLK on a clock-capable pin)
set_property PACKAGE_PIN D15 [get_ports qsclk]
set_property PACKAGE_PIN C15 [get_ports qcs_n]
set_property PACKAGE_PIN A13 [get_ports {qio[0]}]
set_property PACKAGE_PIN A14 [get_ports {qio[1]}]
set_property PACKAGE_PIN B18 [get_ports {qio[2]}]
set_property PACKAGE_PIN A18 [get_ports {qio[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {qsclk qcs_n qio[*]}]
create_clock -period 12.500 -name qsclk [get_ports qsclk]
# QSPI front end <-> ui_clk: only through async_fifo.v (Gray pointers)
set_max_delay -datapath_only -from [get_clocks qsclk] -to [get_clocks -of_objects [get_nets ui_clk]] 6.450
set_max_delay -datapath_only -from [get_clocks -of_objects [get_nets ui_clk]] -to [get_clocks qsclk] 12.500
# ESP32-S3 SPI2 at 80 MHz, mode 0. Host -> FPGA: host launches on the
# falling edge, FPGA samples on the rising edge. FPGA -> host: the FPGA
# launches each nibble on the rising edge before the one the host samples
# it on (qspi_data_port.v), from IOB flops. Board + ESP32 budget 0..2 ns.
set_input_delay  -clock qsclk -clock_fall -max 2.0 [get_ports {qio[*] qcs_n}]
set_input_delay  -clock qsclk -clock_fall -min 0.0 [get_ports {qio[*] qcs_n}]
set_output_delay -clock qsclk -max 2.0 [get_ports {qio[*]}]
set_output_delay -clock qsclk -min 0.0 [get_ports {qio[*]}]
