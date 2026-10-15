#!/usr/bin/env python3
"""Generate the Lucero Sync extension icons (standard library only).

Draws the logo -- a four-pointed amber star on a dark rounded square with a
small cream centre dot -- by supersampling a 64x64 vector description and
writing PNGs with a minimal zlib-based encoder.

Usage: python3 tools/make_icons.py   (writes src/icons/icon-{16,32,48,128}.png)
"""
import os
import struct
import zlib

BG = (0x10, 0x0D, 0x0A)
STAR = (0xFF, 0xA2, 0x4A)
DOT = (0xFF, 0xF4, 0xE4)

# Star path in a 64x64 viewBox.
STAR_PTS = [(32, 6), (36.6, 27.4), (58, 32), (36.6, 36.6), (32, 58),
            (27.4, 36.6), (6, 32), (27.4, 27.4)]
CORNER = 14.0   # rounded-square corner radius (viewBox units)
DOT_R = 3.2     # centre dot radius
SS = 4          # supersampling factor per axis


def in_rounded_square(x, y):
    r = CORNER
    cx = min(max(x, r), 64 - r)
    cy = min(max(y, r), 64 - r)
    return 0 <= x <= 64 and 0 <= y <= 64 and (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def in_polygon(x, y, pts):
    inside = False
    n = len(pts)
    j = n - 1
    for i in range(n):
        xi, yi = pts[i]
        xj, yj = pts[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def sample(x, y):
    """Return (r, g, b, a) for a point in viewBox space."""
    if not in_rounded_square(x, y):
        return (0, 0, 0, 0)
    if (x - 32) ** 2 + (y - 32) ** 2 <= DOT_R ** 2:
        return DOT + (255,)
    if in_polygon(x, y, STAR_PTS):
        return STAR + (255,)
    return BG + (255,)


def render(size):
    rows = []
    scale = 64.0 / size
    for py in range(size):
        row = bytearray([0])  # filter type: none
        for px in range(size):
            acc = [0, 0, 0, 0]
            for sy in range(SS):
                for sx in range(SS):
                    x = (px + (sx + 0.5) / SS) * scale
                    y = (py + (sy + 0.5) / SS) * scale
                    r, g, b, a = sample(x, y)
                    acc[0] += r * a
                    acc[1] += g * a
                    acc[2] += b * a
                    acc[3] += a
            n = SS * SS
            a = acc[3] / n
            if acc[3]:
                rgb = [round(c / acc[3]) for c in acc[:3]]
            else:
                rgb = [0, 0, 0]
            row.extend(rgb + [round(a)])
        rows.append(bytes(row))
    return b"".join(rows)


def png(size, raw):
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)  # 8-bit RGBA
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "..", "src", "icons")
    os.makedirs(out, exist_ok=True)
    for size in (16, 32, 48, 128):
        path = os.path.join(out, "icon-%d.png" % size)
        with open(path, "wb") as f:
            f.write(png(size, render(size)))
        print("wrote", os.path.normpath(path))


if __name__ == "__main__":
    main()
