# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Source location: https://github.com/manvalan/OpenNPU
# applied AFTER synthesis (cell names exist): host address/data registers
# feed the core memories 1 cycle before the delayed strobe, and the strobes
# themselves are held >= 2 cycles by the host protocol (v4_core_top.v)
set_multicycle_path -setup 2 -from [get_cells -hier -regexp {.*(stage_reg|addr_r_reg|sel_r_reg|chunk_r_reg|we_rr_reg|re_rr_reg).*}]
set_multicycle_path -hold 1  -from [get_cells -hier -regexp {.*(stage_reg|addr_r_reg|sel_r_reg|chunk_r_reg|we_rr_reg|re_rr_reg).*}]
