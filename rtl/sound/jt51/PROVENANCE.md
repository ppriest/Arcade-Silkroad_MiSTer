# jt51 (YM2151) provenance

jotego's JT51, copied from Arcade-Vamphalf_MiSTer `rtl/sound/jt51/` (`hdl/*.v` and `LICENSE`) at
Vamphalf commit `ec45cfb`. Vamphalf took it from the `modules/jt51` checkout of jtcores at
`985a573dcfc1ff135553a39f7eae21d18ba57cbe`, `hdl/` only, without `hdl/filter/` (unused: the core
takes the chip's own 16-bit output). GPL-3.0. Unchanged.

Instantiated by `rtl/sound/silkroad_sound.sv`, which has this board's chip set (YM2151 at
3.579545 MHz and two M6295, one banked).
