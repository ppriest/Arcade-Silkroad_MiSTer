-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sprites with attribute bit 13 set (silkroad.cpp:210, "another priority bit?") and every write
-- to video registers 3 and 4 (0xC00118-0xC0011F, silkroad.cpp:329; unused by MAME's
-- screen_update). Driven by scripts/bit13_scan.py through run.lua.
--
--   B13_OUT     output directory: log.txt, and f<frame>.png snapshots
--   B13_FRAMES  frames to run
--   B13_COIN    frame to insert a coin, press Start and play (0 = attract only)
--   B13_SNAPS   at most this many snapshots of frames with a visible bit-13 sprite
--
-- Each frame (frame_done, vblank start: the list just drawn) the sprite list is walked as
-- draw_sprites does, to the end marker; an entry with bit 13 set and any tile on screen is
-- logged: frame, entry, X, Y, tile, attr.
local OUT    = os.getenv("B13_OUT")
local FRAMES = tonumber(os.getenv("B13_FRAMES") or "6000")
local COIN   = tonumber(os.getenv("B13_COIN") or "0")
local SNAPS  = tonumber(os.getenv("B13_SNAPS") or "15")
local m      = manager.machine
local scr    = m.screens[":screen"]
local prog   = m.devices[":maincpu"].spaces["program"]

local log = assert(io.open(OUT .. "/log.txt", "w"))

-- write tap on regs[3] and regs[4]
local last = {}
reg_tap = prog:install_write_tap(0xc00118, 0xc0011f, "b13regs", function(offset, data, mask)
    local n = scr:frame_number()
    local key = offset .. ":" .. mask
    local v = data & mask
    if last[key] ~= v then
        log:write(string.format("reg frame %d addr %06x mask %08x data %08x line %d\n",
                                n, offset, mask, v, scr:vpos()))
        last[key] = v
    end
    return data
end)

local function field(name)
    for _, port in pairs(m.ioport.ports) do
        if port.fields[name] then return port.fields[name] end
    end
end
local f_coin, f_start = field("Coin 1"), field("1 Player Start")
local f_b1, f_right = field("P1 Button 1"), field("P1 Right")

local snaps, n = 0, 0
sub = emu.add_machine_frame_notifier(function()
    n = scr:frame_number()
    if COIN > 0 then
        f_coin:set_value((n >= COIN and n < COIN + 6) and 1 or 0)
        f_start:set_value((n >= COIN + 90 and n < COIN + 96) and 1 or 0)
        f_b1:set_value(((n >= COIN + 1200 and n < COIN + 1206) or (n > COIN + 2400 and n % 30 < 4)) and 1 or 0)
        f_right:set_value((n > COIN + 2400 and n % 200 < 120) and 1 or 0)
    end
    local hits = {}
    for e = 0, 511 do
        local w0 = prog:read_u32(0x40c000 + e * 8)
        local w1 = prog:read_u32(0x40c000 + e * 8 + 4)
        local attr = w1 & 0xffff
        if (attr & 0xff00) == 0xff00 then break end
        if attr & 0x2000 ~= 0 then
            local x = ((w0 >> 16) & 0x1ff) + 8 - 50
            local y = (w0 & 0xffff) - 16
            local w = ((attr >> 8) & 0xf) + 1
            if x < 380 and x + 16 * w > 0 and y < 224 and y + 16 > 0 then
                hits[#hits + 1] = string.format("%d,%d,%d,%d", e, x, y, w)
                log:write(string.format("spr frame %d entry %d x %d y %d width %d tile %04x attr %04x\n",
                                        n, e, x, y, w, (w1 >> 16) & 0xffff, attr))
            end
        end
    end
    if #hits > 0 and snaps < SNAPS and n % 600 == 0 then
        scr:snapshot(string.format("%s/f%05d.png", OUT, n))
        log:write(string.format("snap frame %d boxes %s\n", n, table.concat(hits, ";")))
        snaps = snaps + 1
    end
    if n >= FRAMES then
        log:close()
        print("B13_OK")
        m:exit()
    end
end)
