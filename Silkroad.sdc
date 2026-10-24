derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# ---------------------------------------------------------------------------
# No CPU multicycle constraints -- deliberately.
# ---------------------------------------------------------------------------
# rtl/cpu/maincpu.sv drives TG68KdotC_Kernel directly, gated by a real 16 MHz
# clock enable (clkena_in). The kernel is entirely rising-edge, so there are
# no half-cycle paths here to mis-constrain, and a genuine clock enable means
# the Fitter is already told the truth by the netlist.
#
# An earlier version of this file constrained {*TG68K:*|*} with
# set_multicycle_path -setup 2/4. That was actively dangerous: it swept the
# TG68K.vhd wrapper's FALLING-edge registers (as_e, rw_e, uds_e, lds_e,
# clkena_e, data_akt_e, cpuIPL, waitm, E) into the collection and granted
# half-cycle paths (~5.8 ns) up to ~46 ns. The Fitter routes them that slowly,
# the timing report stays clean, and the design fails only on silicon -- and
# two of those registers are waitm (the DTACK sample) and data_akt_e (which
# gates the DATA tri-state). See docs/LESSONS_LEARNED.md.
#
# A multicycle IS needed -- the kernel's register file measured ~19.6 ns in
# the Psikyo core, against an 18.5 ns clock at 54 MHz -- and it is safe to
# state, for two reasons:
#
#   1. The CPU path is TG68KdotC_Kernel only, which is entirely rising-edge
#      (verified: zero falling_edge occurrences). The TG68K.vhd wrapper and
#      its falling-edge registers are no longer instantiated, so there is no
#      half-cycle path left in the CPU for a multicycle to corrupt.
#   2. The relaxation is backed by RTL, not hope. rtl/cpu/maincpu.sv gates
#      the kernel with a real 16 MHz clock enable (8/27 of 54 MHz: ticks 3
#      or 4 clk_sys cycles apart), and its acc_ph settle counter guarantees nothing downstream
#      acts before the CPU's ~14 ns address path has settled: writes commit
#      at phase 1, BRAM reads capture at phase 2.
#
# Kernel -> kernel gets 3, the minimum enable gap (it was 4 at 85.9 MHz, where
# ticks were 5-6 apart; 4 here would be unsafe). Kernel -> anywhere gets 2,
# matching the settle discipline above.
set krn [get_registers {*TG68KdotC_Kernel:*|*}]
if {[get_collection_size $krn] > 0} {
    set_multicycle_path -setup -end 2 -from $krn -to [all_registers]
    set_multicycle_path -hold  -end 1 -from $krn -to [all_registers]

    set_multicycle_path -setup -end 3 -from $krn -to $krn
    set_multicycle_path -hold  -end 2 -from $krn -to $krn
} else {
    post_message -type critical_warning \
        "Silkroad.sdc: no TG68KdotC_Kernel registers matched -- CPU multicycle NOT applied"
}

# ---------------------------------------------------------------------------
# Video pixel-path multicycle: tilemap/sprite pixel data -> palette lookup.
# ---------------------------------------------------------------------------
# The remaining recurring clk_sys violations (~-0.9 ns worst) are pixel-data
# paths into the two palette BRAMs' port-B address registers. Two facts make
# a setup-2 relaxation safe here:
#
#   1. Sources are pixel-cadence: tilemap_line_engine's pixel_index /
#      pixel_color registers update ONLY under ce_pix (1-in-8; verified --
#      reset aside, no other branch writes them; pixel_valid is NOT in the
#      collection because blanking edges clear it at full rate).
#   2. The only consumer of the palette output (rgb -> arcade_video /
#      screen_rotate_two) samples at ce_pix cadence too, so an address that
#      settles 2 clk after the pixel tick instead of 1 is invisible: the
#      lookup result is stable 6 cycles before anything reads it.
#
# Deliberately -from restricted, never a blanket -to the palette BRAMs, so
# no full-rate path into them is relaxed by accident. sprite_line_buffer is
# not a source here: none of its paths failed in the Psikyo core, and
# granting slack a path does not need lets the Fitter route it slowly.
set vidsrc [get_registers {*|tilemap_line_engine:*|pixel_index[*] *|tilemap_line_engine:*|pixel_color[*]}]
set palbram [get_registers {*|dpram:u_palette|* *|dpram:u_palette_snap|*}]
if {[get_collection_size $vidsrc] > 0 && [get_collection_size $palbram] > 0} {
    set_multicycle_path -setup -end 2 -from $vidsrc -to $palbram
    set_multicycle_path -hold  -end 1 -from $vidsrc -to $palbram
} else {
    post_message -type critical_warning \
        "Silkroad.sdc: video pixel-path multicycle NOT applied (empty collection)"
}
