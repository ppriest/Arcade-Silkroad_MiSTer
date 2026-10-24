#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write the .mra files and prove each one byte for byte.

    python scripts/build_mra.py                      # every set -> releases/_dev/
    python scripts/build_mra.py silkroad             # one set
    python scripts/build_mra.py --check              # verify only, write nothing
    python scripts/build_mra.py --image silkroad out.bin   # the download image, for the benches
    python scripts/build_mra.py --release            # -> releases/ (only with a released .rbf)

The image is the SDRAM layout of rtl/memory/silkroad_sdram_top.sv, whose *_BASE localparams
are read here. Each region is built twice: by this script from the driver's ROM_START records
(scripts/extract_romstart.py), and by re-reading the written .mra with scripts/mra.py
(mra-tools-c's semantics); the two must be identical. Interleave maps are not reasoned about:
each candidate is tried against the ROM_START image and the one that reproduces it is written.

MAME's "gfx" region is not stored as MAME loads it. Region A is its thirds 0 and 1 interleaved by
32 bits (one 8-byte granule a tile row), region B its third 2; neither is inverted
(ROMREGION_INVERT is the decode's). scripts/gfx_layout_check.py proves the decode of that layout
against MAME's. After Arcade-DreamWorld_MiSTer's and Arcade-Eolith_MiSTer's build_mra.py.
"""
import argparse
import itertools
import re
import subprocess
import sys
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape

sys.path.insert(0, str(Path(__file__).resolve().parent))
import extract_dips as edips       # noqa: E402
import extract_romstart as ers     # noqa: E402
import mra as mra_lib              # noqa: E402
from coretools import setting      # noqa: E402

REPO = Path(__file__).resolve().parent.parent
DRIVER = Path(setting("MAME_SRC") or "E:/mame/src/mame/unico/silkroad.cpp")
ROMDIRS = [Path(p) for p in (setting("MAME_ROMPATH") or "F:/Emulation/roms/MAME ROMs").split(";")]

# set: parent or None
SETS = {"silkroad": None, "silkroada": "silkroad"}
# per game (parent): button names, button 1 first. No manual, flyer or database found names them;
# named for what each does pressed alone in play in MAME 0.289 (docs/screenshots/buttons_mame.png,
# frames 3050-3070 after a coin and Start, one row a button): 1 swings the sword, 2 jumps, 3 changes
# the magic icon beside the health bar.
BUTTONS = {"silkroad": ["Attack", "Jump", "Select Magic"]}
CATEGORY = {"silkroad": "Fighter"}
ROTATION = {0: "horizontal", 90: "vertical (cw)", 270: "vertical (ccw)"}
ROT_CODE = {0: 0, 90: 1, 270: 2}   # mod byte bits 2:1 (Silkroad.sv game_rot)
# MAME's hiscore plugin data, beside the driver's source tree
HISCORE_DAT = DRIVER.parents[3] / "plugins" / "hiscore" / "hiscore.dat"
# rtl/hiscore.v header (Psikyo's): START_WAIT 0x199A57EF clk (8.95 s at 48 MHz) before the first
# check, CHECK_WAIT 0x3FFF, then the table's fixed fields; one 8-byte line per entry follows
HISCORE_HEADER = "19 9A 57 EF 3F FF 00 02 00 02 00 01 00 0F 10 00"


def sdram_map():
    text = (REPO / "rtl" / "memory" / "silkroad_sdram_top.sv").read_text(encoding="utf-8")
    m = {k: int(v, 16) for k, v in re.findall(r"localparam logic \[24:0\] (\w+)\s*=\s*25'h([0-9a-fA-F]+);", text)}
    need = ("GFXA_BASE", "GFXB_BASE", "MAINCPU_BASE", "OKI1_BASE", "OKI2_BASE", "ROM_END")
    for k in need:
        if k not in m:
            sys.exit(f"{k} missing from rtl/memory/silkroad_sdram_top.sv")
    return m


THIRD = 0x800000          # silkroad.cpp's gfx region, RGN_FRAC(1,3) of 24 MB (422-431)
# region -> (map key, capacity in the SDRAM map), in address order. "gfxA"/"gfxB" are built
# from MAME's "gfx" region (module docstring).
REGIONS = (("gfxA", "GFXA_BASE", 2 * THIRD), ("gfxB", "GFXB_BASE", THIRD),
           ("maincpu", "MAINCPU_BASE", 0x200000),
           ("oki1", "OKI1_BASE", 0x80000), ("oki2", "OKI2_BASE", 0x40000))


def game_info(text, setname):
    m = re.search(r"GAME\(\s*(\d+)\s*,\s*" + setname + r"\s*,[^\n]*", text)
    if not m:
        sys.exit(f"no GAME line for {setname}")
    f = [x.strip() for x in m.group(0).split("(", 1)[1].split(",")]
    q = re.findall(r'"([^"]*)"', m.group(0))
    return {"year": f[0], "machine": f[3], "ports": f[4], "rot": int(f[7][3:]),
            "manufacturer": q[0], "title": q[1]}


def zips_for(setname):
    names = [setname + ".zip"] + ([SETS[setname] + ".zip"] if SETS[setname] else [])
    found = []
    for n in names:
        for d in [REPO / "roms"] + ROMDIRS:
            if (d / n).exists():
                found.append(d / n)
                break
    return names, found


def region_size(body, region):
    m = re.search(r'ROM_REGION\w*\(\s*(0x[0-9a-fA-F]+)\s*,\s*"' + re.escape(region) + '"', body)
    return int(m.group(1), 16) if m else 0


def load_region(zs, records, size):
    """ROM_START records -> region bytes, as MAME's loader puts them (zero fill)."""
    out = bytearray(size)
    for kind, name, dest, length, crc, *rest in records:
        data = mra_lib._zip_read(zs, name, crc)
        assert len(data) == length, (name, len(data), length)
        if kind == "load":
            out[dest:dest + length] = data
        elif kind == "load32_byte":
            out[dest:dest + 4 * length:4] = data
        elif kind == "load16_byte":
            out[dest:dest + 2 * length:2] = data
        elif kind == "load32_wswap":
            # each 16-bit word of the file, bytes swapped, into every other word from dest
            for w in range(length // 2):
                out[dest + 4 * w] = data[2 * w + 1]
                out[dest + 4 * w + 1] = data[2 * w]
        else:
            sys.exit(f"record kind {kind} not handled")
    return bytes(out)


def hiscore_entries(setname):
    """The set's hiscore.dat entries as (address, length, start byte, end byte), or []."""
    if not HISCORE_DAT.exists():
        return []
    names, entries, out = [], [], {}
    for raw in HISCORE_DAT.read_text(encoding="utf-8", errors="replace").splitlines() + [""]:
        line = raw.strip()
        if line.endswith(":") and not line.startswith(("@", ";")):
            if entries:
                names, entries = [], []
            names.append(line[:-1])
        elif line.startswith("@"):
            entries.append(line)
        elif not line and entries:
            for n in names:
                out[n] = entries
            names, entries = [], []
    parsed = []
    for line in out.get(setname, []):
        f = line.split(",")
        if f[0] != "@:maincpu" or f[1] != "program":
            sys.exit(f"hiscore.dat {setname}: {line!r} is not on the main CPU's program space")
        parsed.append(tuple(int(x, 16) for x in f[2:6]))
    return parsed


def split_gfx(gfx):
    """MAME's gfx region -> (region A, region B), as rtl/memory/silkroad_sdram_top.sv stores them."""
    a = bytearray(2 * THIRD)
    t0, t1 = gfx[0:THIRD], gfx[THIRD:2 * THIRD]
    a[0::8], a[1::8], a[2::8], a[3::8] = t0[0::4], t0[1::4], t0[2::4], t0[3::4]
    a[4::8], a[5::8], a[6::8], a[7::8] = t1[0::4], t1[1::4], t1[2::4], t1[3::4]
    return bytes(a), gfx[2 * THIRD:3 * THIRD]


def find_maps(raws, want, lanes):
    """The interleave maps, one per part, under which mra.py reproduces `want`; each part gives
    lanes / len(raws) bytes per output word, as one contiguous run, in either byte order."""
    k = len(raws)
    per = lanes // k
    runs = []
    for start in range(0, lanes, per):
        for rev in (False, True):
            m = ["0"] * lanes
            digits = list(range(1, per + 1))
            if rev:
                digits.reverse()
            for j, d in enumerate(digits):
                m[lanes - 1 - (start + j)] = str(d)
            runs.append("".join(m))
    for combo in itertools.product(runs, repeat=k):
        if mra_lib.interleave(list(zip(raws, combo)), 8 * lanes) == want:
            return combo
    return None


def switches(ports, setname):
    """<dip> lines for the DSW and its default. silkroad.cpp's DSW fields are in bits 31-16;
    the .mra's byte 0 is bits 23-16 (SWA), byte 1 bits 31-24 (SWB)."""
    edips.SRC = str(DRIVER)
    blocks = edips.load()
    missing = set()
    dips = edips.parse_ports(blocks[ports], blocks, missing).get("DSW", [])
    if missing:
        sys.exit(f"{setname}: DEF_STR missing: {', '.join(sorted(missing))}")
    default, out = 0, []
    for name, mask, dflt, settings in dips:
        assert not mask & 0xFFFF, (name, hex(mask))
        mask, dflt = mask >> 16, dflt >> 16
        settings = None if settings is None else {v >> 16: lab for v, lab in settings.items()}
        default |= dflt
        if settings is None:
            continue
        pos = [i for i in range(16) if mask & (1 << i)]
        ids = []
        for idx in range(1 << len(pos)):
            v = sum(1 << b for j, b in enumerate(pos) if idx & (1 << j))
            lab = settings.get(v, "-")
            if "," in lab:
                sys.exit(f"{setname}: dip {name!r}: label {lab!r} contains a comma")
            ids.append(lab)
        q = {chr(34): "&quot;"}
        # Main_MiSTer reads bits as a range, sscanf("%d,%d") (mra_loader.cpp): first,last
        if pos != list(range(pos[0], pos[-1] + 1)):
            sys.exit(f"{setname}: dip {name!r} uses bits {pos}, not contiguous: the .mra cannot say it")
        rng = f"{pos[0]},{pos[-1]}" if len(pos) > 1 else f"{pos[0]}"
        out.append(f'        <dip name="{escape(name, q)}" bits="{rng}" '
                   f'ids="{escape(",".join(ids), q)}"/>')
    return out, default


def build(setname, sm, out_root, write=True):
    text = DRIVER.read_text(encoding="utf-8", errors="replace")
    body = ers.blocks(text)[setname]
    info = game_info(text, setname)
    parent = SETS[setname]
    names, paths = zips_for(setname)
    if not paths:
        print(f"{setname}: no zip found ({' / '.join(names)}); skipped")
        return False
    zs = [zipfile.ZipFile(p) for p in paths]

    # the image this script expects: each region at its base, zeros elsewhere
    img = bytearray(sm["ROM_END"])
    rec, data = {}, {}
    for region in ("maincpu", "gfx", "oki1", "oki2"):
        recs, unknown = ers.region_records(body, region)
        if unknown:
            sys.exit(f"{setname}: region {region}: unparsed {unknown}")
        rec[region] = recs
        data[region] = load_region(zs, recs, region_size(body, region))
    data["gfxA"], data["gfxB"] = split_gfx(data["gfx"])
    for region, key, cap in REGIONS:
        assert len(data[region]) <= cap, (setname, region, hex(len(data[region])))
        img[sm[key]:sm[key] + len(data[region])] = data[region]
    img = bytes(img)

    def thirds(t):
        r = sorted((x for x in rec["gfx"] if t * THIRD <= x[2] < (t + 1) * THIRD), key=lambda x: x[2])
        assert all(x[0] == "load" for x in r), r
        return r

    L, pos = [], 0

    def pad_to(addr, why):
        nonlocal pos
        if addr > pos:
            L.append(f'        <part repeat="0x{addr - pos:X}">00</part>  <!-- {why} -->')
            pos = addr
        assert pos == addr, (why, hex(pos), hex(addr))

    for region, key, cap in REGIONS:
        base = sm[key]
        pad_to(base, f"{region} at 0x{base:X}")
        if region == "gfxA":
            L.append("        <!-- gfx region A: thirds 0 and 1, 4 bytes each a tile row -->")
            for p0, p1 in zip(thirds(0), thirds(1)):
                assert p0[3] == p1[3] and p0[2] == p1[2] - THIRD, (p0, p1)
                start = 2 * p0[2]
                pad_to(base + start, f"gfxA 0x{start:x}")
                raws = [mra_lib._zip_read(zs, p[1], p[4]) for p in (p0, p1)]
                maps = find_maps(raws, data["gfxA"][start:start + 2 * p0[3]], 8)
                if not maps:
                    sys.exit(f"{setname}: no interleave map reproduces gfxA 0x{start:x}")
                L.append('        <interleave output="64">')
                for p, mp in zip((p0, p1), maps):
                    L.append(f'            <part name="{escape(p[1])}" crc="{p[4]:08x}" map="{mp}"/>')
                L.append("        </interleave>")
                pos += 2 * p0[3]
            continue
        if region == "gfxB":
            L.append("        <!-- gfx region B: third 2 -->")
            for p in thirds(2):
                pad_to(base + p[2] - 2 * THIRD, f"gfxB 0x{p[2] - 2 * THIRD:x}")
                L.append(f'        <part name="{escape(p[1])}" crc="{p[4]:08x}"/>')
                pos += p[3]
            continue
        recs = sorted(rec[region], key=lambda r: r[2])
        if not recs:
            continue
        L.append(f"        <!-- {region} -->")
        kinds = {r[0] for r in recs}
        if kinds == {"load32_wswap"}:
            assert len(recs) == 2 and recs[0][2] == 0 and recs[1][2] == 2 and recs[0][3] == recs[1][3], recs
            raws = [mra_lib._zip_read(zs, r[1], r[4]) for r in recs]
            maps = find_maps(raws, data[region][:2 * recs[0][3]], 4)
            if not maps:
                sys.exit(f"{setname}: no interleave map reproduces {region}")
            L.append('        <interleave output="32">')
            for r, mp in zip(recs, maps):
                L.append(f'            <part name="{escape(r[1])}" crc="{r[4]:08x}" map="{mp}"/>')
            L.append("        </interleave>")
            pos += 2 * recs[0][3]
        elif kinds == {"load"}:
            for kind, name, dest, length, crc, *rest in recs:
                pad_to(base + dest, f"{region} 0x{dest:x}")
                L.append(f'        <part name="{escape(name)}" crc="{crc:08x}"/>')
                pos += length
        elif kinds in ({"load32_byte"}, {"load16_byte"}):
            lanes = 4 if kinds == {"load32_byte"} else 2
            for i in range(0, len(recs), lanes):
                grp = recs[i:i + lanes]
                start, length = grp[0][2] - grp[0][2] % lanes, grp[0][3]
                assert all(r[3] == length for r in grp) and sorted(r[2] - start for r in grp) == list(range(lanes)), grp
                pad_to(base + start, f"{region} 0x{start:x}")
                want = data[region][start:start + lanes * length]
                raws = [mra_lib._zip_read(zs, r[1], r[4]) for r in grp]
                maps = ["".join("1" if j == lanes - 1 - k else "0" for j in range(lanes)) for k in range(lanes)]
                chosen = next((p for p in itertools.permutations(maps)
                               if mra_lib.interleave(list(zip(raws, p)), 8 * lanes) == want), None)
                if not chosen:
                    sys.exit(f"{setname}: no interleave map reproduces {region} 0x{start:x}")
                L.append(f'        <interleave output="{8 * lanes}">')
                for r, mp in zip(grp, chosen):
                    L.append(f'            <part name="{escape(r[1])}" crc="{r[4]:08x}" map="{mp}"/>')
                L.append("        </interleave>")
                pos += lanes * length
        else:
            sys.exit(f"{setname}: {region}: mixed record kinds {kinds}")
    pad_to(len(img), "image end")

    mod = ROT_CODE[info["rot"]] << 1
    hs = hiscore_entries(setname)
    hs_xml = []
    if hs:
        lines = [HISCORE_HEADER] + [f"{a >> 24:02X} {a >> 16 & 255:02X} {a >> 8 & 255:02X} {a & 255:02X} "
                                    f"{n:02X} {st:02X} {en:02X} 00" for a, n, st, en in hs]
        hs_xml = ["    <!-- hiscore (rtl/hiscore.v), from MAME's plugins/hiscore/hiscore.dat -->",
                  '    <rom index="3">', "        <part>", *("        " + l for l in lines), "        </part>",
                  "    </rom>", f'    <nvram index="4" size="{sum(n for _, n, _, _ in hs)}"/>', ""]
    game = BUTTONS[parent or setname]
    # six button slots, then Start, Coin, Pause, Service at the J1 line's positions (Silkroad.sv)
    btn_names = ",".join(game + ["-"] * (6 - len(game)) + ["Start", "Coin", "Pause", "Service"])
    # Main_MiSTer (joymapping.cpp, map_joystick) skips the "-" names and gives the n-th default
    # to the n-th named button, so the list has one entry per named button, in order
    btn_default = ",".join(["A", "B", "X", "Y", "L"][:len(game)] + ["Start", "Select", "R", "L"])
    sw, sw_def = switches(info["ports"], setname)
    q = {chr(34): "&quot;"}
    xml = [
        "<misterromdescription>",
        "    <!-- Generated by scripts/build_mra.py from MAME silkroad.cpp; the layout is",
        "         rtl/memory/silkroad_sdram_top.sv. Do not edit by hand. -->",
        f'    <about author="Paul Priest" webpage="" source="MAME silkroad.cpp"/>',
        f"    <name>{escape(info['title'])}</name>",
        f"    <setname>{setname}</setname>",
        "    <rbf>Silkroad</rbf>",
        f"    <mameversion>{mame_version()}</mameversion>",
        f"    <year>{info['year']}</year>",
        f"    <manufacturer>{escape(info['manufacturer'])}</manufacturer>",
        f"    <category>{CATEGORY[parent or setname]}</category>",
        f"    <rotation>{ROTATION[info['rot']]}</rotation>",
        "    <players>2</players>",
        "    <joystick>8-way</joystick>",
        f'    <buttons names="{escape(btn_names, q)}" default="{btn_default}" count="{len(game)}"/>',
        "",
        "    <!-- mod byte (Silkroad.sv): [2:1] orientation -->",
        f'    <rom index="1"><part>{mod:02X}</part></rom>',
        "",
        *hs_xml,
        "    <!-- address: the HPS puts the image in DDR3 and the core copies it to SDRAM (rtl/memory/rom_loader.sv) -->",
        f'    <rom index="0" zip="{"|".join(names)}" md5="none" address="0x30000000">',
        *L,
        "    </rom>",
        "",
        f'    <switches default="{sw_def & 0xff:02X},{sw_def >> 8:02X},00">',
        *sw,
        "        <!-- not on the board: read by the core, not the game (Silkroad.sv flip_screen) -->",
        '        <dip name="Flip Screen" bits="16" ids="Off,On"/>',
        "    </switches>",
        "</misterromdescription>",
        "",
    ]

    def safe(t):
        return re.sub(r'[\\/:*?"<>|]', "-", t)
    odir = (out_root / "_alternatives" / ("_" + safe(game_info(text, parent)["title"]))) if parent else out_root
    fname = odir / (safe(info["title"]) + ".mra")
    odir.mkdir(parents=True, exist_ok=True)
    tmp = fname.with_suffix(".mra.tmp")
    tmp.write_text("\n".join(xml), encoding="utf-8", newline="\n")
    got = mra_lib.build_image(str(tmp), [str(p) for p in paths])
    for z in zs:
        z.close()
    if got != img:
        diff = next((i for i in range(min(len(got), len(img))) if got[i] != img[i]), min(len(got), len(img)))
        tmp.unlink()
        sys.exit(f"{setname}: the .mra image differs from the ROM_START image at 0x{diff:x} "
                 f"({len(got)} vs {len(img)} bytes)")
    if write:
        tmp.replace(fname)
        print(f"{setname}: {fname.relative_to(REPO)}, image {len(img)} bytes, identical to ROM_START")
    else:
        tmp.unlink()
        print(f"{setname}: image {len(img)} bytes, identical to ROM_START (not written)")
    return img


def mame_version():
    exe = Path(setting("MAME_DIR") or "C:/Emulation/Emulators/MAME") / (setting("MAME_EXE") or "mame.exe")
    out = subprocess.run([str(exe), "-version"], capture_output=True, text=True, timeout=30).stdout
    m = re.match(r"\s*0\.(\d+)", out)
    if not m:
        sys.exit(f"cannot read the MAME version from {exe}")
    return "%04d" % int(m.group(1))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--release", action="store_true", help="write to releases/ instead of releases/_dev/")
    ap.add_argument("--image", nargs=2, metavar=("SET", "OUT"))
    a = ap.parse_args()
    sm = sdram_map()
    out_root = REPO / "releases" / ("" if a.release else "_dev")
    if a.image:
        img = build(a.image[0], sm, out_root, write=False)
        if img is False:
            return 1
        Path(a.image[1]).write_bytes(img)
        print(f"wrote {a.image[1]}")
        return 0
    ok = True
    for s in a.sets or list(SETS):
        if s not in SETS:
            sys.exit(f"unknown set {s}")
        ok = build(s, sm, out_root, write=not a.check) is not False and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
