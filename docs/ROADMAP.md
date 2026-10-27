# Unico SR2001A (The Legend of Silkroad) — MiSTer Core Roadmap

**Approved, including the 48 MHz clock and the 8 MHz pixel clock assumption. A phase whose scope
changes goes back for approval.**

## Context

Goal: a DE10-nano MiSTer core for the Unico SR2001A board, emulated by MAME's
`src/mame/unico/silkroad.cpp` and the standard devices it instantiates — a Quartus 17.0.2
SystemVerilog project producing one `.rbf` and a `.mra` per set.

Every chip on the board already runs in a sibling core. The 68EC020 at 16 MHz from a 32 MHz
crystal is Arcade-DreamWorld_MiSTer's CPU (TG68K.C, via Psikyo), with the same 0xFE0000 work RAM
and level-4 vblank interrupt. The YM2151 + two M6295 with a banked first OKI is
Arcade-Vamphalf_MiSTer's `vh_ymoki.sv`, which already serves `aoh` (Age of Heroes, this game's
Unico sequel) with jt51 and jt6295. So the core starts from DreamWorld's tree, as DreamWorld
started from Psikyo's. What is new work:

1. **Video**: three 64 x 64 tilemaps of 16 x 16 tiles at 6 bpp, and a sprite format of
   horizontal strips (1-16 tiles wide, one tall, flip X, one priority bit) with first-entry-wins
   mixing. Written into the inherited per-scanline engines.
2. **6 bpp graphics fetch**: a tile row is 12 bytes from three ROM thirds 8 MB apart. The load-time
   layout and the per-line fetch budget are a Phase 0 measurement.
3. **Video timing**: not in the driver. A choice, made in Phase 0 (Clocks).

Everything else is adapting inherited RTL with verification against MAME. Hardware facts with
sources are in [`HARDWARE_NOTES.md`](HARDWARE_NOTES.md).

Cross-cutting findings from the previous cores are in **[`LESSONS_LEARNED.md`](LESSONS_LEARNED.md)**.
Working practice built on them is in **[`WORKFLOW.md`](WORKFLOW.md)**. The entries that already
bind decisions here are collected under "Pitfalls that already bind decisions here".

## Progress

**Phase 3's RTL and `.mra` work is done (`3982a3c`); Phases 2 and 3 both wait on the board, which
another session was using: their hardware checks are the checklist under Phase 3.** Phases 0 and
1 are done (below).

- Phase 3 (`3982a3c`): flip (2 scenes identical to the model turned 180 degrees in
  `sim/frame_tb`), test and service inputs, button names from MAME play, DIP bits written as
  Main_MiSTer's first,last range (they were a list, which loses half of a 3-bit switch), a layer 2
  debug switch, README. Both `.mra` files pass `validate_mra.py`.

- `scripts/render_model.py` (`9c0296e`): 26 of 26 scenes, 13 per set, attract and play,
  pixel-identical to MAME (`scripts/model_sweep.py`).
- RTL (`6a1a0c8` and after): `sim/frame_tb` loads each capture through the CPU ports and records
  two frames through the real SDRAM path. 13 of 13 silkroad scenes identical to the model in both
  frames, no line cut short.
- Fetch budget, measured by the RTL's counters over the 13 scenes (a line is 3,072 clk):

  | | worst render | scene |
  |---|---|---|
  | tilemaps | 2,734 clk | sw4800 (194 fetches on one line: 104 tile, 90 sprite) |
  | sprites | 2,207 clk | sw600 (112 sprite fetches) |

  Both engines share the SDRAM chip, so a line's time follows its total fetches. The heaviest a
  line can be is 150 tile fetches (25 distinct tiles on each layer) and 112 sprite fetches (the
  56-row worst of `docs/sprite_load_mame.txt`), 262; at sw4800's rate (about 14 clk a fetch)
  that is beyond 3,072. A line that overruns loses its last tiles or sprites for that line, and
  is counted (debug overlay rows 217 and 219).
  Decided by the user: keep 48 MHz and measure overruns on hardware with these counters; revisit
  only if play cuts a line short.

- Hardware, `9cfac89` as `Silkroad_stp` (`Silkroad_30000001.rbf`; timing +6.041 ns, 20,913
  ALMs, 391 M10K), launched 22:28:23 from `_Arcade/_Silkroad/_dev`. ISSP C at 22:37:10,
  `Silkroad|Silkroad|silkroad|`: 31,209 interrupt acknowledges, one a frame at 59.64 Hz less
  the load; palette writes, VRAM writes and ROM reads each saturated at 65,535; fetching at
  0x00A5C6. The second reading, 30 s later, came from KonamiHornet's gradius4: another session
  had taken the board. The picture is DreamWorld's engines on region A
  (`debug/hw/p1/silkroad_t25.png`, 25 s after launch), as expected before Phase 2. The first
  launch was black: `silkroad.zip` was not in `/media/fat/games/mame`; copied there.
- `9cfac89`, `sim/boot_tb` against MAME's first 2,000,000 accesses (seven vblank interrupts):
  74,256 of 74,256 writes match in order, 14 runs of up to 12 writes in another bus order
  with the same bytes written; 14,242 of 14,242 I/O reads; every ROM word MAME read in the
  window. I/O values are MAME's, replayed; the interrupt is raised where MAME took it.
- `scripts/build_mra.py`: silkroad and silkroada give the same 27 MB image; each `.mra` re-reads
  byte for byte. `validate_mra.py` fails both on the generic button names only (Open items).

- Quartus, `build_staged.py --rev Silkroad`, `62f964f`, default seed: timing met on every clock,
  worst `clk_sys` setup +5.706 ns, hold +0.252 ns; PLL VCO 480 MHz, both outputs 48.0 MHz,
  SDRAM_CLK 306 degrees; 20,183 ALMs (48%), 379 of 553 M10K (69%), 64 DSP. Not deployed: the
  decode is still DreamWorld's.

- `62f964f`: the MCU stripped, 48 MHz, 512 x 262 at 8 MHz, jt51 vendored. ModelSim: 26 inherited
  benches pass (listed in the commit). Not run: `crt_chain_tb` (did not finish in 300 s in
  DreamWorld), `frame_tb` and the OKI phrase and trace benches (DreamWorld captures).
- `baedab3`: DreamWorld `233d1f2`'s `rtl/`, `sim/` and Quartus project imported with renames only.
- `scripts/gfx_layout_check.py`: the core's two-region layout decodes 1,049,344 pixels of 4099 tiles
  to MAME's pens, 0 differ; a swapped plane pair gives 22,694 of 66,304 wrong.
- `a4fc5d9`: `docs/write_timing_mame.txt`, `docs/sprite_load_mame.txt`, `docs/boot_trace_mame.txt`.
- `-verifyroms silkroad silkroada`: both good in the local ROM path.

## Game scope

| Set | Parent | Config | maincpu | gfx | oki1 | oki2 | Rot | MAME |
|---|---|---|---|---|---|---|---|---|
| silkroad | - | silkroad | 2 MB | 24 MB (12 x 2 MB) | 512 KB | 256 KB | 0 | good |
| silkroada | silkroad | silkroad | 2 MB | 24 MB (3 x 4 MB + 6 x 2 MB) | 512 KB | 256 KB | 0 | good |

### Scope decision

- **In scope:** both sets — one board, one memory map. silkroada's three 4 MB ROMs are byte-identical
  to silkroad's pairs (HARDWARE_NOTES, Sets), so both `.mra` files build the same 26.75 MB image.
- **Out of scope:** none in this driver. Age of Heroes runs on different hardware (Hyperstone,
  `vamphalf.cpp`) and belongs to the Vamphalf core.
- **First-target set:** silkroad. **Second:** silkroada, which only checks the `.mra`.

## Hardware reality (from the driver, not assumption)

Every value cites a silkroad.cpp line; details in [`HARDWARE_NOTES.md`](HARDWARE_NOTES.md).

### Chips

68EC020 16 MHz (445); YM2151 3.579545 MHz (464); M6295 1 MHz and 2 MHz, pin 7 high, both "not
verified" (466, 471); video in two Actel A40MX04 (header 30).

### Clocks

Board: 32 MHz XTAL (CPU /2, OKIs /32 and /16) and 3.579545 MHz XTAL (YM2151). The pixel clock is
not in the driver: 60 Hz, a 512 x 256 bitmap and a 380 x 224 visible area (451-454), no `set_raw`.

**Proposed pixel clock: 32 MHz / 4 = 8 MHz, H total 512, V total 262** — 15.625 kHz, 59.64 Hz
against MAME's 60 Hz (-0.6%). A choice, not a measurement; it goes in `docs/HACKS.md` until a PCB
measurement replaces it (Open items). 512 is MAME's bitmap width; 262 is the nearest line count
to 60 Hz that is usual for a 15.6 kHz board.

**Proposed `clk_sys`: 48 MHz, SDRAM on the same clock**, the default (clocks.md). Candidates:

| clk_sys | pixel 8 MHz | CPU 16 MHz | Note |
|---|---|---|---|
| 48 MHz | 1 in 6 | 1 in 3 | chosen: the default, every 32 MHz-derived clock exact |
| 64 MHz | 1 in 8 | 1 in 4 | only for a measured fetch shortfall |

| Clock | From 48 MHz | Exact |
|---|---|---|
| pixel 8 MHz | `ce_pix` 1 in 6 | yes |
| 68EC020 16 MHz | 1 in 3 | yes |
| M6295 #1 1 MHz | 1 in 48 | yes |
| M6295 #2 2 MHz | 1 in 24 | yes |
| YM2151 3.579545 MHz | phase accumulator, 715909/9600000 | yes, rational |
| SDRAM controller | `clk_sdram`, 96 MHz, in phase with `clk_sys` (decided below) | - |
| SDRAM_CLK | 96 MHz, 3.125 ns ahead of `clk_sdram` | - |

One line is 3072 clk. DreamWorld runs at 54 MHz because its 27 MHz video crystal forced it; this
board has no such crystal. CPU catch-up on SDRAM stalls is measured in Phase 1, not assumed.

**The SDRAM controller at 96 MHz.** Decided by the user after the measured shortfall (0.004
tilemap lines cut a frame with the instruction cache; Open items): `sdram.sv` alone runs on
`clk_sdram`, twice `clk_sys` from the same PLL; its clients, the `sdram_phy` wrappers and every
other module stay on `clk_sys`. A granule takes 11 controller cycles, 115 ns, against 229 ns
at 48 MHz.

### Interrupts

Level 4 autovectored at vblank, `irq4_line_hold` (447); the program's vector is 0x12C, every
other level an `rte` (header 9-19). Already what DreamWorld's `maincpu.sv` does.

### Memory map

As HARDWARE_NOTES. Differences from DreamWorld's decode: sprite RAM 0x40C000-0x40CFFF, palette in
the upper 16 bits of each word (0x600000-0x603FFF), three VRAMs to 0x80BFFF, inputs and DIPs at
0xC00000/4, OKI 1 at 0xC00025, YM2151 at 0xC00029/0xC0002D, OKI 2 at 0xC00031, bank 0xC00034,
coin 0xC00039, video registers 0xC0010C-0xC00123. No MCU.

### Video

Three 64 x 64 tilemaps of 16 x 16 tiles, 6 bpp, pen 0 transparent, flip X per tile, 32 colours,
one scroll pair each from the register words (266-273). 512 sprites, each a strip of 1-16 tiles,
flip X, 64 colours, 17-bit tile, one priority bit: 0 above layer 0, 1 above layers 0-1, always
below layer 2; the lowest-numbered sprite wins over later ones (HARDWARE_NOTES, Mixing). Background
pen 0x7C0. One 4096-entry xRGB 555 palette. No flip screen.

Latency: MAME draws sprites from live sprite RAM at `screen_update`, and the driver says "Sprites
probably need to be delayed" (186). The video-write sweep decides the snapshot point.

### Sound

YM2151 stereo at 1.0; two M6295 to both sides at 0.45 (464-473). OKI 1: 0x00000-0x1FFFF fixed,
0x20000-0x3FFFF banked over ROM 0x20000-0x7FFFF, bank 3 ignored (295-299, 439).

### Protection

None in the driver.

### Per-game configuration

None: one image, one configuration. The `.mra` files differ only in ROM file names.

## Component reuse map

| block | plan | source |
|---|---|---|
| whole tree | Fork | Arcade-DreamWorld_MiSTer `233d1f2`: framework glue, SDRAM backend, DDR3 load, hiscore, CRT Adjust, rotation, OSD (GPL-3.0-or-later) |
| 68EC020 | Keep | TG68K.C in DreamWorld `rtl/cpu/tg68k/` (Psikyo's vendoring, `PROVENANCE.md`), LGPL-3.0 |
| main bus | Adapt | DreamWorld `rtl/cpu/maincpu.sv`: new decode, MCU removed |
| YM2151 + 2 x M6295 | Write | `rtl/sound/silkroad_sound.sv`: YM2151 3.579545 MHz, OKI 1 at 1 MHz banked, OKI 2 at 2 MHz, with `jt51` (jtcores `985a573`) and `jt6295` (`7d76b0b`), GPL-3.0; `sample_cache.sv` / `oki_rom_bridge.sv` from DreamWorld |
| tilemaps | Adapt | DreamWorld `tilemap_line_engine.sv`: three layers, 6 bpp, 12-byte rows |
| sprites | Adapt | DreamWorld `sprite_line_list.sv` / `sprite_line_engine.sv`: strip format, first-wins line buffer, priority bit |
| compositor | Adapt | DreamWorld `compositor.sv`: four inputs, sprite priority against layers 1 and 2, 4096-entry palette |
| video timing | Adapt | DreamWorld `video_timing.sv`: 512 x 262, 380 x 224 active |
| SDRAM | Keep, re-map | DreamWorld `rtl/memory/` |
| DIP/keys | Keep | `rtl/mame_keys.sv` |

## On-chip RAM budget

Estimated from DreamWorld's fit (386 of 553 M10K at `42baf8e`); measured after the first fit.

| Block | Size | M10K, estimate |
|---|---|---|
| work RAM | 128 KB | 128, as DreamWorld |
| VRAM x3 | 16 KB each | ~48 (DreamWorld: 2 x 16) |
| sprite RAM + snapshot | 4 KB + 4 KB | ~8 (DreamWorld's 8 KB double buffer: 32) |
| palette | 4096 x 16 | 8 |
| sprite line buffers | 2 x 512 x (12-bit colour + priority + taken) | ~2 |

DreamWorld's MCU ROM, MCU RAM and second video-register copy go. The one to watch is work RAM,
as in DreamWorld: hiscore keeps sharing its port.

## Memory plan

SDRAM, 32 MB, at `clk_sys`. Proposed layout (the RTL's localparams become the source of truth):

| Region | Size | Client |
|---|---|---|
| gfx, rearranged | 24 MB | tiles and sprites |
| maincpu | 2 MB | CPU, narrow bridge |
| oki1 | 512 KB | sample cache |
| oki2 | 256 KB | sample cache |

26.75 MB of 32 MB. DDR3 only at load time.

**Graphics layout.** MAME's region has a tile row in three 32-bit pieces 8 MB apart. At load the
core rearranges it so a row is one fetch. Options, chosen in Phase 0 against the controller's
burst lengths: 12 contiguous bytes (stride x 12 by shift-and-add), or planes 0-3 as 8 bytes in a
16 MB region plus planes 4-5 as 4 bytes in an 8 MB region (two bursts, power-of-two strides).

**Fetch budget** (an estimate, to be replaced by the Phase 0 measurement): 3072 clk a line. The
three tilemaps need up to 3 x 25 = 75 tile rows a line. DreamWorld measured about 11 clk for one
burst-4 read on its own port; at about 15 clk for a 12-byte row, the tilemaps take about 1100 clk
on one port. Sprites get their own port, as in DreamWorld, with about 3000 clk for a line's sprite
tile rows. A line of sprite strips can ask for up to 16 rows per entry, so the worst real line
comes from MAME captures (`docs/sprite_load_mame.txt`), with X tested before fetching as in
DreamWorld. If the measured line does not fit at 48 MHz, the numbers come to the user before any
change of clock or shape.

## Design decisions

**Follow MAME, including where MAME is wrong, and write down every place that is.** There is no
PCB here. MAME is the accuracy target and its acknowledged guesses are inherited deliberately. Each
goes in `docs/MAME_KLUDGES.md` when it is implemented, with what MAME does, what the hardware is
suspected to do, and what would settle it. The first two: the unknown video timing, and sprites
drawn from live RAM.

**Where a vendored module and MAME disagree, record it and keep the module.**

**Every approximation of this core's own goes in `docs/HACKS.md`** in the commit it lands, with
what would make it correct.

**Transcribe the reference literally first, then look for the chip.**

**One `.rbf` for both sets.**

**Two Quartus revisions, `Silkroad_stp` and `Silkroad`,** differing only by a `DEBUG_ISSP` macro.
See [`WORKFLOW.md`](WORKFLOW.md).

**Licence: GPL-3.0-or-later.** jt51 and jt6295 are GPL-3.0, TG68K.C LGPL-3.0. `sys/` is never
edited.

**Per-scanline rendering from buffered sprite RAM.** Inherited from DreamWorld and Psikyo. The
snapshot point comes from the video-write sweep; nothing in the driver shows a frame buffer.

**No multiplies, no divides, in 2D pipelines.** The 12-byte stride, if chosen, is (n << 3) + (n << 2).

**Fork DreamWorld rather than start from the template's RTL.** Its CPU, memory backend and feature
set are on hardware and in a release; the inherited engines are adapted against MAME-derived
references and their existing benches.

**Sprite line buffer: first writer wins.** A per-pixel taken bit, set by every opaque sprite pixel
whether or not it shows over the layers, matching MAME's pixel op. An engine that runs out of time
drops the highest-numbered entries, which are the ones underneath.

**Flip screen through a fake DIP.** The game has none; the OSD option and the fake DIP drive one
path in the video logic, verified against the unflipped frame rotated 180 degrees.

## Pitfalls that already bind decisions here

| Entry | What it binds here |
|---|---|
| "Read both halves of a mechanism before changing it: the draw loop AND the pixel op" | `prio_transpen` sets priority 31 on every opaque sprite pixel: first entry wins, hidden pixels still block |
| "Sprite lists, line buffers and snapshots" | the snapshot point against live-RAM drawing in MAME |
| "[Seta] In a `gfx_layout`, the first plane listed is the MSB of the pen" | the 6-plane order across the three thirds, and `ROMREGION_INVERT` |
| "[Seta] A `gfx_layout` transcription can be checked without any ROM" | the rearranged layout, before any ROM is involved |
| "[HyperNG64] Check a large set's regions for byte-identical copies before sizing memory" | silkroada's ROMs: checked, same image |
| "Memory transport: req/valid contracts, latency, byte order" | the third tilemap client and the 12-byte fetch |
| "[DreamWorld] MAME's PORT_DIPUNUSED with IP_ACTIVE_LOW defaults the bit to 1" | SWA:3-5, SWB:1, SWB:3 |
| "Prove the interleave against MAME's disassembly offline, before building" | `ROM_LOAD32_WORD_SWAP` of rom02/rom03 |

## Phased roadmap

**Phase 0 — Measurements and the fork. The gate.**

Exit criteria:

1. **Video-write sweep in play and attract**, 1800 frames or more, both from a coin-up and Start
   (`--coin`): sprite RAM, the three VRAMs, the video registers, palette. Into
   `docs/write_timing_mame.txt`. — Met: 1800 attract and 2400 play frames. Sprite RAM and the
   scroll registers are written only on MAME lines 240-250, inside vblank; tile VRAM and part of
   the palette during the visible area.
2. **Sprite load per line from MAME captures**, with X tested, into `docs/sprite_load_mame.txt`,
   and the tilemap fetch count, against the 3072-clk line. — Met: worst line 56 sprite tile rows
   (attract, and 9000 frames of play); with 75 tilemap rows, 131 rows of 12 bytes a line.
3. **Graphics layout chosen**: the load-time rearrangement, checked bit-exact against MAME's
   decoded tiles (`gfx_layout` check, then against a ROM). — Met: region A (16 MB) holds thirds 0
   and 1 interleaved by 32 bits, one 8-byte granule a row; region B (8 MB) is third 2, 4 bytes a
   row. `scripts/gfx_layout_check.py`: 0 of 1,049,344 pixels differ.
4. **Video timing decided** (8 MHz, 512 x 262 proposed) and logged in `docs/HACKS.md`, unless a
   PCB measurement turns up. — Met by decision: `docs/HACKS.md`, `docs/MAME_KLUDGES.md`.
5. **The fork**: DreamWorld's tree imported unchanged apart from renames, then the DreamWorld-only
   hardware removed; its benches that still apply pass. jt51 vendored from Vamphalf with
   `PROVENANCE.md`. — Met for the MCU (`62f964f`, 26 benches pass) and jt51. The spritelut and
   row scroll are inside `sprite_line_engine` and `vreg_decode`, which Phases 1 and 2 replace for
   silkroad's formats; they go with them rather than being edited twice. jt51's copied `hdl/`
   has no benches; Phase 4's MAME-trace bench is its first test.
6. **MAME boot trace of silkroad** into `docs/boot_trace_mame.txt`. — Met.
7. **Clock plan approved and the PLL regenerated at 48 MHz**; timing met on the stripped tree.
   — Met: `62f964f`, worst `clk_sys` setup +5.706 ns (Progress).

**Phase 1 — CPU, memory map, SDRAM layout.**

The new decode (inputs, DIPs with MAME's defaults, sound stubs, coin counters, video registers),
the SDRAM map and the graphics rearrangement in the loader, the `.mra` generator for both sets.
Exit: silkroad boots in simulation with a bus trace matching MAME's from reset through the first
frames of attract; on hardware, the CPU runs the attract loop (ISSP interrupt and VRAM write
counts). — Met. Simulation: seven frames from reset (Progress); attract itself is beyond what
the bench reaches in reasonable time (19 minutes for those seven). Hardware: the interrupt count
after 527 s is one a frame and the VRAM writes saturate; a second reading for a rate was taken
by another session's core.

**Phase 2 — Video against a software model.**

`render_model.py` from silkroad.cpp checked pixel-exact against MAME frames, then in RTL: timing
380 x 224, three 6 bpp tilemaps, the strip sprites with the first-wins buffer and priority bit,
the compositor and palette. The sprite snapshot moves from vblank start (DreamWorld's copy point,
which would show sprites a frame behind the scroll) to after the game's last sprite write, MAME
line 250 (`docs/write_timing_mame.txt`). Exit: captured scenes (attract and play) pixel-identical in
simulation, then matched on hardware with `hw.py --native` screenshots.

**Phase 3 — Hardware: the standard feature set.**

Inputs with MAME's keys, DIPs, Pause, CRT Adjust (and v-size if BRAM allows), hiscore, fast DDR3
loading, HDMI scaling and crop, rotation, flip screen by the fake DIP, audio mix, the OSD hiding
what does not apply. Exit: both sets boot and play on a DE10-nano, silent, every feature checked.

Hardware checklist, for Phases 2 and 3, `3982a3c` as `Silkroad_stp` (`Silkroad_30000003.rbf`),
launched 02:27:57. Evidence in `debug/hw/p2/`; frame matches by `scripts/hw_vs_mame.py`:

1. Native screenshots matched to MAME frames. — Met for attract: `a0`-`a5` (one every 20 s):
   3 of 6 identical (frames 702, 1931, 5619), the others 9, 257 and 1,233 pixels off, all on the
   flashing "Insert coin" text and the animated portrait icons, which run on their own phase.
   Play (`p0`-`p4`): coin, Start and Button 1 from the keyboard select a character and start a
   fight; not matched to MAME frames (the inputs are not MAME's).
2. Lines cut short in play. — Met at 96 MHz (below). `448aa07` (`Silkroad_30000004.rbf`), launched 02:55:10,
   two minutes of attract then a game with Attack and Jump pressed; ISSP V at 02:59:23,
   `Silkroad|Silkroad|silkroad|`: 15,217 frames, tilemap lines cut short 12,766, sprite lines 85,
   worst render 3,071 clk on both engines (the counters run from the bitstream load, so the count
   includes the ROM load's frames, when the engines are held in reset and cut nothing). The frame
   bench never cut a line because its CPU is paused: on the board the 68020's program fetches
   share the SDRAM chip with both engines. A cut loses the end of the line's layer 2 first (it
   renders last); no screenshot shows it (`v_end.png`), layer 2 being mostly transparent.
   With the 68020's instruction cache (`rom_cache.sv`), `760bd1d` (`Silkroad_30000005.rbf`),
   launched 12:33:03, two minutes of attract and a game with inputs to 12:37:10, then left
   running untouched; ISSP V at 13:09:09: 129,212 frames, tilemap lines cut 487, sprite lines
   382, worst render 3,071 clk on both. Tilemap cuts fall from 0.84 to 0.004 a frame; not zero,
   and which scenes still cut is not known (the counters do not say when).
   With the SDRAM controller at 96 MHz, `bf5d7a7` (`Silkroad_30000006.rbf`), launched 14:23:52,
   attract, then two credits with inputs to 14:29:25 (`debug/hw96/a0`-`a4`, `p0`-`p5`), then
   left running; ISSP V at 14:48:40: 88,443 frames, 0 tilemap and 0 sprite lines cut, worst
   render 1,648 clk (tilemaps) and 2,152 (sprites) of 3,072.
3. Flip. — Met through the fake DIP: an `.mra` with the flip bit set, screenshots turned back
   180 degrees, `fl0r`/`fl1r` identical to MAME frames 1205 and 2205, `fl2r` 11 pixels off on the
   blinking text. The OSD option not checked: the OSD does not appear in screenshots, and a blind
   key sequence did not reach it (`flip0`/`flip1` identical).
4. DIPs. — Defaults met: the game's own Dip Switches page (`dips0`) shows Life 2, Special Effect
   On, Difficulty 4, Free Play Off, Demo Sound On, Coin Box 1, 1 Coin 1 Credit. Changing them not
   checked (the OSD again).
5. Test switch. — Met: F2 enters Test Mode (`test0`). Service coins not checked.
6. Pause. — Met: two screenshots 6 s apart while paused differ in 0 pixels, 1,493 after
   unpausing (`pause0`-`pause2`). Hiscore, CRT Adjust, scaling, direct video: not checked (need
   the OSD or a CRT).
7. silkroada. — Met: `alt0`/`alt1` identical to MAME frames 1182 and 2290.

**Phase 4 — Sound.**

`rtl/sound/silkroad_sound.sv` at 48 MHz: YM2151 3.579545 MHz, OKI 1 at 1 MHz banked from
0xC00034, OKI 2 at 2 MHz, MAME's mix (1.0 / 0.45). Exit: register-write traces captured from MAME
reproduce the audio in a bench against MAME's output, and it is judged by ear on the board.

**Phase 5 — Accuracy and release.**

Both `.mra` files, README, `docs/HACKS.md` and `docs/MAME_KLUDGES.md` current, the release per
`docs/RELEASE_PROCESS.md`, floorplan and database update.

**Phase 6 — Savestates, state dumps and cheats.** Optional. RTL written for it from Phase 1:
reachable RAM ports, `docs/STATE.md` current. DreamWorld's state work, if any, comes with the fork.

## Verification strategy

- **MAME is a reference generator, driven from scripts.** Boot traces, VRAM and register dumps at
  known frames, palette dumps, register-write logs. WORKFLOW §9 applies.
- **The software model comes before the RTL.** The model against MAME first, the RTL against the
  model.
- **Layouts are verified before ROMs are involved**: the 6 bpp layout and its rearrangement get the
  "every bit of a tile exactly once" check.
- **`.mra` files are generated, not written**, re-read against an image built from `ROM_START`,
  and gated on an XML check before deploy.
- **Worst cases are measured in the RTL**: saturating counters for sprite rows dropped per line.

## Repository setup

Seeded from **MiSTer-devel/Template_MiSTer**, `Template.*` renamed to `Silkroad.*` and split into
the `Silkroad_stp` and `Silkroad` revisions; the Quartus 13 project dropped. Quartus **17.0.2**.
The DreamWorld fork replaces the template's RTL in Phase 0; `sys/` stays the template's.

## Open items

**The pixel clock and line counts.** Not in the driver. Assumed 8 MHz, 512 x 262. Closed by a PCB
measurement (H and V sync frequencies) or a reliable recording's frame rate.

**The button names.** MAME has Button 1-3; the `.mra` needs the game's names. A web search found no
manual or flyer giving them. A MAME run pressing each button alone met the player-select screen
and the intro, where any button acts. Phase 3 names them from a scripted fight, unless the
manual, a flyer or the user gives them first.

**The per-line fetch budget on hardware.** Measured: 0.84 tilemap lines cut a frame with the CPU
running, 0.004 with the 68020's instruction cache (487 tilemap and 382 sprite lines in 129,212
frames; Phase 3 checklist, item 2). Decided by the user: the SDRAM controller at 96 MHz, twice
`clk_sys` (Clocks). Remeasured: 0 lines cut in 88,443 frames, worst render 2,152 of 3,072 clk
(checklist, item 2). Closed.

**Sprite latency.** MAME uses live sprite RAM; its own comment suspects a delay. The sweep says
when the game writes; matching against MAME stays the target, with any delay an OSD A/B.

**Bit 7 of the system inputs (`IPT_CUSTOM`).** Stephh's notes say it freezes input reads. What MAME
returns for it is checked in the boot trace and reproduced.

**`regs[3]`, `regs[4]` and sprite attribute bit 13.** `scripts/bit13_scan.py` (MAME 0.289, 9,000
frames of attract and 9,000 of play): `regs[3]` and `regs[4]` (0xC00118-0xC0011F) are never
written, so they are not the game's. Bit 13 is set on visible sprites in 8,992 of 9,000 attract
frames: the warning screen's text, the "CREDIT" counter, and whole enemy fighters (the Yellow Hood
soldiers) but not the player (`debug/bit13/*_sheet.png`); commonest attr 0x3008. What it does on
the board is unknown: MAME ignores it, and the core follows MAME. A PCB recording of those
enemies would show whether it changes how they are drawn.

## Next steps

1. ~~User approval of this roadmap, the 48 MHz clock and the 8 MHz pixel clock assumption.~~
2. ~~Phase 0, criteria 1-6.~~ `a4fc5d9`, `62f964f`.
3. ~~Phase 0, criterion 7.~~ `62f964f`, +5.706 ns.
4. ~~Phase 1 RTL, `.mra` generator, boot bench~~ `9cfac89`.
5. ~~Phase 1 on hardware.~~ ISSP C at 22:37:10 (Progress).
6. Phase 2: `render_model.py` for silkroad.cpp against MAME frames, then the three 6 bpp layers,
   the strip sprites, the compositor and 380 x 224.
