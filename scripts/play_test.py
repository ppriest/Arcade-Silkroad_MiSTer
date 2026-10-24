#!/usr/bin/env python3
"""Boot, coin up and start each set on the MiSTer; check Pause; one contact sheet.

    python scripts/play_test.py                        # every set in releases/ (else releases/_dev)
    python scripts/play_test.py "Dream World" "Cute Fighter"

Per set: launch (scripts/hw.py run), a native frame of the attract (~25 s in), coin (key 5)
and Start (key 1) through the remote API, a native frame in play, then Pause (key P): two
frames 2 s apart must be identical, and a frame after Pause again must differ from them.
A ROT90/270 set also gets the API's scaled frame, which is the HDMI output after the rotator.
Writes debug/hw/play/<set>_*.png and debug/hw/play/sheet.png. Launching takes the board.
"""
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "debug" / "hw" / "play"
KEY_5, KEY_1, KEY_P = 6, 2, 25


def hw(*args, timeout=300):
    r = subprocess.run([sys.executable, str(REPO / "scripts" / "hw.py"), *args], cwd=REPO,
                       capture_output=True, text=True, timeout=timeout, env={**__import__("os").environ,
                                                                              "MSYS_NO_PATHCONV": "1"})
    return r.returncode, (r.stdout + r.stderr).strip()


def shot(path, native=True):
    hw("shot", *(["--native"] if native else []), "--out", str(path))
    return np.asarray(Image.open(path).convert("RGB"))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    dev = REPO / "releases" / "_dev"
    root = dev if any(dev.rglob("*.mra")) else REPO / "releases"
    mras = sorted(p for p in root.rglob("*.mra") if root == dev or dev not in p.parents)
    if sys.argv[1:]:
        mras = [p for p in mras if any(p.stem.startswith(n) for n in sys.argv[1:])]
    rows = []
    for mra in mras:
        tag = mra.stem.replace(" ", "_")[:40]
        rel = mra.relative_to(REPO / "releases").as_posix()
        remote = f"/media/fat/_Arcade/_DreamWorld/{rel}"
        rc, msg = hw("run", remote, "--settle", "25", "--native", "--out", str(OUT / f"{tag}_attract.png"))
        if rc:
            print(f"{tag}: launch failed: {msg[-200:]}")
            continue
        rotated = "vertical" in mra.read_text(encoding="utf-8")
        if rotated:
            shot(OUT / f"{tag}_hdmi.png", native=False)
        hw("keys", str(KEY_5)); time.sleep(2)
        hw("keys", str(KEY_1)); time.sleep(8)
        play = shot(OUT / f"{tag}_play.png")
        hw("keys", str(KEY_P)); time.sleep(1)
        p1 = shot(OUT / f"{tag}_pause1.png"); time.sleep(2)
        p2 = shot(OUT / f"{tag}_pause2.png")
        hw("keys", str(KEY_P)); time.sleep(2)
        after = shot(OUT / f"{tag}_resumed.png")
        paused = np.array_equal(p1, p2)
        resumed = not np.array_equal(p2, after)
        attract = np.asarray(Image.open(OUT / f"{tag}_attract.png").convert("RGB"))
        rows.append((tag, attract, play))
        print(f"{tag:24} pause holds the frame: {'yes' if paused else 'NO'}; "
              f"runs again after: {'yes' if resumed else 'NO'}" + ("; HDMI frame saved" if rotated else ""))
    if rows:
        h, w = rows[0][1].shape[:2]
        sheet = np.zeros((h * len(rows), w * 2 + 4, 3), np.uint8)
        for i, (_, a, b) in enumerate(rows):
            sheet[i * h:(i + 1) * h, :w] = a[:h, :w]
            sheet[i * h:(i + 1) * h, w + 4:] = b[:h, :w]
        Image.fromarray(sheet).save(OUT / "sheet.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
