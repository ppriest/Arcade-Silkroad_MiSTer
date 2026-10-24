#!/usr/bin/env python3
"""Run sim/frame_tb on several captures and summarise the comparison with the model.

    python sim/frame_tb/run_scenes.py debug/dreamwld-sw600 debug/baryon-sw3600p ...
    python sim/frame_tb/run_scenes.py --default        # the scene list below

One ModelSim run per capture (scripts/run_sim.sh, so one at a time), then
scripts/frame_compare.py. The log of each run is <capture>/frame_tb.log.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
# Git bash, not WSL's: plain "bash" from Python on this machine is WSL, which cannot run the
# Windows ModelSim (scripts/run_sim.sh, "TOOL PATH RESOLUTION")
BASH = next((b for b in (os.environ.get("GIT_BASH"), "C:/Program Files/Git/bin/bash.exe",
                         shutil.which("bash")) if b and Path(b).exists()), "bash")
# chosen from scripts/model_sweep.py's feature column: both sprite priorities, flip X,
# strips to 8 wide, tile bit 16, flipped tiles, the three layers scrolled apart
DEFAULT = ["silkroad-sw600", "silkroad-sw2400", "silkroad-sw3600", "silkroad-sw7200",
           "silkroad-sw1500p", "silkroad-sw2400p", "silkroad-sw3600p"]


def main():
    args = sys.argv[1:]
    caps = [REPO / "debug" / c for c in DEFAULT] if args == ["--default"] else [Path(a) for a in args]
    rows = []
    for d in caps:
        rel = d.resolve().relative_to(REPO).as_posix()
        setname = d.name.split("-")[0]
        subprocess.run([sys.executable, str(REPO / "sim" / "frame_tb" / "prep.py"), rel], cwd=REPO,
                       check=True, capture_output=True)
        (d / "rtl_frames.hex").unlink(missing_ok=True)
        with open(d / "frame_tb.log", "w") as log:
            subprocess.run([BASH, "scripts/run_sim.sh", "frame_tb", f"+CAP={rel}",
                            f"+IMG=debug/{setname}-image.sdram"], cwd=REPO, stdout=log, stderr=subprocess.STDOUT)
        r = subprocess.run([sys.executable, str(REPO / "scripts" / "frame_compare.py"), rel], cwd=REPO,
                           capture_output=True, text=True)
        lines = [l for l in r.stdout.splitlines() if l.startswith("frame")]
        rows.append((d.name, r.returncode == 0, lines))
        print(f"{d.name:20} {'PASS' if r.returncode == 0 else 'FAIL'}", flush=True)
        for l in lines:
            print("    " + l, flush=True)
    print(f"\n{sum(ok for _, ok, _ in rows)}/{len(rows)} scenes identical to the model in every recorded frame")
    return 0 if all(ok for _, ok, _ in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
