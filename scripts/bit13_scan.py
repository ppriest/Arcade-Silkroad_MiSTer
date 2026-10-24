#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Where the game sets sprite attribute bit 13, and what it writes to video registers 3 and 4.

    python scripts/bit13_scan.py [--frames 9000] [--coin 600]

Runs MAME headless (scripts/mame/bit13.lua) once in attract and once in play, and writes to
debug/bit13/<attract|play>/: log.txt (every visible bit-13 sprite per frame, and every change of
the value written to 0xC00118-0xC0011F), snapshots of frames with such sprites, and the same
snapshots with those sprites boxed in red (*_boxed.png). Prints a summary.
"""
import argparse
import collections
import os
import re
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mame_capture as mc   # noqa: E402

REPO = Path(__file__).resolve().parent.parent


def run(tag, frames, coin):
    out = REPO / "debug" / "bit13" / tag
    out.mkdir(parents=True, exist_ok=True)
    for p in out.glob("*"):
        p.unlink()
    mame_dir, exe = mc.mame_paths()
    cmd = mc.mame_cmd(exe, "silkroad", "run.lua", mame_dir,
                      ["-snapshot_directory", out.as_posix(), "-snapview", "native"])
    env = dict(os.environ, **mc.lua_runner_env("bit13.lua"), B13_OUT=out.as_posix(),
               B13_FRAMES=str(frames), B13_COIN=str(coin))
    r = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, timeout=3600, **mc.NO_WINDOW)
    if "B13_OK" not in r.stdout + r.stderr:
        sys.exit(f"{tag}: MAME did not finish: {(r.stdout + r.stderr)[-400:]}")
    return out


def report(out):
    lines = (out / "log.txt").read_text().splitlines()
    spr = [l for l in lines if l.startswith("spr ")]
    regs = [l for l in lines if l.startswith("reg ")]
    frames = sorted({int(l.split()[2]) for l in spr})
    attrs = collections.Counter(re.search(r"attr (\w+)", l).group(1) for l in spr)
    tiles = collections.Counter(re.search(r"tile (\w+)", l).group(1) for l in spr)
    print(f"{out.name}: {len(spr)} visible bit-13 sprite entries in {len(frames)} frames"
          + (f" ({frames[0]}-{frames[-1]})" if frames else ""))
    print(f"  attr values: {dict(attrs.most_common(8))}")
    print(f"  commonest tiles: {dict(tiles.most_common(6))}")
    print(f"  register 3/4 writes that changed a value: {len(regs)}")
    for l in regs[:12]:
        print("   ", l)
    for l in lines:
        if not l.startswith("snap "):
            continue
        n = int(l.split()[2])
        boxes = l.split("boxes ", 1)[1].split(";")
        src = out / "silkroad" / f"f{n:05d}.png"
        if not src.exists():
            src = out / f"f{n:05d}.png"
        if not src.exists():
            continue
        im = Image.open(src).convert("RGB")
        d = ImageDraw.Draw(im)
        for b in boxes:
            e, x, y, w = (int(v) for v in b.split(","))
            d.rectangle([x, y, x + 16 * w - 1, y + 15], outline=(255, 0, 0))
        im.save(out / f"f{n:05d}_boxed.png")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--frames", type=int, default=9000)
    ap.add_argument("--coin", type=int, default=600)
    a = ap.parse_args()
    for tag, coin in (("attract", 0), ("play", a.coin)):
        report(run(tag, a.frames, coin))


if __name__ == "__main__":
    main()
