# Hacks, approximations and workarounds in this core

Everything in this core's own RTL, scripts or `.mra` layout that is known not to be what the
hardware does: a stand-in, a shortcut, a value chosen to make something work, a workaround for a
tool. Each entry is added in the commit that introduces the hack and removed in the commit that
removes it.

This is not `MAME_KLUDGES.md`. That file lists MAME's own guesses that the core reproduces on
purpose because MAME is the reference. This file lists what is ours.

Rules:

- An entry cites `file:line` (or a module and signal name if the line moves often), and the
  evidence column says what was measured, or "unverified".
- "What would make it correct" names the work, not "fix later".
- A hack whose entry is missing is a bug. A hack whose entry is stale is worse: update it in the
  same commit as the code.
- Severity is what a player or a verifier would see: **visible** (wrong pixels, wrong sound, wrong
  timing a game can hit), **latent** (wrong only for input no in-scope set produces), **tooling**
  (affects the build or the bench, not the bitstream).

| What | Where | Why it is a hack | What would make it correct | Evidence | Severity |
|---|---|---|---|---|---|
| 68020 sprite RAM writes held during the snapshot copy | `rtl/cpu/maincpu.sv` `spr_hold`; `rtl/video/silkroad_spriteram.sv` | silkroad.cpp has no copy (live RAM, 186); the core copies at line 248, 2048 clk, after the game's last write (`docs/write_timing_mame.txt`), and a write during it waits | Nothing on the board is known; equivalent to MAME while the game never writes sprite RAM after line 248 | the sweep: no write after MAME line 250 in 4200 frames | latent |
| Tile VRAM, palette and scroll read live, as each line renders | `rtl/video/silkroad_tilemaps.sv`, the compositor in `rtl/silkroad_core.sv` | MAME draws the whole frame at vblank start; a write during the visible area shows from the next rendered line down here, from the next frame in MAME. silkroad writes tile VRAM and some palette entries during the visible area (`docs/write_timing_mame.txt`) | Queue the writes and apply them at vblank start | not yet measured on hardware; the frame bench loads a still state | visible |
| Each OKI mixed at x 7 where MAME's 0.45 is x 7.2 | `rtl/sound/silkroad_sound.sv` `oki_x7` | A shift and a subtract in place of a multiply; the OKIs are 2.8% quieter against the YM2151 than in MAME | x 7.2 by shift-and-add terms (x 7 + x 0.2 = x 7 + x/8 + x/16 + ...), if the level difference is heard | arithmetic; the mix not yet compared with MAME's | visible (audio level) |
| Pixel clock 8 MHz (32 MHz / 4), H total 512, V total 262 | `rtl/video/video_timing.sv` `H_TOTAL`/`V_TOTAL`; `Silkroad.sv` `ce_pix` | silkroad.cpp has no raw timing: 60 Hz, a 512 x 256 bitmap, 380 x 224 visible (451-454). 8 MHz is the 32 MHz crystal / 4; 512 is MAME's bitmap width; 262 the usual line count nearest 60 Hz at 15.625 kHz | A PCB measurement of H and V sync frequency | 59.637 Hz against MAME's 60 Hz (-0.6%), 15.625 kHz; unverified | visible |
| Sync pulse widths and positions | `rtl/video/video_timing.sv` `H_SYNC_*`, `V_SYNC_*` | 38-pixel (4.75 us) hsync from hcnt 420, 3-line vsync 8 lines into vblank: chosen, MAME has none | A PCB measurement of the sync timing | unverified | visible (analog only) |
| SDRAM_CLK 252 degrees (7292 ps) at 96 MHz | `rtl/pll/pll_0002.v` `phase_shift2` | Carries the 3.125 ns lead of SDRAM_CLK over the controller's clock that the 48 MHz builds ran with (DreamWorld's, estimated from two overlay captures at 54 MHz) to 96 MHz | A phase sweep on hardware: read margin at several shifts | not measured at 96 MHz | visible if wrong |

<!-- Examples of the shape, from sibling cores:
| Sound mailbox is a stub that answers the power-on test | `rtl/gx_snd_stub.sv` | No sound CPU yet; the stub returns the reply the test expects and a heartbeat | Phase 3: the real sound board | The game's RAM check passes with it; nothing else is exercised | visible |
| Sound-command spin of 800 CPU clocks after a latch write | `rtl/cpu/…_bus.sv:NNN` | Copies MAME's 40 us wait; the real board's mechanism is unknown | A measurement of the latch on hardware | Without it the second byte overwrote the first (commit) | latent |
| Sound CPU reset held 1,024 clocks | `rtl/….sv:NNN` | MAME's pulse is zero-length; the T80 needs to see it | The measured reset length | A PCB measurement says about one second | latent |
| Screen timing from one game used for every game | `rtl/video/…crtc.sv` | MAME declares 60 Hz with no comment; the one PCB-verified rate is used for all | Per-game timing from PCB measurement | 0.043% from the verified rate | visible |
-->

## Removed

Entries move here when the hack is gone, with the commit that removed it, so a later reader can
tell "never had it" from "had it and fixed it". Delete a row once nothing else refers to it.

| What | Removed by | Replaced with |
|---|---|---|
| YM2151 status read as 0x00 (never busy) | the Phase 4 sound commit | jt51's status (`rtl/sound/silkroad_sound.sv`) |
| Sprite LUT answered as identity; tiles and sprites drawn as 4 bpp from region A | the Phase 2 video commit | `silkroad_tilemaps`, `silkroad_sprites`: 6 bpp from regions A and B, no LUT |
