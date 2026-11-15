"""render_raster.py raster.hex out.png: the whole Pentagon raster of tb_pentagon (BRD_TRACE), 448 x 320, each pixel
2 x 2; line 0 the first of the paper, x 0 its first pixel (the left border is at x 384..447 of the line before)."""
import sys, zlib, struct
v = [int(l.replace("x", "0"), 16) for l in open(sys.argv[1]) if l.strip()]
W, H = 448, 320
def rgb(c):
    k = 0xFF if c & 8 else 0xC0
    return (k if c & 2 else 0, k if c & 4 else 0, k if c & 1 else 0)
rows = []
for y in range(H):
    line = b''.join(bytes(rgb(v[y * W + x])) * 2 for x in range(W))
    rows += [line, line]
raw = b''.join(b'\0' + r for r in rows)
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
open(sys.argv[2], 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', W * 2, H * 2, 8, 2, 0, 0, 0))
    + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))
