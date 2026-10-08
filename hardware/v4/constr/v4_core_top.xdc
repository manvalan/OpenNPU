# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Source location: https://github.com/manvalan/OpenNPU
create_clock -period 5.000 -name clk [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports *]
# host pins are quasi-static (the host waits between commands): no IO timing
set_false_path -from [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_false_path -to   [get_ports -filter {DIRECTION == OUT}]
