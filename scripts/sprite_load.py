#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Sprite tile rows per scanline, from MAME, for the sprite fetch budget.

    python scripts/sprite_load.py silkroad [--skip 600] [--frames 1800]
    python scripts/sprite_load.py silkroad --coin 600 --skip 900 --tag _play
    python scripts/sprite_load.py silkroad --reuse [--blank]

Dumps sprite RAM (0x40C000-0x40CFFF, 512 records of two longs) at every vblank
start (scripts/mame/sprdump.lua), after the frame is drawn from live RAM and
before the game writes the next list in the 10 lines after it
(docs/write_timing_mame.txt): each dump is the list that frame showed.

Geometry is draw_sprites() in silkroad.cpp (lines 192-232), MAME screen coordinates:
    long 0: X 24:16, Y 15:0; long 1: tile 31:16 (+0x10000 when bit 15),
    width - 1 in 11:8, end of list when bits 15:8 are 0xFF
    tile k of the strip at X + 8 + 16k, Y to Y + 15, no wrap
A flipped strip covers the same pixels as an unflipped one.
Visible area: X 50..429, Y 16..239 (silkroad.cpp:454).

Two counts per line:
    rows      tile rows of every strip whose Y span covers the line -- what an
              engine that does not test X fetches
    visible   only the tiles that overlap X 50..429
With --blank, visible rows whose 16 pixels are all pen 0 (all ones in the ROM,
which MAME inverts) are not counted: the rows that can change a pixel.
Raw dumps: debug/sprload/<set><tag>.bin. Snapshot: debug/sprload/snap<tag>/.
"""
import argparse
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import (NO_WINDOW, lua_env, lua_runner_env, mame_cmd,  # noqa: E402
                          mame_paths, regions)

BASE, LEN = 0x40C000, 0x1000
X0, X1, Y0, Y1 = 50, 430, 16, 240

# set: (zip, gfx files per third in order; each third is 8 MB)
ROMS = {
    "silkroad":  ("silkroad", [["rom12.rom12", "rom13.rom13", "rom14.rom14", "rom07.rom07"],
                               ["rom08.rom08", "rom09.rom09", "rom10.rom10", "rom11.rom11"],
                               ["rom04.rom04", "rom05.rom05", "rom06.rom06", "rom15.rom15"]]),
    "silkroada": ("silkroad", [["silkroada/unico_sr13.rom13", "rom14.rom14", "rom07.rom07"],
                               ["silkroada/unico_sr09.rom09", "rom10.rom10", "rom11.rom11"],
                               ["silkroada/unico_sr05.rom05", "rom06.rom06", "rom15.rom15"]]),
}


def load_blank(game):
    """blank(tile, row) -- True when that sprite tile row is pen 0 in all six planes."""
    import os
    import zipfile
    zname, thirds = ROMS[game]
    for d in os.environ.get("MAME_ROMPATH", "").split(";") + [r"F:/Emulation/roms/MAME ROMs"]:
        zp = Path(d) / f"{zname}.zip"
        if zp.exists():
            break
    z = zipfile.ZipFile(zp)
    g = [b"".join(z.read(n) for n in t) for t in thirds]
    ones = bytes([0xFF]) * 4

    def blank(tile, row):
        o = (tile & 0x1FFFF) * 64 + row * 4
        return all(t[o:o + 4] == ones for t in g)
    return blank


def run(game, skip, frames, coin, tag):
    mame_dir, exe = mame_paths()
    r = regions()
    out = REPO / "debug" / "sprload" / f"{game}{tag}.bin"
    out.parent.mkdir(parents=True, exist_ok=True)
    inp = r.get("inputs", {})
    env = dict(__import__("os").environ, **lua_env(r), **lua_runner_env("sprdump.lua"),
               SD_OUT=out.as_posix(), SD_BASE=f"{BASE:x}", SD_LEN=str(LEN),
               SD_SKIP=str(skip), SD_FRAMES=str(frames), SD_COIN=str(coin),
               SD_IN_COIN=inp.get("coin", "Coin 1"), SD_IN_START=inp.get("start", "1 Player Start"),
               SD_IN_HOLD=inp.get("hold", "P1 Right"), SD_IN_PULSE=inp.get("pulse", "P1 Button 1"))
    cmd = mame_cmd(exe, game, "sprdump.lua", mame_dir,
                   ["-snapshot_directory", (out.parent / f"snap{tag}").as_posix(),
                    "-snapview", "native"])
    subprocess.run(cmd, cwd=str(mame_dir), env=env, capture_output=True, timeout=3600, **NO_WINDOW)
    return out


def frame_counts(rec, blank=None):
    rows = [0] * (Y1 - Y0)
    vis = [0] * (Y1 - Y0)
    for i in range(512):
        w0 = int.from_bytes(rec[i * 8:i * 8 + 4], "big")
        w1 = int.from_bytes(rec[i * 8 + 4:i * 8 + 8], "big")
        if (w1 & 0xFF00) == 0xFF00:
            break
        x = ((w0 >> 16) & 0x1FF) + 8
        y = w0 & 0xFFFF
        w = ((w1 >> 8) & 0xF) + 1
        tile0 = ((w1 >> 16) & 0xFFFF) + (0x10000 if w1 & 0x8000 else 0)
        flip = bool(w1 & 0x80)
        a, b = max(y, Y0), min(y + 16, Y1)
        if a >= b:
            continue
        # position k on screen shows tile k, or tile w-1-k flipped (225-228)
        cols = [k for k in range(w) if x + 16 * k < X1 and x + 16 * k + 16 > X0]
        for line in range(a, b):
            rows[line - Y0] += w
            if blank is None:
                vis[line - Y0] += len(cols)
                continue
            r = line - y
            for k in cols:
                t = tile0 + ((w - 1 - k) if flip else k)
                if not blank(t, r):
                    vis[line - Y0] += 1
    return rows, vis


def analyse(path, blank=None):
    data = path.read_bytes()
    nf = len(data) // LEN
    worst_rows = worst_vis = 0
    hist_rows, hist_vis = {}, {}
    where = None
    for f in range(nf):
        rows, vis = frame_counts(data[f * LEN:(f + 1) * LEN], blank)
        for r, v in zip(rows, vis):
            hist_rows[r] = hist_rows.get(r, 0) + 1
            hist_vis[v] = hist_vis.get(v, 0) + 1
        if max(rows) > worst_rows:
            worst_rows = max(rows)
        if max(vis) > worst_vis:
            worst_vis = max(vis)
            where = (f, vis.index(worst_vis))
    return nf, worst_rows, worst_vis, where, hist_rows, hist_vis


def pct(hist, q):
    total = sum(hist.values())
    acc = 0
    for k in sorted(hist):
        acc += hist[k]
        if acc >= q * total:
            return k
    return max(hist)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="+")
    ap.add_argument("--skip", type=int, default=600)
    ap.add_argument("--frames", type=int, default=1800)
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--tag", default="")
    ap.add_argument("--reuse", action="store_true")
    ap.add_argument("--blank", action="store_true",
                    help="do not count visible rows that are all pen 0")
    a = ap.parse_args()
    print(f"{'set':16s} {'frames':>6s}  {'rows: max':>9s} {'p99.9':>6s}  "
          f"{'visible: max':>12s} {'p99.9':>6s} {'p99':>4s} {'mean':>5s}  worst at (frame, line)")
    for g in a.sets:
        path = REPO / "debug" / "sprload" / f"{g}{a.tag}.bin"
        if not a.reuse or not path.exists():
            run(g, a.skip, a.frames, a.coin, a.tag)
        if not path.exists() or path.stat().st_size < LEN:
            print(f"{g}{a.tag}: no dump (MAME failed?)")
            continue
        blank = load_blank(g) if a.blank else None
        nf, wr, wv, where, hr, hv = analyse(path, blank)
        mean = sum(k * c for k, c in hv.items()) / sum(hv.values())
        print(f"{g + a.tag:16s} {nf:6d}  {wr:9d} {pct(hr, 0.999):6d}  "
              f"{wv:12d} {pct(hv, 0.999):6d} {pct(hv, 0.99):4d} {mean:5.1f}  {where}")


if __name__ == "__main__":
    sys.exit(main())
