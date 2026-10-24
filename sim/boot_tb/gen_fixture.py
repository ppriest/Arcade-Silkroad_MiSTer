#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fixtures for sim/boot_tb from the .mra image and MAME's boot trace.

    python scripts/mame_boot_trace.py silkroad 2000000
    python sim/boot_tb/gen_fixture.py [silkroad]

Writes, in sim/boot_tb/:
  maincpu.hex   the program ROM as 16-bit big-endian words (scripts/build_mra.py --image)
  replay.hex    MAME's I/O reads in order, one "addr mask data" line each: every read that is
                not ROM or a RAM region of regions.json "trace" (the bench returns them in turn)
  irq.hex       one line per vblank interrupt MAME took (its read of the level-4 vector at
                0x70): the number of writes before it, the last access before the vector read
                that was not a ROM fetch, whether MAME returned to the instruction that made that
                access (a loop later), and MAME's return address, as "count rw addr mask late pc"
                (rw 1 = write). The bench raises the interrupt when its CPU has made that many
                writes and is making the same access: during it, or after it when late. Accesses are counted with
                the two halves of a split access merged, as scripts/compare_boot_trace.py does,
                and as the bench does for its 16-bit CPU.
"""
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import regions  # noqa: E402
from compare_boot_trace import load, merge_halves  # noqa: E402

T = regions()["trace"]
ROM = [(int(a, 16), int(b, 16)) for a, b in T["rom"]]
RAM = [(int(a, 16), int(b, 16)) for a, b in T["ram"]]


def inr(a, rs):
    return any(lo <= a <= hi for lo, hi in rs)


def main():
    game = sys.argv[1] if len(sys.argv) > 1 else "silkroad"
    out = REPO / "sim" / "boot_tb"
    img = out / "image.bin"
    subprocess.run([sys.executable, str(REPO / "scripts" / "build_mra.py"), "--image", game, str(img)],
                   check=True, capture_output=True)
    sdram = (REPO / "rtl" / "memory" / "silkroad_sdram_top.sv").read_text(encoding="utf-8")
    import re
    base = int(re.search(r"MAINCPU_BASE\s*=\s*25'h([0-9a-fA-F]+)", sdram).group(1), 16)
    d = img.read_bytes()[base:base + 0x200000]
    img.unlink()
    with open(out / "maincpu.hex", "w") as f:
        for i in range(0, len(d), 2):
            f.write(f"{d[i] << 8 | d[i + 1]:04x}\n")

    trace = REPO / "debug" / f"{game}-boot" / f"{game}_boot.trace"
    raw = load(trace)
    nrep = 0
    with open(out / "replay.hex", "w") as fr:
        for _, rw, ai, m, dd in raw:
            if rw == "r" and not inr(ai, ROM) and not inr(ai, RAM):
                fr.write(f"{ai:06x} {m:08x} {dd:08x}\n")
                nrep += 1
    rows = merge_halves(raw)
    rom = d

    def pushed_pc(k):
        """The return address in the exception frame MAME wrote after the vector read at row k:
        the four writes after it, SR at the lowest address and the PC above it."""
        mem, got = {}, 0
        for _, rw, ai, m, dd in rows[k + 1:]:
            if rw != "w":
                continue
            for lane in range(4):
                if m >> (8 * (3 - lane)) & 0xFF:
                    mem[ai + lane] = dd >> (8 * (3 - lane)) & 0xFF
            got += 1
            if got == 4:
                break
        sp = min(mem)
        return int.from_bytes(bytes(mem[sp + 2 + i] for i in range(4)), "big")

    def refers_to(pc, addr):
        """Whether the instruction at pc names addr as an absolute long in its first extension
        words: then MAME returned to the instruction that made its last data access, a loop
        later than the access itself."""
        w = [rom[pc + i] << 8 | rom[pc + i + 1] for i in range(0, 8, 2)]
        return ((w[1] << 16 | w[2]) & 0xFFFFFF) == (addr & 0xFFFFFC) or \
               ((w[1] << 16 | w[2]) & 0xFFFFFC) == (addr & 0xFFFFFC)

    nirq, writes, last = 0, 0, None
    with open(out / "irq.hex", "w") as fi:
        for k, (_, rw, ai, m, dd) in enumerate(rows):
            if rw == "r" and ai == 0x70:
                assert last is not None
                pc = pushed_pc(k)
                late = 1 if (last[0] == 0 and refers_to(pc, last[1])) else 0
                fi.write(f"{writes:08x} {last[0]} {last[1]:06x} {last[2]:08x} {late} {pc:06x}\n")
                nirq += 1
                continue
            if rw == "w":
                writes += 1
            if rw == "w" or not inr(ai, ROM):
                last = (1 if rw == "w" else 0, ai, m)
    print(f"{len(d) // 2} ROM words, {nrep} I/O reads, {nirq} interrupts, from {len(raw)} MAME accesses")


if __name__ == "__main__":
    main()
