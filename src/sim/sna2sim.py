#!/usr/bin/env python3
# sna2sim.py - a 128K .sna for tb_pentagon (run_sim.sh SNA=<file>): the RAM pages 0..7 as $readmemh words of the
# SDRAM model (page p at byte p * 16 KB of the bank) and a ROM 0 that restores the registers and jumps to the PC.
#   sna2sim.py game.sna ram.hex rom0.bin
import struct, sys

d = open(sys.argv[1], 'rb').read()
assert len(d) in (131103, 147487), 'a 128K snapshot'
h = d[:27]
i_reg = h[0]
hl_, de_, bc_, af_, hl, de, bc, iy, ix = struct.unpack('<9H', h[1:19])
iff2 = h[19] & 4
af, sp = struct.unpack('<HH', h[21:25])
im, border = h[25], h[26] & 7
pc, p7ffd = struct.unpack('<HB', d[49179:49182])
n = p7ffd & 7
pages = {5: d[27:27 + 16384], 2: d[27 + 16384:27 + 32768], n: d[27 + 32768:27 + 49152]}
off = 49183
for p in (0, 1, 3, 4, 6, 7):
    if p != n:
        pages[p] = d[off:off + 16384]
        off += 16384
ram = b''.join(pages[p] for p in range(8))
with open(sys.argv[2], 'w') as f:
    for k in range(0, len(ram), 2):
        f.write('%04x\n' % (ram[k] | ram[k + 1] << 8))

# the loader: DI, #7FFD, border, I, IM, the registers from a table by POPs, SP, EI if IFF2, JP PC
w = lambda v: [v & 255, v >> 8]
code = [0xF3,                                           # di
        0x01, 0xFD, 0x7F, 0x3E, p7ffd, 0xED, 0x79,      # ld bc,#7ffd: ld a,p: out (c),a
        0x3E, border, 0xD3, 0xFE,                       # ld a,border: out (#fe),a
        0x3E, i_reg, 0xED, 0x47,                        # ld a,i: ld i,a
        0xED, [0x46, 0x56, 0x5E][im],                   # im n
        0x31] + w(0x100)                                # ld sp,table
code += [0xE1, 0xD1, 0xC1, 0xF1, 0xD9, 0x08,             # pop hl,de,bc,af: exx: ex af,af'
         0xE1, 0xD1, 0xC1, 0xDD, 0xE1, 0xFD, 0xE1, 0xF1, # pop hl,de,bc,ix,iy,af
         0x31] + w(sp)                                  # ld sp,sp
code += ([0xFB] if iff2 else []) + [0xC3] + w(pc)     # ei: jp pc
rom = bytearray(b'\xff' * 16384)
rom[0:len(code)] = bytes(code)
table = w(hl_) + w(de_) + w(bc_) + w(af_) + w(hl) + w(de) + w(bc) + w(ix) + w(iy) + w(af)
rom[0x100:0x100 + len(table)] = bytes(table)
open(sys.argv[3], 'wb').write(rom)
print('sna2sim: pc %04x sp %04x im %d iff2 %d 7ffd %02x border %d' % (pc, sp, im, iff2 >> 2, p7ffd, border))
