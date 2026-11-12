; im2test.asm: IM 2 in the place of the ESXDOS ROM (src/sim, TESTROM=im2test). I = 80, the table 8000..8100 = 81,
; the handler at 8181 counts the interrupts in 9000/9001 and keeps the low byte of the vector it got (the byte the CPU
; read in the interrupt acknowledge) in 9002 from its return address on the stack... simpler: it only counts; the
; testbench prints the data bus of each acknowledge cycle.
	device zxspectrum48
	org 0
	di
	ld sp,0x7f00
	ld hl,0x8000
	ld de,0x8001
	ld bc,0x100
	ld (hl),0x81
	ldir			; the vector table
	ld hl,handler
	ld de,0x8181
	ld bc,hend-handler
	ldir			; the handler at 8181
	ld hl,0
	ld (0x9000),hl
	ld a,0x80
	ld i,a
	im 2
	ei
loop:	jr loop			; in the DivMMC ROM (mapped): automap stays, 1FF8 is never fetched
handler:
	push hl
	ld hl,(0x9000)
	inc hl
	ld (0x9000),hl
	pop hl
	ei
	reti
hend:
	savebin "work/im2test.bin",0,8192
