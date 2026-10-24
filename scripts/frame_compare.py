#!/usr/bin/env python3
"""Compare sim/frame_tb's recorded frames with scripts/render_model.py's frame.

    python scripts/frame_compare.py debug/silkroad-sw600            # every recorded frame
    python scripts/frame_compare.py debug/silkroad-sw600 --frame 0

Reads <capture>/rtl_frames.hex ({vblank, hblank} digit + rgb555 per pixel clock, 512 x 262 a frame),
model_idx.bin, model_top.bin and palette.bin. The RTL's active area is where neither blank is
set; it is compared with the model's 380 x 224 at the column offset that matches best (reported,
so a shifted picture shows as a shift, not as noise). Writes <capture>/rtl_f<n>.png and
diff_f<n>.png (model | RTL | mismatches in red).
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HT, VT, W, H = 512, 262, 380, 224


def rgb888(v555):
    e = lambda c: (c << 3) | (c >> 2)
    return np.stack([e((v555 >> 10) & 31), e((v555 >> 5) & 31), e(v555 & 31)], axis=-1).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture")
    ap.add_argument("--frame", type=int, default=None)
    ap.add_argument("--flip", action="store_true",
                    help="the RTL ran flipped: compare with the model frame turned 180 degrees")
    a = ap.parse_args()
    d = Path(a.capture)

    toks = (d / "rtl_frames.hex").read_text().lower().split()
    # first digit {vblank, hblank}, then rgb555; an X or Z in the colour makes the sample
    # unknown (bit 17), never equal to a model colour
    raw = np.array([(int(t[0], 16) << 15) | (0x20000 if any(c in t[1:] for c in "xz") else int(t[1:], 16))
                    for t in toks], dtype=np.int64)
    nframes = len(raw) // (HT * VT)
    # palette.bin holds longs; the entry is the upper word (silkroad.cpp:318)
    pal = (np.frombuffer((d / "palette.bin").read_bytes(), dtype=">u4").astype(np.int64) >> 16) & 0x7fff
    model = pal[np.fromfile(d / "model_idx.bin", dtype="<u2").astype(np.int64).reshape(H, W)]
    top = np.fromfile(d / "model_top.bin", dtype=np.uint8).reshape(H, W)
    if a.flip:
        model, top = model[::-1, ::-1], top[::-1, ::-1]

    worst = 0
    for f in ([a.frame] if a.frame is not None else range(nframes)):
        fr = raw[f * HT * VT:(f + 1) * HT * VT].reshape(VT, HT)
        active = ((fr >> 15) & 3) == 0
        rows = np.nonzero(active.any(axis=1))[0]
        cols = np.nonzero(active.any(axis=0))[0]
        if len(rows) == 0:
            print(f"frame {f}: no active area")
            worst = max(worst, W * H)
            continue
        rtl = fr[rows[0]:rows[-1] + 1, cols[0]:cols[-1] + 1] & 0x27fff
        rh, rw = rtl.shape
        best = None
        for dx in range(0, max(rw - W, 0) + 1):
            sub = rtl[:H, dx:dx + W]
            if sub.shape != (H, W):
                continue
            bad = sub != model
            if best is None or bad.sum() < best[1].sum():
                best = (dx, bad, sub)
        if best is None:
            print(f"frame {f}: RTL active area {rw}x{rh} is smaller than {W}x{H}")
            worst = max(worst, W * H)
            continue
        dx, bad, sub = best
        n = int(bad.sum())
        worst = max(worst, n)
        layers = ", ".join(f"{k} {int((bad & (top == i)).sum())}" for i, k in enumerate(("bg", "l0", "l1", "l2", "spr")))
        print(f"frame {f}: RTL active {rw}x{rh} at hcnt {cols[0]}, vcnt {rows[0]}; model at column {dx}: "
              f"{W * H - n}/{W * H} match" + (f" (by top layer: {layers})" if n else " (identical)"))
        if n:
            ys, xs = np.nonzero(bad)
            print("  first: " + "  ".join(f"({x},{y}) {sub[y, x]:04x}/{model[y, x]:04x}" for y, x in list(zip(ys, xs))[:6]))
        red = np.zeros((H, W, 3), dtype=np.uint8)
        red[bad] = (255, 0, 0)
        sheet = np.concatenate([rgb888(model), np.full((H, 4, 3), 128, np.uint8), rgb888(sub & 0x7fff),
                                np.full((H, 4, 3), 128, np.uint8), red], axis=1)
        Image.fromarray(sheet).save(d / f"diff_f{f}.png")
        Image.fromarray(rgb888(rtl & 0x7fff)).save(d / f"rtl_f{f}.png")
        if (rtl >> 17).any():
            print(f"  {int((rtl >> 17).sum())} samples unknown (X/Z)")
    return 0 if worst == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
