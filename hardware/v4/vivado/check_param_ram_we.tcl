# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
# per-chunk write-enable check: every RAM of chunk k of a parameter memory
# must have its WE driven (through at most 3 registers) by the decode
# register of chunk k (we_dww_reg[k] / we_dwq_reg[k] / we_pwq_reg[k] / we_w_reg[k])
proc chk2 {tag} {
  set bad 0; set tot 0
  foreach {g w} {G_DWW.GEN_DWW we_dww GEN_DWQ we_dwq GEN_PWQ we_pwq GEN_WC we_w} {
    foreach r [get_cells -hier -quiet -filter "NAME =~ *${g}\[*\]* && IS_PRIMITIVE && REF_NAME =~ RAM*"] {
      if {![regexp "${g}\\\[(\[0-9\]+)\\\]" $r -> k]} continue
      set p [get_pins -quiet $r/WE]; if {$p eq ""} { set p [get_pins -quiet $r/WEBWE[0]] }
      if {$p eq ""} continue
      incr tot
      set ok 0; set pin $p
      for {set i 0} {$i < 4} {incr i} {
        set drv [get_cells -quiet -of [get_pins -quiet -leaf -filter {DIRECTION==OUT} -of [get_nets -of $pin]]]
        if {$drv eq ""} break
        if {[string first "${w}_reg\[${k}\]" $drv] >= 0} { set ok 1; break }
        if {![string match FD* [get_property REF_NAME $drv]]} { break }
        set pin [get_pins $drv/D]
      }
      if {!$ok} { incr bad; if {$bad <= 5} { puts "CHK2 $tag BAD $r k=$k WE-chain ends at $drv" } }
    }
  }
  # every chunk must have its own RAMs (a merge leaves chunks without any)
  foreach {g nk} {G_DWW.GEN_DWW 9 GEN_DWQ 5 GEN_PWQ 5 GEN_WC 16} {
    for {set k 0} {$k < $nk} {incr k} {
      if {[llength [get_cells -hier -quiet -filter "NAME =~ *${g}\[$k\]* && IS_PRIMITIVE && REF_NAME =~ RAM*"]] == 0} { incr bad; puts "CHK2 $tag MISSING $g\[$k\]: no RAM of its own" }
    }
  }
  puts "CHK2 $tag rams $tot bad $bad"
}
