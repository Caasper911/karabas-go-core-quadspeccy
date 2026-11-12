"""render_screen.py screen5.hex screen7.hex out.png: the two ZX screens ($writememh of 16-bit words of the SDRAM
model, src/sim) side by side as a PNG (256 x 192 each, attributes without flash). No libraries."""
import struct
import sys
import zlib

PAL = [(0, 0, 0), (0, 0, 0xCA), (0xCA, 0, 0), (0xCA, 0, 0xCA), (0, 0xCA, 0), (0, 0xCA, 0xCA), (0xCA, 0xCA, 0),
       (0xCA, 0xCA, 0xCA)]


def load(path):
    words = []
    for line in open(path):
        line = line.split("//")[0].strip()
        if line and not line.startswith("@"):
            words.append(int(line, 16))
    data = bytearray()
    for w in words:
        data += bytes((w & 0xFF, w >> 8))
    return data


def pixels(scr):
    rows = []
    for y in range(192):
        row = []
        for x in range(256):
            b = scr[((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2) | (x >> 3)]
            a = scr[0x1800 + (y >> 3) * 32 + (x >> 3)]
            ink = (b >> (7 - (x & 7))) & 1
            c = (a & 7) if ink else ((a >> 3) & 7)
            col = PAL[c]
            if a & 0x40:
                col = tuple(0xFF if v else 0 for v in col)
            row.append(col)
        rows.append(row)
    return rows


def png(path, rows):
    h, w = len(rows), len(rows[0])
    raw = b"".join(b"\0" + b"".join(bytes(p) for p in r) for r in rows)

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
                chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


a = pixels(load(sys.argv[1]))
b = pixels(load(sys.argv[2]))
gap = [(0x40, 0x40, 0x40)] * 8
png(sys.argv[3], [ra + gap + rb for ra, rb in zip(a, b)])
