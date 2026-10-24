#!/usr/bin/env python3
"""Capture scenes from every set and check scripts/render_model.py against each.

    python scripts/model_sweep.py                       # all sets, the default scene list
    python scripts/model_sweep.py dreamwld --jobs 4
    python scripts/model_sweep.py --report-only         # re-run the model on existing captures

A scene is (frame, coin): coin 0 is attract, otherwise a coin at that frame and play
(mame_capture.py --coin). Captures go to debug/<set>-sw<frame>[p]/. Prints, per scene, the
model's match and the features it exercises, so a feature no scene reaches is visible.
"""
import argparse
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_mra   # noqa: E402

REPO = Path(__file__).resolve().parent.parent
SCENES = [(600, 0), (1500, 0), (2400, 0), (3600, 0), (4800, 0), (6000, 0), (7200, 0),
          (1500, 600), (2400, 600), (3000, 600), (3600, 600), (4800, 600), (6000, 600)]


def name(frame, coin):
    return f"sw{frame}" + ("p" if coin else "")


def capture(setname, frame, coin):
    cmd = [sys.executable, str(REPO / "scripts" / "mame_capture.py"), setname, "--frame", str(frame),
           "--name", name(frame, coin)] + (["--coin", str(coin)] if coin else [])
    r = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip().splitlines()[-1:]


def features(d):
    """What the scene exercises, from the captured registers, VRAM and sprite RAM."""
    sys.path.insert(0, str(REPO / "scripts"))
    import render_model as rm
    cap = rm.load_capture(d)
    out = [f"scroll:{','.join(f'{x:x}/{y:x}' for x, y in rm.scrolls(cap['regs']))}"]
    fl = [str(l) for l in range(3) if (cap["vram"][l][:4096] & 0x80).any()]
    if fl:
        out.append("tflip" + "".join(fl))
    src = cap["spriteram"].reshape(-1, 2)
    end = next((n for n in range(512) if (int(src[n, 1]) & 0xff00) == 0xff00), 512)
    s0, s1 = src[:end, 0], src[:end, 1]
    x, y = ((s0 >> 16) & 0x1ff) + 8 - rm.VX, (s0 & 0xffff) - rm.VY
    w = ((s1 >> 8) & 0xf) + 1
    vis = (x < rm.W) & (x + 16 * w > 0) & (y < rm.H) & (y + 16 > 0)
    out.append(f"spr:{int(vis.sum())}/{end}")
    if (vis & (s1 & 0x80 > 0)).any():
        out.append("xflip")
    if vis.any():
        out.append(f"maxw{int(w[vis].max())}")
    if (vis & (s1 & 0x1000 > 0)).any():
        out.append("pri1")
    if (vis & (s1 & 0x1000 == 0)).any():
        out.append("pri0")
    if (vis & (s1 & 0x8000 > 0)).any():
        out.append("tile17")
    return " ".join(out)


def model(d):
    r = subprocess.run([sys.executable, str(REPO / "scripts" / "render_model.py"), str(d)],
                       cwd=REPO, capture_output=True, text=True)
    line = [l for l in r.stdout.splitlines() if "pixels match" in l]
    return r.returncode == 0, (line[0].split(": ", 1)[1] if line else (r.stdout + r.stderr).strip()[-200:])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--report-only", action="store_true")
    a = ap.parse_args()
    sets = a.sets or list(build_mra.SETS)
    jobs = [(s, f, c) for s in sets for f, c in SCENES]
    if not a.report_only:
        with ThreadPoolExecutor(a.jobs) as ex:
            for (s, f, c), (ok, tail) in zip(jobs, ex.map(lambda j: capture(*j), jobs)):
                if not ok:
                    print(f"{s} {name(f, c)}: capture failed: {tail}")
    bad = 0
    for s, f, c in jobs:
        d = REPO / "debug" / f"{s}-{name(f, c)}"
        if not (d / "manifest.txt").exists():
            print(f"{s:10} {name(f, c):8} no capture")
            bad += 1
            continue
        ok, msg = model(d)
        bad += not ok
        print(f"{s:10} {name(f, c):8} {'PASS' if ok else 'FAIL'}  {msg:44}  {features(d)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
