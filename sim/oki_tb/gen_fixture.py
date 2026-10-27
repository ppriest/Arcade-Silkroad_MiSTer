#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fixture for sim/oki_tb: silkroad's OKI 1 ROM (rom00.bin, 512 KB) as $readmemh text.

    python sim/oki_tb/gen_fixture.py      # from the repository root
    -> sim/oki_tb/oki.hex                 (not committed)

Read from silkroad.zip in MAME_ROMPATH by CRC (b10ba7ab). Also prints the shortest valid
phrase in the M6295 window as the chip sees it with bank 0 (0x00000-0x1FFFF fixed,
0x20000-0x3FFFF = ROM 0x20000-0x3FFFF), which the bench plays.
"""
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
from coretools import load_env  # noqa: E402

CRC = 0xB10BA7AB


def main():
    for d in load_env().get("MAME_ROMPATH", "").split(";"):
        zp = Path(d.strip()) / "silkroad.zip"
        if zp.exists():
            break
    else:
        sys.exit("silkroad.zip not found in MAME_ROMPATH")
    z = zipfile.ZipFile(zp)
    rom = z.read(next(i for i in z.infolist() if i.CRC == CRC))
    out = REPO / "sim" / "oki_tb" / "oki.hex"
    out.write_text("".join(f"{b:02x}\n" for b in rom))
    best = None
    for n in range(1, 128):
        e = rom[n * 8:n * 8 + 6]
        start = int.from_bytes(e[0:3], "big") & 0x3FFFF
        end = int.from_bytes(e[3:6], "big") & 0x3FFFF
        if 0x400 <= start < end and (best is None or end - start < best[2] - best[1]):
            best = (n, start, end)
    print(f"wrote {len(rom)} bytes to {out.relative_to(REPO)}; shortest phrase {best[0]} "
          f"0x{best[1]:05x}-0x{best[2]:05x} ({best[2] - best[1] + 1} bytes)")


if __name__ == "__main__":
    main()
