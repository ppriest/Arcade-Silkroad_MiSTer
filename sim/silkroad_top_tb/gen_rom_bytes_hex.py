#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Converts test_video.bin (vasm -Fbin output, from sim/silkroad_core_tb/
# test_video.s) into a $readmemh-compatible hex file, one BYTE per line --
# unlike sim/silkroad_core_tb/gen_rom_hex.py's word-packed format, this
# testbench feeds the program through the real HPS ioctl_download path
# byte-at-a-time (matching real hardware), so a byte-per-line file avoids
# any unpacking step in the testbench itself.
with open("sim/silkroad_top_tb/test_video.bin", "rb") as f:
    data = f.read()

with open("sim/silkroad_top_tb/test_video_bytes.hex", "w") as f:
    for b in data:
        f.write(f"{b:02x}\n")

print(f"wrote {len(data)} bytes to sim/silkroad_top_tb/test_video_bytes.hex")
