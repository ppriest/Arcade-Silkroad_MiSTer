#!/usr/bin/env python3
"""Inputs for sim/frame_tb from a scripts/mame_capture.py directory.

    python sim/frame_tb/prep.py debug/silkroad-sw600

Writes <capture>/cpu_state.hex: the words the bench writes through the CPU ports, in order --
sprite RAM (2048), palette (4096: the upper word of each long of palette.bin), VRAM 0, 1, 2
(8192 each), the twelve video-register halves (reg_vregs.bin) -- and debug/<set>-image.sdram:
the .mra image with each byte pair swapped, so the bench's $fread (first byte to the high half)
leaves the even byte in the low half, as the download does. Runs render_model.py on the capture
if its model files are missing.
"""
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
import build_mra   # noqa: E402


def words(b):
    return [b[i] << 8 | b[i + 1] for i in range(0, len(b), 2)]


def main():
    d = Path(sys.argv[1])
    setname = dict(l.split(" ", 1) for l in (d / "manifest.txt").read_text().splitlines() if " " in l)["set"]
    w = []
    spr = (d / "spriteram.bin").read_bytes()
    assert len(spr) == 0x1000, len(spr)
    w += words(spr)
    pal = (d / "palette.bin").read_bytes()
    assert len(pal) == 0x4000, len(pal)
    w += words(pal)[0::2]
    for i in range(3):
        v = (d / f"vram{i}.bin").read_bytes()
        assert len(v) == 0x4000, (i, len(v))
        w += words(v)
    vr = (d / "reg_vregs.bin").read_bytes()
    assert len(vr) == 24, len(vr)
    w += words(vr)
    (d / "cpu_state.hex").write_text("".join(f"{x:04x}\n" for x in w))

    sd = REPO / "debug" / f"{setname}-image.sdram"
    if not sd.exists():
        img = build_mra.build(setname, build_mra.sdram_map(), REPO / "releases" / "_dev", write=False)
        if not img:
            sys.exit(f"{setname}: no ROM image (zip not found)")
        img = bytearray(img)
        img[0::2], img[1::2] = img[1::2], img[0::2]
        sd.write_bytes(bytes(img))
    if not (d / "model_idx.bin").exists() or not (d / "model_top.bin").exists():
        subprocess.run([sys.executable, str(REPO / "scripts" / "render_model.py"), str(d)], check=False)
    print(f"{d}/cpu_state.hex, {sd.relative_to(REPO)}")
    print(f"scripts/run_sim.sh frame_tb +CAP={d.as_posix()} +IMG={sd.relative_to(REPO).as_posix()}")


if __name__ == "__main__":
    main()
