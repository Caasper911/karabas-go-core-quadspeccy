; memtest.asm: the 1024 KB RAM of Profi (port #DFFD 2..0) as ROM 0 (run_sim.sh MEMTEST=1, DivMMC off). Each of the
; 64 pages gets its marker in C000, then all are read back. Results in page 2: 9000 the pages with a wrong marker (0),
; 9001 77 at the end. Bits 7..3 of #DFFD are written as 1 (ignored).
; Marker of page p: p xor 5A at offset 3F00 (FF00 in C000).
	device zxspectrum48
	org 0
	di
	ld sp,0x9f00
	ld e,0
wl:	call setpage
	ld a,e
	xor 0x5a
	ld (0xff00),a
	inc e
	ld a,e
	cp 64
	jr nz,wl
	ld e,0
	ld d,0
rl:	call setpage
	ld a,e
	xor 0x5a
	ld b,a
	ld a,(0xff00)
	cp b
	jr z,rok
	inc d
rok:	inc e
	ld a,e
	cp 64
	jr nz,rl
	ld a,d
	ld (0x9000),a
	ld a,0x77
	ld (0x9001),a
loop:	jr loop
setpage:
	ld a,e
	and 7
	ld bc,0x7ffd
	out (c),a
	ld a,e
	rrca
	rrca
	rrca
	and 7
	or 0xf8			; the other bits of #DFFD are ignored
	ld bc,0xdffd
	out (c),a
	ret
	savebin "work/memtest.bin",0,16384
