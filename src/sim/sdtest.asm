; sdtest.asm: a test of the DivMMC SPI with an SD card, in the place of the ESXDOS ROM (src/sim, SDTEST=1).
; Automap at 0000 runs it from 0001 (the DI at 0000 comes from the Spectrum ROM). It does what a card driver
; does and keeps every answer in RAM (page 2, 9000..): 8 bytes after each command, then 256 bytes after CMD17.
; At the end 9200 = A5. tb_pentagon prints the bytes.
	device zxspectrum48
	org 0
	di
	ld sp,0x8000
	ld a,0xff
	out (0xe7),a		; card deselected
	ld b,10
dummy:	ld a,0xff
	out (0xeb),a		; 80 clocks
	djnz dummy
	ld a,0xfe
	out (0xe7),a		; card 0 selected
	ld hl,cmd0
	ld de,0x9000
	call cmd
	ld hl,cmd8
	ld de,0x9010
	call cmd
	ld hl,cmd55
	ld de,0x9020
	call cmd
	ld hl,acmd41
	ld de,0x9030
	call cmd
	ld hl,cmd58
	ld de,0x9040
	call cmd
	ld hl,cmd17
	ld de,0x9050
	call cmd
	ld hl,0x9060
	ld b,0
rd:	in a,(0xeb)		; the token and the sector
	ld (hl),a
	inc hl
	djnz rd
	ld a,0xa5
	ld (0x9200),a
	jr $

cmd:	ld b,6
c1:	ld a,(hl)
	out (0xeb),a
	inc hl
	djnz c1
	ld b,8
c2:	in a,(0xeb)
	ld (de),a
	inc de
	djnz c2
	ret

cmd0:	db 0x40,0,0,0,0,0x95
cmd8:	db 0x48,0,0,1,0xaa,0x87
cmd55:	db 0x77,0,0,0,0,0x65
acmd41:	db 0x69,0x40,0,0,0,0x77
cmd58:	db 0x7a,0,0,0,0,0xfd
cmd17:	db 0x51,0,0,0,0,0xff
	savebin "work/sdtest.bin",0,8192
