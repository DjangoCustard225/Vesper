"""Render Vesper's layered playback-card icon in Quby's geometric style.

Opaque blue gradient, cream card, tilted pale-blue backing, soft shadow,
bold play symbol. iOS supplies the outer mask. --check verifies existing assets.
"""
from pathlib import Path
import argparse
import json
import math
import struct
import zlib

SIZE = 1024
PAPER = (255, 250, 235)
BACK_PAPER = (177, 219, 246)
INK = (54, 65, 77)
ACCENT = (29, 117, 216)


def smooth(edge0, edge1, value):
    t = max(0.0, min(1.0, (value - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)


def segment_distance(x, y, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(x - ax - t * dx, y - ay - t * dy)


def rounded_rect_distance(x, y, left, top, width, height, radius):
    dx = abs(x - left - width / 2) - width / 2 + radius
    dy = abs(y - top - height / 2) - height / 2 + radius
    return math.hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - radius


def blend(color, paint, distance, opacity=1):
    alpha = (1 - smooth(-0.5, 0.5, distance)) * opacity
    return [c + (p - c) * alpha for c, p in zip(color, paint)]


def chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)


def render():
    raw = bytearray()
    angle = math.radians(12)
    cosine, sine = math.cos(angle), math.sin(angle)
    triangle = [(448, 390), (448, 578), (610, 484)]
    for py in range(SIZE):
        raw.append(0)
        y = py + 0.5
        for px in range(SIZE):
            x = px + 0.5
            light = max(0, 1 - math.hypot(x - 190, y - 95) / 1100)
            color = [18 + 24 * light, 91 + 56 * light, 192 + 44 * light]
            back_x = (x - 512) * cosine + (y - 512) * sine + 512
            back_y = -(x - 512) * sine + (y - 512) * cosine + 512
            color = blend(color, BACK_PAPER, rounded_rect_distance(back_x, back_y, 221, 306, 596, 470, 54), 0.8)
            shadow_distance = rounded_rect_distance(x, y, 223, 296, 596, 470, 55)
            shadow = max(0, 1 - max(shadow_distance, 0) / 32) * 0.12
            color = [channel * (1 - shadow) for channel in color]
            color = blend(color, PAPER, rounded_rect_distance(x, y, 214, 282, 596, 470, 55))
            distance = min(segment_distance(x, y, *triangle[i], *triangle[(i + 1) % 3]) for i in range(3))
            inside = x >= 448 and abs(y - 484) <= (610 - x) * 94 / 162
            color = blend(color, ACCENT, (-distance if inside else distance) - 16)
            color = blend(color, INK, rounded_rect_distance(x, y, 300, 652, 424, 20, 10), 0.18)
            color = blend(color, ACCENT, rounded_rect_distance(x, y, 300, 652, 170, 20, 10))
            raw.extend(round(max(0, min(255, channel))) for channel in color)
    header = struct.pack('>IIBBBBB', SIZE, SIZE, 8, 2, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    assets = root / 'Vesper/Assets.xcassets'
    png = render()
    outputs = {
        assets / 'AppIcon.appiconset/AppIcon.png': png,
        assets / 'Contents.json': json.dumps({'info': {'author': 'xcode', 'version': 1}}, indent=2).encode(),
        assets / 'AppIcon.appiconset/Contents.json': json.dumps({'images': [{'filename': 'AppIcon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}], 'info': {'author': 'xcode', 'version': 1}}, indent=2).encode(),
        assets / 'AccentColor.colorset/Contents.json': json.dumps({'colors': [{'idiom': 'universal', 'color': {'color-space': 'srgb', 'components': {'red': '1.000', 'green': '1.000', 'blue': '1.000', 'alpha': '1.000'}}}], 'info': {'author': 'xcode', 'version': 1}}, indent=2).encode(),
    }
    for path, contents in outputs.items():
        if path.is_file() and path.read_bytes() == contents:
            continue
        if args.check:
            raise SystemExit(f'{path.relative_to(root)} is out of date; run python3 Scripts/GenerateIcon.py')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)
    print('PASS: Vesper icon and Xcode assets match the layered playback-card artwork.')


if __name__ == '__main__':
    main()
