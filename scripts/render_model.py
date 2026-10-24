#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render a captured frame the way silkroad.cpp's screen_update does, and compare it with MAME's.

    python scripts/render_model.py debug/silkroad-t19            # model.png, model_idx.bin, report
    python scripts/render_model.py debug/silkroad-t19 --layers   # also l0/l1/l2/spr.png

Input: a scripts/mame_capture.py directory (spriteram, palette, vram0-2 .bin, reg_vregs.bin,
reference.png, manifest.txt). MAME draws at vblank start from live RAM (silkroad.cpp:186), and
the capture is read at the same moment, so it is the state the frame was drawn from. The gfx
region is built from the zip as MAME loads it (scripts/build_mra.py's ROM_START reader).

Output, beside the capture: model.png (RGB), model_idx.bin (palette index per pixel, u16 LE,
380 x 224 row-major), model_top.bin (what is on top per pixel, u8: 0 backdrop, 1-3 layers 0-2,
4 sprite) -- scripts/frame_compare.py compares the RTL against these -- and the match against
reference.png. The model is checked against MAME here; the RTL is checked against the model.

Line references are to silkroad.cpp at MAME_SRC.
"""
import argparse
import sys
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_mra   # noqa: E402

REPO = Path(__file__).resolve().parent.parent
VX, VY, W, H = 50, 16, 380, 224      # set_visarea(6*8+2, 64*8-1-(10*8)-2, 2*8, 32*8-1-(2*8)), 454
THIRD = 0x800000
NTILES = 0x20000


def gfx_pens(setname, rebuild=False):
    """Every 16x16 tile as pens 0-63 (NTILES x 16 x 16, u8), tiles16x16x6_layout (422-431) with
    ROMREGION_INVERT (488). Cached in debug/<set>-pens.npy."""
    cache = REPO / "debug" / f"{setname}-pens.npy"
    if cache.exists() and not rebuild:
        return np.load(cache)
    text = build_mra.DRIVER.read_text(encoding="utf-8", errors="replace")
    body = build_mra.ers.blocks(text)[setname]
    recs, unknown = build_mra.ers.region_records(body, "gfx")
    assert not unknown, unknown
    _, paths = build_mra.zips_for(setname)
    zs = [zipfile.ZipFile(p) for p in paths]
    g = np.frombuffer(build_mra.load_region(zs, recs, 3 * THIRD), dtype=np.uint8) ^ 0xFF
    pens = np.zeros((NTILES, 16, 16), dtype=np.uint8)
    bit = 7 - (np.arange(16) & 7)
    for t in range(3):
        b = g[t * THIRD:(t + 1) * THIRD].reshape(NTILES, 16, 4)
        lo = np.where(np.arange(16) < 8, b[:, :, 0:1], b[:, :, 2:3])     # plane +0 (422-427)
        hi = np.where(np.arange(16) < 8, b[:, :, 1:2], b[:, :, 3:4])     # plane +8
        pair = (((hi >> bit) & 1) << 1) | ((lo >> bit) & 1)
        pens |= (pair << (2 * (2 - t))).astype(np.uint8)                 # first plane listed = MSB
    cache.parent.mkdir(exist_ok=True)
    np.save(cache, pens)
    return pens


def load_capture(d):
    be32 = lambda n: np.frombuffer((d / n).read_bytes(), dtype=">u4").astype(np.int64)
    regs = be32("reg_vregs.bin")
    return {"vram": [be32(f"vram{i}.bin") for i in range(3)], "spriteram": be32("spriteram.bin"),
            "palette": be32("palette.bin") >> 16, "regs": regs}


def scrolls(regs):
    """(x, y) per layer, screen_update 266-273."""
    r = [int(v) for v in regs] + [0] * (6 - len(regs))
    return [(r[0] >> 16, r[0] & 0xffff), (r[2] & 0xffff, r[5] >> 16), (r[2] >> 16, r[1] >> 16)]


def draw_tilemap(cap, pens, layer, sx, sy):
    """One layer as palette indices and opaque mask over the visible area. get_tile_info (236-247):
    code 31-16 + 0x18000, colour 4-0, flip X bit 7; 64 x 64 tiles, pen 0 transparent (256-258)."""
    v = cap["vram"][layer][:4096].reshape(64, 64)                      # TILEMAP_SCAN_ROWS
    code = ((v >> 16) + 0x18000) % NTILES
    colour = v & 0x1f
    flip = ((v >> 7) & 1).astype(bool)
    ys = (np.arange(VY, VY + H) + sy) & 1023
    xs = (np.arange(VX, VX + W) + sx) & 1023
    ty, tx = ys >> 4, xs >> 4
    fy, fx = ys & 15, xs & 15
    c = code[ty[:, None], tx[None, :]]
    f = flip[ty[:, None], tx[None, :]]
    px = np.where(f, 15 - fx[None, :], fx[None, :])
    p = pens[c, fy[:, None], px].astype(np.int64)
    return colour[ty[:, None], tx[None, :]] * 64 + p, p != 0


def draw_sprites(cap, pens, idx, pri):
    """draw_sprites (192-232) with prio_transpen's pixel op (emu/drawgfxt.ipp 189-200): a pixel
    is drawn unless (1 << priority) & pmask, and every opaque pixel sets the priority to 31.
    Modifies idx and pri in place; returns the mask of pixels a sprite drew."""
    drawn = np.zeros((H, W), dtype=bool)
    src = cap["spriteram"]
    for n in range(512):
        s0, s1 = int(src[2 * n]), int(src[2 * n + 1])
        if (s1 & 0xff00) == 0xff00:
            break
        xpos, ypos = (s0 >> 16) & 0x1ff, s0 & 0xffff
        tileno = (s1 >> 16) & 0xffff
        attr = s1 & 0xffff
        flipx = bool(attr & 0x80)
        width = ((attr >> 8) & 0xf) + 1
        colour = attr & 0x3f
        pmask = ~((1 << (((attr >> 12) & 1) + 1)) - 1) & 0xffffffff
        if attr & 0x8000:
            tileno += 0x10000
        for k in range(width):                                       # k: position from the left
            t = (tileno + ((width - 1 - k) if flipx else k)) % NTILES
            tile = pens[t][:, ::-1] if flipx else pens[t]
            x, y = xpos + k * 16 + 8 - VX, ypos - VY
            x0, y0, x1, y1 = max(x, 0), max(y, 0), min(x + 16, W), min(y + 16, H)
            if x0 >= x1 or y0 >= y1:
                continue
            p = tile[y0 - y:y1 - y, x0 - x:x1 - x]
            op = p != 0
            pr = pri[y0:y1, x0:x1]
            show = op & ((((1 << pr) & pmask)) == 0)
            sub = idx[y0:y1, x0:x1]
            sub[show] = colour * 64 + p[show].astype(np.int64)
            drawn[y0:y1, x0:x1] |= show
            pr[op] = 31
    return drawn


def pal_rgb(palette):
    """xRGB_555, MAME's pal5bit expansion."""
    r, g, b = (palette >> 10) & 31, (palette >> 5) & 31, palette & 31
    e = lambda c: (c << 3) | (c >> 2)
    return np.stack([e(r), e(g), e(b)], axis=-1).astype(np.uint8)


def render(cap, pens):
    """screen_update (262-278): idx (palette index), top (0 backdrop, 1-3 layer, 4 sprite)."""
    idx = np.full((H, W), 0x7c0, dtype=np.int64)
    top = np.zeros((H, W), dtype=np.uint8)
    pri = np.zeros((H, W), dtype=np.int64)
    layers = []
    for layer, (sx, sy) in enumerate(scrolls(cap["regs"])):
        li, lm = draw_tilemap(cap, pens, layer, sx, sy)
        idx[lm] = li[lm]
        top[lm] = layer + 1
        pri[lm] |= layer                                             # draw(..., 0, layer)
        layers.append((li, lm))
    drawn = draw_sprites(cap, pens, idx, pri)
    top[drawn] = 4
    return idx, top, layers, drawn


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture")
    ap.add_argument("--layers", action="store_true", help="also write each layer alone")
    ap.add_argument("--rebuild", action="store_true", help="rebuild the decoded-tile cache")
    a = ap.parse_args()
    d = Path(a.capture)
    man = dict(l.split(" ", 1) for l in (d / "manifest.txt").read_text(encoding="utf-8").splitlines() if " " in l)
    setname = man["set"]
    pens = gfx_pens(setname, a.rebuild)
    cap = load_capture(d)
    idx, top, layers, drawn = render(cap, pens)

    rgb = pal_rgb(cap["palette"])
    Image.fromarray(rgb[idx]).save(d / "model.png")
    idx.astype("<u2").tofile(d / "model_idx.bin")
    top.tofile(d / "model_top.bin")
    if a.layers:
        for i, (li, lm) in enumerate(layers):
            Image.fromarray(np.where(lm[..., None], rgb[li], 0).astype(np.uint8)).save(d / f"l{i}.png")
        Image.fromarray(np.where(drawn[..., None], rgb[idx], 0).astype(np.uint8)).save(d / "spr.png")

    ref = np.asarray(Image.open(d / "reference.png").convert("RGB"))
    if ref.shape[:2] != (H, W):
        sys.exit(f"reference.png is {ref.shape[1]}x{ref.shape[0]}, expected {W}x{H}")
    bad = np.any(ref != rgb[idx], axis=-1)
    n = int(bad.sum())
    print(f"{setname} {man.get('frame', '?')}: {W * H - n}/{W * H} pixels match MAME"
          + ("" if n else " (identical)"))
    if n:
        names = np.array(["bg", "l0", "l1", "l2", "spr"])
        ys, xs = np.nonzero(bad)
        for y, x in list(zip(ys, xs))[:10]:
            print(f"  ({x},{y}) model {tuple(rgb[idx[y, x]])} [{names[top[y, x]]} 0x{idx[y, x]:03x}] "
                  f"MAME {tuple(ref[y, x])}")
        for k in range(5):
            print(f"  {names[k]}: {int((bad & (top == k)).sum())} differing pixels on top")
    return 0 if n == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
