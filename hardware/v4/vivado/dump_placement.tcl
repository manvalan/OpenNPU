# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# Writes the placement (cell -> SITE/BEL) of a routed checkpoint as a Tcl
# list, for impl_reuse_placement.tcl (placement reuse without the
# incremental-implementation license feature). Clock primitives, I/O
# buffers and the MIG clocking (infrastructure, IDELAYCTRL, clock input
# buffers) are left out: they are re-placed.
#   vivado -mode batch -source dump_placement.tcl -tclargs <routed.dcp> <out.tcl>
set_param general.maxThreads 1
open_checkpoint [lindex $argv 0]
set f [open [lindex $argv 1] w]
puts $f "set P \{"
set n 0
foreach c [get_cells -hier -filter {IS_PRIMITIVE && STATUS == PLACED && PRIMITIVE_GROUP != CLOCK && PRIMITIVE_GROUP != IO}] {
    if {[string match "*u_ddr3_infrastructure*" $c] || [string match "*u_iodelay_ctrl*" $c] || [string match "*clk_ibuf*" $c]} continue
    set bel [get_property BEL $c]
    set site [get_property LOC $c]
    if {$site eq "" || $bel eq ""} continue
    puts $f "\{$c\} \{$site/[lindex [split $bel .] end]\}"
    incr n
}
puts $f "\}"
close $f
puts "DUMPED $n cells"
