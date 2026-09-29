#!/usr/bin/env python3
"""
生成 Android 启动图标（无需 Pillow 等第三方库，只用标准库写 PNG）。

设计：深色圆角方块底 + 白色锁形（锁体 + 锁梁）
输出：mdpi/hdpi/xhdpi/xxhdpi/xxxhdpi 五套 ic_launcher.png
"""

import math
import os
import struct
import zlib

BG = (0x1B, 0x20, 0x27)      # 深灰蓝，与 App 界面一致
FG = (0xE8, 0xEC, 0xF1)      # 近白
ACCENT = (0x2E, 0x7D, 0x32)  # 绿色，呼应"解锁"

DENSITIES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}


def write_png(path, pixels, size):
    """pixels: list of rows, each row a list of (r,g,b,a)"""
    raw = bytearray()
    for y in range(size):
        raw.append(0)  # filter type 0
        for x in range(size):
            r, g, b, a = pixels[y][x]
            raw += bytes((r, g, b, a))

    def chunk(tag, data):
        out = struct.pack(">I", len(data)) + tag + data
        out += struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        return out

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)


def inside_rounded_rect(x, y, size, radius):
    """判断像素是否落在圆角矩形内，返回覆盖率 0..1（简单 2x2 超采样抗锯齿）"""
    hits = 0
    for dx in (0.25, 0.75):
        for dy in (0.25, 0.75):
            px, py = x + dx, y + dy
            cx = min(max(px, radius), size - radius)
            cy = min(max(py, radius), size - radius)
            if (px - cx) ** 2 + (py - cy) ** 2 <= radius ** 2:
                hits += 1
    return hits / 4.0


def coverage_rounded_rect(px, py, x0, y0, w, h, r):
    """点落在圆角矩形内的覆盖率 0..1（按到边界的距离做 1px 羽化，实现抗锯齿）"""
    cx = min(max(px, x0 + r), x0 + w - r)
    cy = min(max(py, y0 + r), y0 + h - r)
    dist = math.hypot(px - cx, py - cy) - r
    return min(max(0.5 - dist, 0.0), 1.0)


def coverage_ring(px, py, cx, cy, r_in, r_out):
    """圆环覆盖率，内外边沿各羽化 1px"""
    d = math.hypot(px - cx, py - cy)
    outer = min(max(r_out - d + 0.5, 0.0), 1.0)
    inner = min(max(d - r_in + 0.5, 0.0), 1.0)
    return outer * inner


def build_icon(size):
    radius = size * 0.22
    body_w = size * 0.46
    body_h = size * 0.34
    body_x = (size - body_w) / 2
    body_y = size * 0.48
    body_r = size * 0.06

    # 锁梁：以锁体上沿为圆心的开环，右下留缺口 —— 表示"已解锁"
    shackle_cx = size / 2
    shackle_cy = body_y
    shackle_r_outer = size * 0.155
    shackle_r_inner = size * 0.105

    keyhole_cx = size / 2
    keyhole_cy = body_y + body_h * 0.45
    keyhole_r = size * 0.045

    pixels = []
    for y in range(size):
        row = []
        for x in range(size):
            bg_cover = inside_rounded_rect(x, y, size, radius)
            if bg_cover <= 0:
                row.append((0, 0, 0, 0))
                continue

            px, py = x + 0.5, y + 0.5

            lock_cover = coverage_rounded_rect(px, py, body_x, body_y,
                                               body_w, body_h, body_r)

            # 锁梁：上半圆环，右下 0~38 度挖空
            if py <= shackle_cy + 1:
                ring = coverage_ring(px, py, shackle_cx, shackle_cy,
                                     shackle_r_inner, shackle_r_outer)
                if ring > 0:
                    ang = math.degrees(math.atan2(shackle_cy - py, px - shackle_cx))
                    if 0 <= ang <= 38:
                        ring = 0.0
                lock_cover = max(lock_cover, ring)

            keyhole_cover = min(max(keyhole_r - math.hypot(px - keyhole_cx,
                                                           py - keyhole_cy) + 0.5,
                                    0.0), 1.0) if lock_cover > 0.5 else 0.0

            # 颜色混合：底色 -> 锁身白 -> 锁孔绿
            r = BG[0] + (FG[0] - BG[0]) * lock_cover
            g = BG[1] + (FG[1] - BG[1]) * lock_cover
            b = BG[2] + (FG[2] - BG[2]) * lock_cover

            if keyhole_cover > 0:
                r = r + (ACCENT[0] - r) * keyhole_cover
                g = g + (ACCENT[1] - g) * keyhole_cover
                b = b + (ACCENT[2] - b) * keyhole_cover

            row.append((int(round(r)), int(round(g)), int(round(b)),
                        int(round(bg_cover * 255))))
        pixels.append(row)
    return pixels


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    res = os.path.join(here, "..", "android-src", "res")

    for name, size in DENSITIES.items():
        pixels = build_icon(size)
        path = os.path.join(res, "mipmap-" + name, "ic_launcher.png")
        write_png(path, pixels, size)
        print("生成 %-8s %3dx%-3d -> %s" % (name, size, size, os.path.relpath(path, here)))

    print("完成")


if __name__ == "__main__":
    main()
