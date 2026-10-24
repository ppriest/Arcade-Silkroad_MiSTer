# MAME kludges this core reproduces

This project follows MAME, including where MAME is wrong (ROADMAP, "Design decisions"), so the
software model and the RTL reproduce MAME's guesses on purpose. This file lists each one that
touches an in-scope set: where it is in MAME, what the core does, and what would settle the real
behaviour.

It also records where a vendored, silicon-derived module disagrees with MAME and the module was
kept (ROADMAP, "Where a vendored module and MAME disagree").

This core's own approximations are not here; they are in `HACKS.md`.

Source references are to `src/mame/unico/silkroad.cpp` unless named. MAME commit:
`774a180df2b` (checkout tagged `mame0289`).

**Core column:** *copies* MAME; *differs* (and why); *n/a* (not in the core's scope);
*not checked*.

Both sets are `MACHINE_SUPPORTS_SAVE` only: no imperfect flags (544-545).
<!-- e.g. "Every set is MACHINE_IMPERFECT_GRAPHICS." -->

## Video

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| Screen timing | `silkroad.cpp:451-454`: `set_refresh_hz(60)`, vblank time 0, a 512 x 256 bitmap; no pixel clock | differs: 8 MHz, 512 x 262, 59.637 Hz (`docs/HACKS.md`) | A PCB measurement |
| "Sprites probably need to be delayed" | `silkroad.cpp:186`: sprites drawn from live sprite RAM at `screen_update` | copies, from Phase 2: a snapshot after the game's last sprite write, which pairs each line with the same list | A PCB recording of a fast-moving sprite against the background |
| Sprite priority "1 = Low" | `silkroad.cpp:207`: the comment says 1 is low; the code puts priority 1 above layer 1 | copies the code | — |
| "Is there a bg colour register?" | `silkroad.cpp:189`, `264`: background pen fixed at 0x7C0 | copies, from Phase 2 | `regs[3]`/`regs[4]` values in the sweep, against a scene whose background differs |
| OKI clocks and pin 7 | `silkroad.cpp:466`, `471`: "clock frequency & pin 7 not verified" | copies, from Phase 4 | A PCB measurement, or a recording's pitch |

## Vendored modules that disagree with MAME

| Module | MAME says | The module does | Kept because | Would settle it |
|---|---|---|---|---|
