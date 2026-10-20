#!/usr/bin/env python3
"""Render the Healther app icon (1024×1024 PNG) with only the standard library:
a glowing fluid orb on a deep night background, matching the in-app AgentOrb."""
import math, struct, sys, zlib

N = 1024
BG = (5, 8, 16)
PINK, BLUE, LILAC, DEEP_BLUE = (255, 136, 153), (119, 153, 204), (179, 153, 214), (74, 95, 153)

def mix(a, b, t): return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))
def clamp(x): return max(0.0, min(1.0, x))
def smooth(e0, e1, x):
    t = clamp((x - e0) / (e1 - e0)); return t * t * (3 - 2 * t)

def pixel(x, y):
    u, v = (x + 0.5) / N * 2 - 1, (y + 0.5) / N * 2 - 1
    r = math.hypot(u, v)
    # background: faint indigo vignette at top-left, violet bottom-right
    col = mix(BG, DEEP_BLUE, 0.22 * clamp(1 - math.hypot(u + 0.7, v + 0.8) / 1.4))
    col = mix(col, LILAC, 0.12 * clamp(1 - math.hypot(u - 0.8, v - 0.9) / 1.2))
    R = 0.56
    # outer glow
    glow = math.exp(-max(0, r - R) * 7.5) * 0.55
    col = mix(col, mix(PINK, BLUE, clamp((v + 1) / 2)), glow)
    if r <= R:
        # fluid interior: warped gradient field
        w = 0.5 + 0.5 * math.sin(3.0 * u + 2.2 * v + 1.3 * math.sin(4 * v + 3 * u * v))
        w2 = 0.5 + 0.5 * math.sin(-2.4 * u + 3.1 * v + 0.8)
        inner = mix(mix(PINK, BLUE, w), mix(LILAC, DEEP_BLUE, w2), smooth(0.1, 0.9, (u - v + 1) / 2) * 0.75)
        # spherical shading + rim
        z = math.sqrt(max(0.0, R * R - r * r)) / R
        inner = mix(inner, BG, (1 - z) ** 3 * 0.45)
        rim = smooth(R - 0.018, R, r) * 0.5
        inner = mix(inner, (255, 255, 255), rim * 0.4)
        # specular highlight
        hl = math.exp(-((u + 0.02) ** 2 / 0.06 + (v + 0.30) ** 2 / 0.012)) * 0.55
        inner = mix(inner, (255, 255, 255), hl)
        edge = smooth(R, R - 0.004, r)
        col = mix(col, inner, edge)
    return tuple(int(round(clamp(c / 255) * 255)) for c in col)

def png(path):
    raw = bytearray()
    for y in range(N):
        raw.append(0)
        for x in range(N):
            raw.extend(pixel(x, y))
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", N, N, 8, 2, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)

if __name__ == "__main__":
    png(sys.argv[1] if len(sys.argv) > 1 else "icon.png")
