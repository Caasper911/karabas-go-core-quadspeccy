#!/usr/bin/env python3
# mkfat.py - a small SD card image for the simulation (tb_pentagon SDIMG=1): 8 MB, MBR with one FAT16 partition, the
# given directories / files in its root (8.3 names, upper case), written as $readmemh text of its non-zero bytes
# (@ byte address lines) for the image model of tb_pentagon.
#   mkfat.py out.hex SRC [SRC ...]: SRC a directory (copied with its tree) or a file, NAME=PATH to rename a file
import os, struct, sys

SECTORS = 16384                 # 8 MB
PART = 32                       # first sector of the partition
SPC = 2                         # sectors per cluster (1 KB): > 4085 clusters, FAT16
RSV = 4
NFAT = 2
ROOT_ENT = 512
psec = SECTORS - PART
root_secs = ROOT_ENT * 32 // 512
fat_secs = 32
data0 = RSV + NFAT * fat_secs + root_secs           # data region, sector in the partition
nclus = (psec - data0) // SPC
assert 4085 <= nclus < 65525 and (nclus + 2) * 2 <= fat_secs * 512

img = bytearray(SECTORS * 512)
fat = [0xFFF8, 0xFFFF]
next_clus = 2

def alloc(data):
    """clusters for data, its first cluster (0 for none)"""
    global next_clus
    n = (len(data) + SPC * 512 - 1) // (SPC * 512)
    if n == 0:
        return 0
    first = next_clus
    for i in range(n):
        c = next_clus
        next_clus += 1
        fat.append(next_clus if i < n - 1 else 0xFFFF)
        off = (PART + data0 + (c - 2) * SPC) * 512
        chunk = data[i * SPC * 512:(i + 1) * SPC * 512]
        img[off:off + len(chunk)] = chunk
    return first

def name83(n):
    n = n.upper()
    base, _, ext = n.partition('.')
    assert len(base) <= 8 and len(ext) <= 3, n
    return (base.ljust(8) + ext.ljust(3)).encode('ascii')

def entry(name, attr, clus, size):
    return name83(name) + struct.pack('<BBBHHHHHHHI', attr, 0, 0, 0, 0x5A21, 0x5A21, 0, 0, 0x5A21, clus, size)

def dir_data(items, self_clus, parent_clus):
    """items: list of (name, path); a subdirectory gets . and .."""
    ents = []
    if self_clus is not None:
        ents.append(b'.          ' + struct.pack('<BBBHHHHHHHI', 0x10, 0, 0, 0, 0x5A21, 0x5A21, 0, 0, 0x5A21, self_clus, 0))
        ents.append(b'..         ' + struct.pack('<BBBHHHHHHHI', 0x10, 0, 0, 0, 0x5A21, 0x5A21, 0, 0, 0x5A21, parent_clus, 0))
    for name, path in items:
        if os.path.isdir(path):
            ents.append(('dir', name, path))
        else:
            data = open(path, 'rb').read()
            ents.append(entry(name, 0x20, alloc(data), len(data)))
    return ents

def make_dir(path, parent_clus):
    """a subdirectory: its cluster"""
    items = [(n, os.path.join(path, n)) for n in sorted(os.listdir(path))]
    # the directory takes one cluster per 32 entries (SPC 2: 32 entries a cluster), reserve them first
    n_ent = len(items) + 2
    n_cl = (n_ent * 32 + SPC * 512 - 1) // (SPC * 512)
    global next_clus
    first = next_clus
    for i in range(n_cl):
        next_clus += 1
        fat.append(first + i + 1 if i < n_cl - 1 else 0xFFFF)
    ents = dir_data(items, first, parent_clus)
    raw = bytearray()
    for e in ents:
        if isinstance(e, tuple):
            _, name, p = e
            raw += entry(name, 0x10, make_dir(p, first), 0)
        else:
            raw += e
    raw = raw.ljust(n_cl * SPC * 512, b'\0')
    for i in range(n_cl):
        off = (PART + data0 + (first + i - 2) * SPC) * 512
        img[off:off + SPC * 512] = raw[i * SPC * 512:(i + 1) * SPC * 512]
    return first

items = []
for a in sys.argv[2:]:
    if '=' in a:
        n, p = a.split('=', 1)
    else:
        p = a
        n = os.path.basename(a.rstrip('/\\'))
    items.append((n, p))
root = bytearray()
for e in dir_data(items, None, None):
    if isinstance(e, tuple):
        _, name, p = e
        root += entry(name, 0x10, make_dir(p, 0), 0)
    else:
        root += e
root = name83('SIMCARD') + bytes([0x08]) + bytes(20) + root     # volume label first
assert len(root) <= ROOT_ENT * 32

# MBR
mbr = bytearray(512)
mbr[446:462] = struct.pack('<B3sB3sII', 0x00, b'\xfe\xff\xff', 0x06, b'\xfe\xff\xff', PART, psec)
mbr[510:512] = b'\x55\xaa'
img[0:512] = mbr
# boot sector (BPB)
bs = bytearray(512)
bs[0:3] = b'\xeb\x3c\x90'
bs[3:11] = b'MSWIN4.1'
struct.pack_into('<HBHBHHBHHHII', bs, 11, 512, SPC, RSV, NFAT, ROOT_ENT, 0, 0xF8, fat_secs, 63, 255, PART, psec)
struct.pack_into('<BBBI11s8s', bs, 36, 0x80, 0, 0x29, 0x12345678, b'SIMCARD    ', b'FAT16   ')
bs[510:512] = b'\x55\xaa'
p0 = PART * 512
img[p0:p0 + 512] = bs
fat_raw = b''.join(struct.pack('<H', x) for x in fat).ljust(fat_secs * 512, b'\0')
for k in range(NFAT):
    off = (PART + RSV + k * fat_secs) * 512
    img[off:off + len(fat_raw)] = fat_raw
off = (PART + RSV + NFAT * fat_secs) * 512
img[off:off + len(root)] = root

with open(sys.argv[1], 'w') as f:
    last = -2
    for i, b in enumerate(img):
        if b:
            if i != last + 1:
                f.write('@%x\n' % i)
            f.write('%02x\n' % b)
            last = i
print('mkfat: %d clusters used of %d' % (next_clus - 2, nclus))
