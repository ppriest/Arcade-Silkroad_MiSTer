#!/usr/bin/env python3
"""Find the MAME frame each hardware screenshot shows, and diff it.

    python scripts/hw_vs_mame.py dreamwld debug/hw/p2/s*.png --from 300 --to 7200

The hardware boots at its own pace (the MCU handshake, the ROM load), so a screenshot's time
does not name a MAME frame. MAME's frames FROM..TO are dumped once (debug/<set>-frames/,
scripts/mame/snap_range.lua), each screenshot is matched on 32 x 28 thumbnails, and the
closest few are diffed pixel for pixel. Prints, per screenshot, the best frame and its
mismatch count, and writes <shot>_vs_mame.png (MAME | hardware | mismatches in red).
Native-resolution screenshots only (scripts/hw.py --native).
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mame_capture as mc   # noqa: E402

REPO = Path(__file__).resolve().parent.parent


def dump(setname, lo, hi):
    out = REPO / "debug" / f"{setname}-frames"
    out.mkdir(parents=True, exist_ok=True)
    have = {int(p.stem[1:]) for p in out.glob("f*.png")}
    if all(n in have for n in range(lo, hi + 1)):
        return out
    mame_dir, exe = mc.mame_paths()
    cmd = mc.mame_cmd(exe, setname, "run.lua", mame_dir, ["-seconds_to_run", str(hi // 50 + 10)])
    env = dict(os.environ, **mc.lua_runner_env("snap_range.lua"), CORE_OUT=out.as_posix(),
               CORE_FROM=str(lo), CORE_TO=str(hi))
    r = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **mc.NO_WINDOW)
    mc.check_lua_error(out)
    if "CORE_SNAP_OK" not in r.stdout + r.stderr:
        sys.exit("MAME did not reach frame %d:\n%s" % (hi, (r.stdout + r.stderr)[-800:]))
    return out


def thumb(a):
    h, w = a.shape[:2]
    return a[: h - h % 8, : w - w % 8].reshape(h // 8, 8, w // 8, 8, 3).mean(axis=(1, 3))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("shots", nargs="+")
    ap.add_argument("--from", dest="lo", type=int, default=300)
    ap.add_argument("--to", dest="hi", type=int, default=7200)
    ap.add_argument("--candidates", type=int, default=12)
    a = ap.parse_args()

    d = dump(a.set, a.lo, a.hi)
    frames = sorted(d.glob("f*.png"))
    frames = [p for p in frames if a.lo <= int(p.stem[1:]) <= a.hi]
    thumbs = np.stack([thumb(np.asarray(Image.open(p).convert("RGB"), dtype=np.float32)) for p in frames])

    prev = None
    for s in a.shots:
        hw = np.asarray(Image.open(s).convert("RGB"))
        dist = np.abs(thumbs - thumb(hw.astype(np.float32))).mean(axis=(1, 2, 3))
        best = None
        for i in np.argsort(dist)[: a.candidates]:
            ref = np.asarray(Image.open(frames[i]).convert("RGB"))
            if ref.shape != hw.shape:
                sys.exit(f"{s} is {hw.shape[1]}x{hw.shape[0]}, MAME {ref.shape[1]}x{ref.shape[0]}: use --native")
            bad = np.any(ref != hw, axis=-1)
            if best is None or bad.sum() < best[1].sum():
                best = (i, bad, ref)
        i, bad, ref = best
        n = int(bad.sum())
        frame = int(frames[i].stem[1:])
        step = "" if prev is None else f"  (+{frame - prev} frames)"
        prev = frame
        print(f"{Path(s).name}: MAME frame {frame}, {hw.shape[0] * hw.shape[1] - n}/{hw.shape[0] * hw.shape[1]} "
              f"pixels match{step}")
        red = np.zeros_like(hw)
        red[bad] = (255, 0, 0)
        gap = np.full((hw.shape[0], 4, 3), 128, np.uint8)
        Image.fromarray(np.concatenate([ref, gap, hw, gap, red], axis=1)).save(
            Path(s).with_name(Path(s).stem + "_vs_mame.png"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
