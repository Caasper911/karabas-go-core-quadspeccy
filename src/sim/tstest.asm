; tstest.asm: TurboSound in the place of the ESXDOS ROM (src/sim, TESTROM=tstest): selects chip 0 (FF) and chip 1
; (FE) through #FFFD and writes R8 / R7 of each with different values; reads R8 of both back into 9000 / 9001;
; the testbench prints the AY writes of the machine (ay_we: chip, register, data).
	device zxspectrum48
	org 0
	di
	ld sp,0x7f00
	ld bc,0xfffd
	ld a,0xff
	out (c),a		; chip 0
	ld a,8
	out (c),a
	ld b,0xbf
	ld a,0x0a
	out (c),a		; chip 0 R8 = 0A
	ld b,0xff
	ld a,0xfe
	out (c),a		; chip 1
	ld a,8
	out (c),a
	ld b,0xbf
	ld a,0x05
	out (c),a		; chip 1 R8 = 05
	ld b,0xff
	ld a,7
	out (c),a
	ld b,0xbf
	ld a,0x3e
	out (c),a		; chip 1 R7 = 3E
	ld b,0xff
	ld a,0xff
	out (c),a		; chip 0
	ld a,8
	out (c),a
	in a,(c)
	ld (0x9000),a		; chip 0 R8
	ld a,0xfe
	out (c),a		; chip 1
	ld a,8
	out (c),a
	in a,(c)
	ld (0x9001),a		; chip 1 R8
loop:	jr loop
	savebin "work/tstest.bin",0,8192
