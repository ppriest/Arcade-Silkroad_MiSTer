-- Snapshot every frame in [CORE_FROM, CORE_TO] to CORE_OUT/fNNNNN.png, then exit. Driven by
-- scripts/hw_vs_mame.py through run.lua. The snapshot is MAME's rendering of the screen, as
-- mame_capture.py's reference.png (a ROT90/ROT270 set comes out turned 180 degrees).
local OUT  = os.getenv("CORE_OUT")
local FROM = tonumber(os.getenv("CORE_FROM") or "0")
local TO   = tonumber(os.getenv("CORE_TO") or "0")
local scr  = manager.machine.screens[":screen"]
core_snap_sub = emu.add_machine_frame_notifier(function()
    local n = scr:frame_number()
    if n >= FROM and n <= TO then scr:snapshot(string.format("%s/f%05d.png", OUT, n)) end
    if n > TO then
        print("CORE_SNAP_OK")
        manager.machine:exit()
    end
end)
