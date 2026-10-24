#!/usr/bin/env python3
"""Write a set's status word (.CFG) on the MiSTer, for the debug page's switches.

    python scripts/write_cfg.py dreamwld --set 56            # trace overlay on
    python scripts/write_cfg.py dreamwld --set 56 --set 57   # overlay, ring mode
    python scripts/write_cfg.py dreamwld --clear             # all zero

/media/fat/config/<setname>.CFG holds status[127:0], little-endian (byte N = status[8N+7:8N]).
This core's DIP switches come from the .mra over ioctl index 254 and are saved in
config/dips/, not here, so writing the word does not touch them. Bits (DreamWorld.sv):
  0 reset, 40/41/42 render disable (sprites, tilemap 0, tilemap 1), 44-46 scandoubler fx,
  47-48 rotation, 49 flip 180, 54 frame-count auto-pause (stp), 56 trace overlay,
  57 tracer ring mode (latest 128 ROM reads; 0 = first 128 after reset), 58 freeze on
  trigger, 59-62 trace window, 63 re-arm, 64 CRT Adjust, 78 hiscore autosave,
  79-80 stereo mix, 121-122 aspect.
The core reads the file when the set is launched.
"""
import argparse
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from coretools import load_env  # noqa: E402
import deploy                    # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("setname")
    ap.add_argument("--set", type=int, action="append", default=[], help="status bit to set")
    ap.add_argument("--clear", action="store_true")
    a = ap.parse_args()
    word = 0
    for b in a.set:
        word |= 1 << b
    data = word.to_bytes(16, "little")
    env = load_env(require=("MISTER_HOST", "MISTER_USER", "MISTER_PASSWORD"))
    m = deploy.Mister(env, False)
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / f"{a.setname}.CFG"
        f.write_bytes(data)
        m.put(f, f"/media/fat/config/{a.setname}.CFG")
    print(f"{a.setname}.CFG = {data.hex()} (bits {sorted(a.set)})")


if __name__ == "__main__":
    main()
