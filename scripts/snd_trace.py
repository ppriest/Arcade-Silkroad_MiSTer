#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""MAME's sound-chip writes and audio, and a window of them for sim/snd_trace_tb.

    python scripts/snd_trace.py --seconds 20 --window 12 2          # attract, window 12-14 s
    python scripts/snd_trace.py --seconds 40 --coin 600 --window 30 2 --tag play
    python scripts/snd_trace.py --compare [--tag play]              # after the bench ran

Runs MAME 0.289 with scripts/mame/sndtrace.lua (every write to the YM2151, both OKIs and the
bank register, with its time) and -wavwrite. For the bench it writes window_events.txt: every
YM2151 write before the window, 1,000 clk apart (the chip's state at the window: its patches
and channel settings), then every write inside the window at its clk_sys time (48 MHz) from
the window's start. OKI writes before the window are left out: a voice still playing at the
start is missed, so the comparison skips the window's first 0.25 s.

--compare reads the bench's rtl_window.txt (left and right at 48 kHz) and MAME's recording of the
same window, finds the lag that lines them up (up to 50 ms) and reports, per channel, the
correlation there and the ratio of the two levels. jt51 is not MAME's ymfm and jt6295 not its
okim6295, so this is a check of the same music at the same level, not of equal samples; the
WAV files are for listening.

Output in debug/snd_trace/<tag>/: sndtrace.txt, mame.wav, window_events.txt, and after the bench
rtl.wav, mame_window.wav.
"""
import argparse
import os
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mame_capture as mc   # noqa: E402

REPO = Path(__file__).resolve().parent.parent
CLK = 48e6


def capture(out, seconds, coin):
    mame_dir, exe = mc.mame_paths()
    cmd = [str(exe), "silkroad", "-nodebug", "-nowindow", "-video", "none", "-skip_gameinfo",
           "-nothrottle", "-autoboot_delay", "0", "-autoboot_script", str(mc.LUA_DIR / "run.lua"),
           "-rompath", mc.rompath(mame_dir), "-wavwrite", str((out / "mame.wav").resolve()),
           "-samplerate", "48000", "-seconds_to_run", str(seconds + 5)]
    env = dict(os.environ, **mc.lua_runner_env("sndtrace.lua"), CORE_OUT=out.as_posix(),
               CORE_SECONDS=str(seconds), CORE_COIN=str(coin))
    r = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **mc.NO_WINDOW)
    if "CORE_SNDTRACE_OK" not in r.stdout + r.stderr:
        sys.exit(f"MAME did not finish: {(r.stdout + r.stderr)[-400:]}")


def events(out):
    """(seconds, kind, value): kind oki1, oki2, bank, yma, ymd."""
    ev = []
    for ln in (out / "sndtrace.txt").read_text().split("\n"):
        if not ln.strip():
            continue
        t, off, data, mask = ln.split()
        t, off, data, mask = float(t), int(off, 16), int(data, 16), int(mask, 16)
        lanes = {0xFF000000: 0, 0x00FF0000: 1, 0x0000FF00: 2, 0x000000FF: 3}
        for m, lane in lanes.items():
            if not mask & m:
                continue
            a = off + lane
            v = (data >> (8 * (3 - lane))) & 0xFF
            kind = {0xC00025: "oki1", 0xC00029: "yma", 0xC0002D: "ymd", 0xC00031: "oki2", 0xC00034: "bank"}.get(a)
            if kind:
                ev.append((t, kind, v))
    return ev


def window(out, start, length):
    ev = events(out)
    lines, clk = [], 0
    for t, kind, v in ev:
        if t < start and kind in ("yma", "ymd"):
            lines.append(f"{clk} {kind} {v}")
            clk += 1000
    pre = clk + 1000
    for t, kind, v in ev:
        if start <= t < start + length:
            lines.append(f"{pre + int(round((t - start) * CLK))} {kind} {v}")
    (out / "window_events.txt").write_text("\n".join(lines) + "\n")
    (out / "window.txt").write_text(f"{start} {length} {pre}\n")
    print(f"{len(ev)} writes; window {start}-{start + length} s: {len(lines)} events, "
          f"the window starting at clk {pre}")


def read_wav(p):
    with wave.open(str(p)) as w:
        n, ch, rate = w.getnframes(), w.getnchannels(), w.getframerate()
        x = np.frombuffer(w.readframes(n), dtype="<i2").astype(np.float64).reshape(-1, ch)
    return x, rate


def write_wav(p, x, rate=48000):
    with wave.open(str(p), "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(np.clip(x, -32768, 32767).astype("<i2").tobytes())


def compare(out):
    start, length, _ = (float(v) for v in (out / "window.txt").read_text().split())
    mame, rate = read_wav(out / "mame.wav")
    assert rate == 48000, rate
    rtl = np.array([[int(v) for v in ln.split()] for ln in (out / "rtl_window.txt").read_text().split("\n") if ln.strip()],
                   dtype=np.float64)
    m = mame[int(start * rate):int((start + length) * rate)]
    write_wav(out / "rtl.wav", rtl)
    write_wav(out / "mame_window.wav", m)
    skip = int(0.25 * rate)
    n = min(len(m), len(rtl)) - skip - 2400
    for ch, name in ((0, "left"), (1, "right")):
        a = m[skip:skip + n, ch]
        best = None
        for lag in range(-2400, 2401, 4):
            b = rtl[skip + lag:skip + lag + n, ch] if skip + lag >= 0 else None
            if b is None or len(b) < n:
                continue
            c = np.dot(a - a.mean(), b - b.mean()) / (np.std(a) * np.std(b) * n + 1e-9)
            if best is None or c > best[1]:
                best = (lag, c)
        lag, c = best
        b = rtl[skip + lag:skip + lag + n, ch]
        print(f"{name}: lag {lag / rate * 1000:+.1f} ms, correlation {c:.3f}, "
              f"RMS RTL/MAME {np.std(b) / (np.std(a) + 1e-9):.3f} (MAME RMS {np.std(a):.0f})")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seconds", type=float, default=20)
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--window", type=float, nargs=2, metavar=("START", "LENGTH"), default=(12, 2))
    ap.add_argument("--tag", default="attract")
    ap.add_argument("--compare", action="store_true")
    a = ap.parse_args()
    out = REPO / "debug" / "snd_trace" / a.tag
    out.mkdir(parents=True, exist_ok=True)
    if a.compare:
        compare(out)
        return 0
    capture(out, a.seconds, a.coin)
    window(out, *a.window)
    return 0


if __name__ == "__main__":
    sys.exit(main())
