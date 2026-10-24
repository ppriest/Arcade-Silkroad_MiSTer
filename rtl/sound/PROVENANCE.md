# rtl/sound

`jt6295/`: see `jt6295/PROVENANCE.md`.

`oki_rom_bridge.sv` and `sample_cache.sv`: copied unchanged from Arcade-Fuuki_MiSTer
`rtl/sound/` at Fuuki commit `11df2b8` (the last commit touching them; `sample_cache.sv` is Fuuki's
port of the Psikyo core's `adpcma_sample_cache.sv`). GPL-3.0-or-later, as this core. Their bench,
`sim/oki_bridge_tb`, is Fuuki's `sim/oki_bridge_tb` retimed from 85.909 MHz to 54 MHz (slot
periods 216/270 clk, the latency sweep scaled with them).
