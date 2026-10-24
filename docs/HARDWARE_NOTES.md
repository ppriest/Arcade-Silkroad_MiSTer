# Silkroad: hardware notes

The Unico SR2001A board, as MAME models it. Each fact cites its source.

Source: MAME `src/mame/unico/silkroad.cpp` (last changed in `774a180df2b`; checkout tagged
`mame0289`), and `mame -listxml silkroad silkroada` from MAME 0.289. Line numbers are that
file's. Everything here is MAME's model unless marked otherwise. The driver uses only standard
devices (`m68ec020`, `ym2151`, `okim6295`, `gfxdecode`, `palette`, `screen`); there is no
device file of the board's own.

## Sets

| Set | Game | Board | ROM loaded | MAME flags |
|---|---|---|---|---|
| silkroad | The Legend of Silkroad | SR2001A | maincpu 2 MB, gfx 24 MB (12 x 2 MB), oki1 512 KB, oki2 256 KB | good, savestate supported (544) |
| silkroada | The Legend of Silkroad (larger ROMs) | same, 3 x 4 MB sprite ROMs | same sizes | good (545) |

Region contents compared: silkroada's `unico_sr13`, `unico_sr09`, `unico_sr05` (4 MB each) are
byte-identical to silkroad's `rom12`+`rom13`, `rom08`+`rom09`, `rom04`+`rom05` concatenated
(checked from the zip; CRCs `d001c3df`, `696d908d`, `00f638c1`). Every other ROM is shared. Both
sets build the same 26.75 MB image; they differ only in which files the `.mra` reads.

`-verifyroms`: both sets good in the local ROM path.

## CPUs and chips

| Tag | Part | Clock | Role | Existing RTL |
|---|---|---|---|---|
| maincpu | MC68EC020FG16 | 32 MHz / 2 = 16 MHz (445) | everything; no sound CPU (header, 24) | TG68K.C, running at 16 MHz in Arcade-DreamWorld_MiSTer and Arcade-Psikyo_MiSTer |
| ymsnd | YM2151 + YM3012 | 3.579545 MHz XTAL (464) | FM, stereo | jt51 (jotego), vendored in Arcade-Vamphalf_MiSTer `rtl/sound/jt51` from jtcores `985a573` |
| oki1 | OKI M6295 | 32 MHz / 32 = 1 MHz, pin 7 high, "not verified" (466) | ADPCM, banked | jt6295, vendored in DreamWorld, Vamphalf, Fuuki and others |
| oki2 | OKI M6295 | 32 MHz / 16 = 2 MHz, pin 7 high, "not verified" (471) | ADPCM | jt6295 |
| video | 2 x Actel A40MX04 | not in the driver | 3 tilemaps, sprites | none; the header says the same chips as Multi Champ (`misc/esd16.cpp`, header 30) |

RAM on the board (header 27): 62256 x8, 6116 x2, KM681000 x4.

## Clocks

| Clock | Source | Value |
|---|---|---|
| main XTAL | header 26 | 32.000 MHz |
| sound XTAL | header 26 | 3.579545 MHz, the YM2151 directly (464) |
| 68EC020 | 445 | 16 MHz |
| OKI 1 / OKI 2 | 466, 471 | 1 MHz / 2 MHz, both marked not verified |
| pixel clock | not in the driver | unknown |

**The video timing is not known.** The driver has no `set_raw`: refresh 60 Hz (451), vblank time
0 (452), a 512 x 256 bitmap (453) and a visible area of x 50-429, y 16-239 (454), 380 x 224
(`-listxml`). The only crystal that could clock the video is 32 MHz. 32/4 = 8 MHz with a
512-pixel line gives 15.625 kHz, a usual line rate; that is an inference from the bitmap width,
not a measurement. The roadmap's Clocks section carries the choice.

## Video

Display: 380 x 224 visible at 60 Hz (`-listxml`), ROT0 for both sets (544-545). Aspect 4:3.

**Graphics ROM** (`gfx`, 24 MB, `ROMREGION_INVERT`, 488): every bit inverted at load. One
`gfx_layout` (422-431): 16 x 16, 6 bpp, `RGN_FRAC(1,3)`. Each 8 MB third holds two planes (bit
offsets +8 and +0 within a 16-bit word); a tile row is 32 bits per third (pixels 0-7 in the first
16 bits, 8-15 in the second), 64 bytes a tile per third. One tile row is 12 bytes, spread over
three thirds 8 MB apart. In each third, tiles 0x00000-0x17FFF (6 MB) are sprites and
0x18000-0x1FFFF (2 MB) are background tiles (ROM comments 490-503, `code += 0x18000` at 242).

**Tilemaps** (252-254): three, 64 x 64 tiles of 16 x 16 (1024 x 1024 pixels), `TILEMAP_SCAN_ROWS`,
pen 0 transparent on all three (256-258). VRAM 16 KB each at 0x800000 / 0x804000 / 0x808000
(319-321). Tile word (236-247): bits 31-16 tile (+0x18000), bit 7 flip X, bits 4-0 colour. No
flip Y, no per-tile priority, no row or column scroll.

**Scroll registers** (`regs`, 0xC0010C-0xC00123, six 32-bit write-only words, 329), as MAME uses
them (266-273):

| Layer | X | Y |
|---|---|---|
| 0 | `regs[0]` 31-16 | `regs[0]` 15-0 |
| 1 | `regs[2]` 15-0 | `regs[5]` 31-16 |
| 2 | `regs[2]` 31-16 | `regs[1]` 31-16 |

`regs[3]`, `regs[4]` and the unused halves are not read by MAME (the disabled popmessage at
280-288 prints them).

**Sprites** (192-232): 4 KB at 0x40C000 (317), 512 entries of two 32-bit words, walked from
entry 0.

| Word | Bits | Meaning |
|---|---|---|
| 0 | 24-16 | X (9 bits); drawn at X + 8 (220) |
| 0 | 15-0 | Y, used as is |
| 1 | 31-16 | tile bits 15-0 |
| 1 | 15 | tile bit 16 (214) |
| 1 | 13 | "another priority bit?" (210), unused |
| 1 | 12 | priority |
| 1 | 11-8 | width - 1, in 16-pixel tiles: 1-16 wide, always one tile tall |
| 1 | 7 | flip X: tiles placed right to left, each mirrored (225-228) |
| 1 | 5-0 | colour, 64 banks of 64 |
| 1 | 15-8 = 0xFF | end of list (212) |

No zoom, no flip Y, no sprite-to-sprite priority bits. MAME reads live sprite RAM at
`screen_update`; the driver's own note says "Sprites probably need to be delayed" (186).

**Mixing** (262-278). The bitmap is filled with pen 0x7C0 (264), then layers 0, 1, 2 are drawn
with priority codes 0, 1, 2, ORed into the priority bitmap where the layer is opaque, then sprites
with `prio_transpen` and `pri_mask = ~((1 << (pri + 1)) - 1)` (208). Read with MAME's pixel op
(`emu/drawgfxt.ipp` 189-200):

- priority 0: above layer 0, below layers 1 and 2.
- priority 1: above layers 0 and 1, below layer 2. The driver comment "1 = Low" (207) says the
  opposite of what the code does.
- every opaque sprite pixel sets the priority bitmap to 31, drawn or not, so **the lowest-numbered
  sprite wins** where sprites overlap. A sprite hidden behind a layer still hides later sprites
  at that pixel.

**Palette** (318, 459): xRGB 555, 16 bits in the upper half of each 32-bit word at
0x600000-0x603FFF, so 4096 entries are addressable of the 0x2000 MAME declares. Tiles use colours
0-31 (entries 0x000-0x7FF), sprites 0-63 (0x000-0xFFF): one shared palette.

**Flip screen**: none in the driver and no DIP for it.

**What MAME says is unknown** (184-189): sprite delay, possible layer offsets, sprite colours, a
background colour register; bit 13 of the sprite attribute (210).

## Memory map

Main CPU (`cpu_map`, 314-331), 24-bit address, 32-bit data:

| Address | Size | What | Line |
|---|---|---|---|
| 0x000000-0x1FFFFF | 2 MB | program ROM, `ROM_LOAD32_WORD_SWAP` of rom02 / rom03 (484-485) | 316 |
| 0x40C000-0x40CFFF | 4 KB | sprite RAM | 317 |
| 0x600000-0x603FFF | 16 KB | palette, upper 16 bits only | 318 |
| 0x800000-0x803FFF | 16 KB | VRAM layer 0 | 319 |
| 0x804000-0x807FFF | 16 KB | VRAM layer 1 | 320 |
| 0x808000-0x80BFFF | 16 KB | VRAM layer 2 | 321 |
| 0xC00000-0xC00003 | r | inputs | 322 |
| 0xC00004-0xC00007 | r | DIP switches, bits 31-16 | 323 |
| 0xC00025 | r/w | OKI 1 | 324 |
| 0xC00028-0xC0002F | r/w | YM2151 on byte lane 23-16: 0xC00029 address, 0xC0002D data | 325 |
| 0xC00031 | r/w | OKI 2 | 326 |
| 0xC00034 | w | OKI 1 bank, bits 1-0; value 3 ignored (295-299) | 327 |
| 0xC00039 | w | coin counters, bits 0 and 3 (303-304) | 328 |
| 0xC0010C-0xC00123 | w | video registers, six words | 329 |
| 0xFE0000-0xFFFFFF | 128 KB | work RAM | 330 |

OKI 1's own space (334-337): 0x00000-0x1FFFF fixed at ROM 0x00000, 0x20000-0x3FFFF banked to ROM
0x20000 + bank x 0x20000, banks 0-2 (439). OKI 2 reads its 256 KB ROM directly.

Interrupts: level 4 at vblank, `irq4_line_hold` (447), autovectored. The header (9-19) lists the
program's vectors: level 4 at 0x12C, every other level an `rte` at 0x1D6.

Inputs (339-378): P1 in bits 31-24 (up, down, right, left, buttons 1-3), P2 in bits 23-16, system
in bits 7-0 (coins, starts, service 1, test, service 2). Bit 7 is `IPT_CUSTOM` with Stephh's note
that it freezes input reads (122-131); bit 8 "makes the 020 lock up" (350). Three buttons a player.

DIPs (380-415): SWA lives, special effect, difficulty (8 levels); SWB free play, demo sounds,
chute type, coinage. The header (37-80) has the operator sheet's version.

## Sound

YM2151 left and right to the two speaker channels at 1.0; both OKIs to both channels at 0.45
(464-473). Stereo FM, mono ADPCM.

## Feasibility

Not a large board: a 16 MHz 68EC020 already running on TG68K.C in two sibling cores, a YM2151 and
two M6295 with vendored RTL in sibling cores, and 26.75 MB of ROM in a 32 MB SDRAM module. The
open question is the per-line graphics fetch: a 6 bpp tile row is 12 bytes against 8 for a 4 bpp
board, with three layers plus sprites up to 16 tiles wide. The sprite load per line is measured
from MAME in Phase 0 before the memory plan is fixed.
