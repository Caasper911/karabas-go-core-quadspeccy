; trtest.asm: TR-DOS paging and the ports of the Beta Disk (run_sim.sh TRDOS=1). ROM 0 is this program, ROM 2 (the
; TR-DOS slot) the code at 3D00 below, the rest AA. From RAM: ROM 48 on (#7FFD bit 4), CALL 3D00: the fetch at 3D00
; maps the TR-DOS ROM; there IN (#1F) is the controller (the testbench answers 5A) -> 9000, (0) the TR-DOS ROM (AA) ->
; 9003; back in RAM TR-DOS is off: IN (#1F) Kempston (00) -> 9001, (0) BASIC 48 (F3) -> 9002; 77 -> 9004 at the end.
	device zxspectrum48
	org 0
	di
	ld sp,0x7f00
	ld hl,stub
	ld de,0x8000
	ld bc,stub_end-stub
	ldir
	jp 0x8000
stub:
	disp 0x8000
	ld a,0x10
	ld bc,0x7ffd
	out (c),a
	call 0x3d00
	in a,(0x1f)
	ld (0x9001),a
	ld a,(0)
	ld (0x9002),a
	ld a,0x77
	ld (0x9004),a
loop:	jr loop
	ent
stub_end:
	savebin "work/trtest0.bin",0,16384

	org 0x4000
	block 0x3d00,0xaa
	disp 0x3d00
	ld a,0x01
	ld (0x9010),a	; a store of 01: the data bus of the CPU holds 01 before the OUT
	ld a,0x3c
	out (0xff),a	; the system port: every clock of the write must see 3C (/MR = 1)
	in a,(0x1f)
	ld (0x9000),a	; (the testbench's 5A without the controller; with it the status)
w0:	in a,(0xff)
	and 0x80
	jr z,w0		; INTRQ of the RESTORE the VG93 makes itself when /MR goes high (03, no head load)
	ld a,0x08
	out (0x1f),a	; RESTORE, head load: the drive steps to track 0
	ld b,0
w1:	djnz w1		; the command is taken within two microwords
wi:	in a,(0xff)
	and 0x80
	jr z,wi		; INTRQ
	in a,(0x1f)
	ld (0x9005),a	; the status
	ld a,0x11
	out (0x5f),a	; the sector register, then at once
	ld a,0x22
	out (0x3f),a	; the track register: the controller holds the CPU (WAIT) after a write, or this write is lost
	in a,(0x5f)
	ld (0x9006),a
	in a,(0x3f)
	ld (0x9007),a
	in a,(0x1f)
	ld (0x9000),a
	ld a,(0)
	ld (0x9003),a
	ret
	ent
	savebin "work/trtest2.bin",0x4000,16384
