#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check the core's graphics layout against MAME's gfx_layout, on the real ROMs.

    python scripts/gfx_layout_check.py [--tiles N]

1. Every bit of a tile is used exactly once by tiles16x16x6_layout
   (silkroad.cpp:422-431), with no ROM.
2. The core's layout decodes every pixel of N tiles (spread over sprites and
   backgrounds) to the same pen as MAME's generic decode of the "gfx" region,
   ROMREGION_INVERT included (488).

The core's layout, at load time:
  region A, 16 MB: for each 32-bit tile row, third 0's 4 bytes then third 1's
                   4 bytes; row r of tile t at t*128 + r*8 (one 8-byte granule)
  region B,  8 MB: third 2 unchanged; row r of tile t at t*64 + r*4
Decode of pixel x (0-15) from a third's 4 row bytes b0..b3: lo = b0 or b2,
hi = b1 or b3 (x < 8 or not), bit 7 - (x & 7). pen = {A0 hi, A0 lo, A1 hi,
A1 lo, B hi, B lo}, inverted. The first plane in planeoffset is the pen's MSB.
"""
import argparse
import os
import sys
import zipfile
from pathlib import Path

THIRD = 0x800000
# silkroad.cpp:422-431
PLANES = [THIRD * 0 * 8 + 8, THIRD * 0 * 8 + 0, THIRD * 1 * 8 + 8, THIRD * 1 * 8 + 0,
          THIRD * 2 * 8 + 8, THIRD * 2 * 8 + 0]
XOFF = [0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 20, 21, 22, 23]
YOFF = [r * 32 for r in range(16)]
CHARINC = 16 * 32
NTILES = THIRD * 8 // CHARINC            # RGN_FRAC(1,3) of 24 MB

# gfx region, ROM_LOAD offsets (silkroad.cpp:488-503)
LOADS = [("rom12.rom12", 0x0000000), ("rom08.rom08", 0x0800000), ("rom04.rom04", 0x1000000),
         ("rom13.rom13", 0x0200000), ("rom09.rom09", 0x0A00000), ("rom05.rom05", 0x1200000),
         ("rom14.rom14", 0x0400000), ("rom10.rom10", 0x0C00000), ("rom06.rom06", 0x1400000),
         ("rom07.rom07", 0x0600000), ("rom11.rom11", 0x0E00000), ("rom15.rom15", 0x1600000)]


def check_bits():
    seen = set()
    for p in PLANES:
        for y in YOFF:
            for x in XOFF:
                o = p + y + x
                assert o not in seen, f"bit {o} used twice"
                seen.add(o)
    # every bit of the tile's 64 bytes in each third, exactly once
    want = {t * THIRD * 8 + b for t in range(3) for b in range(CHARINC)}
    assert seen == want, f"{len(want - seen)} bits unused, {len(seen - want)} outside"
    print(f"layout: {len(seen)} bits, each of a tile's 3 x 64 bytes exactly once")


def load_region():
    for d in os.environ.get("MAME_ROMPATH", "").split(";") + [r"F:/Emulation/roms/MAME ROMs"]:
        zp = Path(d) / "silkroad.zip"
        if zp.exists():
            break
    else:
        sys.exit("silkroad.zip not found in MAME_ROMPATH")
    z = zipfile.ZipFile(zp)
    g = bytearray(3 * THIRD)
    for name, off in LOADS:
        b = z.read(name)
        g[off:off + len(b)] = b
    return bytes(x ^ 0xFF for x in g)       # ROMREGION_INVERT


def mame_pen(g, tile, x, y):
    """MAME's generic decode (emu/drawgfx.cpp, readbit: MSB first)."""
    pen = 0
    for p in PLANES:
        o = tile * CHARINC + p + YOFF[y] + XOFF[x]
        pen = (pen << 1) | ((g[o >> 3] >> (7 - (o & 7))) & 1)
    return pen


def core_regions(raw):
    """Regions A and B as the loader writes them, from the un-inverted ROM bytes."""
    a = bytearray(2 * THIRD)
    for t in range(NTILES * 16):            # every 32-bit row of a third
        a[t * 8:t * 8 + 4] = raw[t * 4:t * 4 + 4]
        a[t * 8 + 4:t * 8 + 8] = raw[THIRD + t * 4:THIRD + t * 4 + 4]
    return bytes(a), raw[2 * THIRD:3 * THIRD]


def pair(b4, x):
    lo, hi = (b4[0], b4[1]) if x < 8 else (b4[2], b4[3])
    s = 7 - (x & 7)
    return (((hi >> s) & 1) << 1) | ((lo >> s) & 1)


def core_pen(a, b, tile, x, y):
    ra = a[tile * 128 + y * 8:tile * 128 + y * 8 + 8]
    rb = b[tile * 64 + y * 4:tile * 64 + y * 4 + 4]
    pen = (pair(ra[0:4], x) << 4) | (pair(ra[4:8], x) << 2) | pair(rb, x)
    return pen ^ 0x3F


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tiles", type=int, default=4096)
    n = ap.parse_args().tiles
    check_bits()
    g = load_region()
    raw = bytes(x ^ 0xFF for x in g)
    a, b = core_regions(raw)
    step = max(1, NTILES // n)
    tiles = list(range(0, NTILES, step)) + [0x17FFF, 0x18000, 0x1FFFF]
    bad = nonzero = 0
    for t in tiles:
        for y in range(16):
            for x in range(16):
                m = mame_pen(g, t, x, y)
                nonzero += m != 0
                if core_pen(a, b, t, x, y) != m:
                    bad += 1
                    if bad <= 5:
                        print(f"  tile {t:05X} x {x} y {y}: core {core_pen(a, b, t, x, y)} mame {m}")
    print(f"decode: {len(tiles)} tiles, {len(tiles) * 256} pixels ({nonzero} not pen 0), {bad} differ")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
