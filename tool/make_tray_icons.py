"""Renders the tray icons (the four-pointed star) without any image libraries.

    python3 tool/make_tray_icons.py

assets/tray/tray_template.png  macOS menu bar template: black star, see-through centre
assets/tray/tray.png           Windows / Linux: amber star with a cream centre
"""
import struct, zlib, os

STAR = [(32, 6), (36.6, 27.4), (58, 32), (36.6, 36.6), (32, 58), (27.4, 36.6), (6, 32), (27.4, 27.4)]

def inside(poly, x, y):
    c = False
    j = len(poly) - 1
    for i in range(len(poly)):
        xi, yi = poly[i]; xj, yj = poly[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            c = not c
        j = i
    return c

def render(size, star_rgb, dot_rgb, pad=2.0, ss=4):
    scale = (64 - 2 * pad) / 64
    rows = []
    for py in range(size):
        row = bytearray([0])
        for px in range(size):
            star = dot = 0
            for sy in range(ss):
                for sx in range(ss):
                    x = ((px + (sx + .5) / ss) / size * 64 - 32) / scale + 32
                    y = ((py + (sy + .5) / ss) / size * 64 - 32) / scale + 32
                    if (x - 32) ** 2 + (y - 32) ** 2 <= 4.5 ** 2:
                        dot += 1
                    elif inside(STAR, x, y):
                        star += 1
            n = ss * ss
            if dot_rgb is None:
                a = star / n
                rgb = star_rgb
            else:
                a = (star + dot) / n
                rgb = tuple(round((s * star + d * dot) / max(star + dot, 1)) for s, d in zip(star_rgb, dot_rgb))
            row += bytes(rgb) + bytes([round(a * 255)])
        rows.append(bytes(row))
    raw = b''.join(rows)
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0)) + \
        chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')

out = os.path.join(os.path.dirname(__file__), '..', 'assets', 'tray')
os.makedirs(out, exist_ok=True)
open(os.path.join(out, 'tray_template.png'), 'wb').write(render(44, (0, 0, 0), None, pad=4))
open(os.path.join(out, 'tray.png'), 'wb').write(render(64, (0xff, 0xa2, 0x4a), (0xff, 0xf4, 0xe4)))
print('wrote', out)
