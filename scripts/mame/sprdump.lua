-- SPDX-License-Identifier: GPL-3.0-or-later
-- Dump the drawn half of sprite RAM every frame, for scripts/sprite_load.py.
--
--   CORE_CPU, CORE_SPACE  the CPU and address space (regions.json)
--   SD_OUT     output file: FRAMES records of SD_LEN bytes, big-endian longs
--   SD_BASE    hex start address of the dump
--   SD_LEN     bytes per frame
--   SD_SKIP    frames to run before dumping (boot)
--   SD_FRAMES  frames to dump
--   SD_COIN    frame to insert a coin and press Start (0 = attract only); from
--              Start, HOLD is held and PULSE pulsed, so play goes on
--   SD_IN_COIN/START/HOLD/PULSE  input field names (regions.json "inputs")
--
-- frame_done runs at vblank start, after the frame is drawn and before the game
-- writes the next list: the RAM read here is the list the frame just drawn used.

local OUT    = os.getenv("SD_OUT")
local BASE   = tonumber(os.getenv("SD_BASE") or "40c000", 16)
local LEN    = tonumber(os.getenv("SD_LEN") or "4096")
local SKIP   = tonumber(os.getenv("SD_SKIP") or "600")
local FRAMES = tonumber(os.getenv("SD_FRAMES") or "1800")
local COIN   = tonumber(os.getenv("SD_COIN") or "0")

local mach = manager.machine
local cpu  = mach.devices[os.getenv("CORE_CPU") or ":maincpu"]
local prog = cpu.spaces[os.getenv("CORE_SPACE") or "program"]

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
    return nil
end
local f_coin, f_start = field(os.getenv("SD_IN_COIN") or "Coin 1"), field(os.getenv("SD_IN_START") or "1 Player Start")
local f_right, f_b1 = field(os.getenv("SD_IN_HOLD") or "P1 Right"), field(os.getenv("SD_IN_PULSE") or "P1 Button 1")

local out = assert(io.open(OUT, "wb"))
local n = 0
emu.register_frame_done(function()
    n = n + 1
    if COIN > 0 and f_coin and f_start then
        f_coin:set_value((n >= COIN and n < COIN + 6) and 1 or 0)
        f_start:set_value((n >= COIN + 90 and n < COIN + 96) and 1 or 0)
        if n >= COIN + 96 then
            if f_right then f_right:set_value(1) end
            if f_b1 then f_b1:set_value((n % 20) < 4 and 1 or 0) end
        end
    end
    if n > SKIP and n <= SKIP + FRAMES then
        local parts = {}
        for a = BASE, BASE + LEN - 4, 4 do
            parts[#parts + 1] = string.pack(">I4", prog:read_u32(a))
        end
        out:write(table.concat(parts))
    end
    if n == SKIP + FRAMES then
        out:close()
        mach.video:snapshot()
        mach:exit()
    end
end)
