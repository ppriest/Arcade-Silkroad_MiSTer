; silkroad_core end-to-end video-path exercise: assembled with vasm
; (vasmm68k_mot -m68020 -Fbin), same convention as
; sim/maincpu_tb/test_maincpu.s (see that file's header for why hand-encoded
; opcodes are avoided in this project).
;
; org $8 -- reset vectors (initial SP/PC) are supplied directly by the
; testbench's ROM preload, not by this file, same convention as
; test_maincpu.s.
;
; Writes just enough to put ONE known, non-transparent pixel on screen at
; tilemap layer 0's origin tile (VRAM cell 0, screen grid col=0/row=0 --
; both tilemap sizes map col=0,row=0 to VRAM index 0): tile code 0 / color 0
; in VRAM cell 0, a distinctive palette entry at the resulting pal_addr
; (0x800 -- rtl/video/compositor.sv: 0x800 + color*16 + pixel, both 0 here),
; and layer 0's control word (bank 0, 64x64). Layer 0 is opaque, so the
; all-zero gfx ROM stub's pen 0 is drawn. Scroll registers are left at their
; post-reset zero default.

        org     $8

start:
        ; layer 0 VRAM cell 0: tile code 0, color 0.
        move.w  #$0000,d0
        move.w  d0,$800000.l

        ; palette entry 0x03F -- distinctive test value: an all-zero gfx ROM inverts to pen 63,
        ; colour 0. silkroad's palette is the upper word of each long (silkroad.cpp:318), so
        ; entry 0x03F is byte 0x6000FC. No 68k assembler is installed here: the .bin/.hex
        ; fixtures were DreamWorld's, patched from $601000.
        move.w  #$1234,d1
        move.w  d1,$6000FC.l

        ; layer 0 control word (byte 0x804412): bit0=enable, bit3=0 (pen 15
        ; transparent), mode bits 7:6=00 (mode doesn't matter here).
        move.w  #$0001,d2
        move.w  d2,$804412.l

done:
        bra.s   done
