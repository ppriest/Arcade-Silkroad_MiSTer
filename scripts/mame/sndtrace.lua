-- Every write to the sound chips, with the machine time, for scripts/snd_trace.py. silkroad.cpp
-- (324-327): OKI 1 at 0xC00025, the YM2151 at 0xC00029 (address) and 0xC0002D (data), OKI 2 at
-- 0xC00031, OKI 1's bank at 0xC00034 -- byte handlers on the 68020's 32-bit bus. One line per
-- write: "seconds offset data mask", the tap's 32-bit-aligned offset and lanes. Run through
-- run.lua; stops after CORE_SECONDS.
local OUT  = os.getenv("CORE_OUT")
local SECS = tonumber(os.getenv("CORE_SECONDS") or "20")
local COIN = tonumber(os.getenv("CORE_COIN") or "0")
local m    = manager.machine
local sp   = m.devices[":maincpu"].spaces["program"]
local f    = assert(io.open(OUT .. "/sndtrace.txt", "w"))

core_snd_tap = sp:install_write_tap(0xc00024, 0xc00037, "snd", function(offset, data, mask)
    f:write(string.format("%.9f %06x %08x %08x\n", m.time:as_double(), offset, data, mask))
end)

local function field(name)
    for _, port in pairs(m.ioport.ports) do
        if port.fields[name] then return port.fields[name] end
    end
end
local f_coin, f_start = field("Coin 1"), field("1 Player Start")
core_snd_frame = emu.add_machine_frame_notifier(function()
    local n = m.screens[":screen"]:frame_number()
    if COIN > 0 then
        f_coin:set_value((n >= COIN and n < COIN + 6) and 1 or 0)
        f_start:set_value((n >= COIN + 90 and n < COIN + 96) and 1 or 0)
    end
    if m.time:as_double() >= SECS then
        f:close()
        print("CORE_SNDTRACE_OK")
        m:exit()
    end
end)
