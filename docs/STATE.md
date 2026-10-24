# Silkroad state inventory

What a savestate or a state dump has to carry, kept current as RTL lands (the skill's
`savestates.md`). "Skip" needs a reason: a ROM table from the `.mra`, or something re-derived
every frame.

## RAMs

| Region | RTL | Width x depth | Bytes | Save? |
|---|---|---|---|---|
| work RAM 0xFE0000 | `silkroad_core` `u_workram` | 16 x 65536 | 128 KB | yes; port A shared with hiscore |
| sprite RAM 0x40C000 | `silkroad_spriteram` `u_live` | 16 x 2048 | 4 KB | yes |
| sprite RAM snapshot and Y table | `silkroad_spriteram` `u_snap`, `u_ytab` | 16 x 2048, 17 x 512 | 5 KB | no: re-copied each frame at line 248 |
| palette 0x600000 | `silkroad_core` `u_palette` | 16 x 4096 | 8 KB | yes |
| VRAM 0 / 1 / 2 | `silkroad_core` `u_vram0`/`u_vram1`/`u_vram2` | 16 x 8192 each | 16 KB each | yes; port B is the engines' (the third has none until Phase 2) |
| tilemap line buffers | `silkroad_tilemaps` `g_lb[0-2]` | 11 x 1024 each | | no: rebuilt every line |
| sprite line buffer and claimed bits | `silkroad_sprites` `u_lb`, `taken` | 13 x 1024, 2 x 512 bits | | no: rebuilt every line |

## Registers and FSMs

| What | RTL | Bits | Save? | MAME `save_item` equivalent |
|---|---|---|---|---|
| video registers, 12 halves | `silkroad_vregs` `r` | 192 | yes; readable through its `dbg` port, no write port yet | `m_regs` (share) |
| OKI 1 bank | `silkroad_sound` | 2 | yes | `m_okibank` |
| vblank IRQ pending | `maincpu` `irq_pending` | 1 | yes | the CPU's IRQ line state |

## Chip state

| Chip | Module | Addressable? | Tier | Note |
|---|---|---|---|---|
| 68EC020 | TG68KdotC_Kernel | no state port | | registers inside the VHDL kernel; the Psikyo and DreamWorld cores have no savestates either |
| M6295 x2 | jt6295 | no | | Phase 4 |
| YM2151 | jt51 (Phase 4) | no | | |

## Deliberately skipped

| What | Why it need not be saved |
|---|---|
| | |

## Frame alignment

Restore point (normally `frame_start`), and anything whose phase must be saved with it: sprite or
tile double-buffer selection, snapshot ownership bits.
