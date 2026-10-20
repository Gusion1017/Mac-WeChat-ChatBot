#!/usr/bin/env python3
"""Generate the WeChat AI app icon (1024px master + .icns iconset).

Pure Pillow, no external assets. Apple-style squircle: emerald gradient,
white chat bubble and a four-point AI sparkle.
"""
import math
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "assets")
ICONSET = os.path.join(OUT_DIR, "AppIcon.iconset")


def squircle_mask(size: int, inset: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle(
        (inset, inset, size - inset, size - inset), radius=radius, fill=255
    )
    return mask


def vertical_gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    img = Image.new("RGB", (size, size), top)
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        # ease-out for a softer bottom
        t = t ** 0.92
        color = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        d.line([(0, y), (size, y)], fill=color)
    return img


def radial_glow(size: int, center: tuple, radius: float, color: tuple, strength: float) -> Image.Image:
    glow = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(glow)
    cx, cy = center
    steps = 60
    for i in range(steps, 0, -1):
        r = radius * i / steps
        alpha = int(strength * 255 * (1 - i / steps) ** 1.6)
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=alpha)
    glow = glow.filter(ImageFilter.GaussianBlur(radius * 0.18))
    layer = Image.new("RGBA", (size, size), color + (0,))
    layer.putalpha(glow)
    return layer


def star_points(cx: float, cy: float, outer: float, inner: float, points: int = 4, rotation: float = -math.pi / 2):
    coords = []
    for i in range(points * 2):
        r = outer if i % 2 == 0 else inner
        angle = rotation + i * math.pi / points
        coords.append((cx + r * math.cos(angle), cy + r * math.sin(angle)))
    return coords


def make_master() -> Image.Image:
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # Drop shadow under the squircle.
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle((122, 142, 902, 922), radius=232, fill=(10, 60, 40, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(42))
    canvas.alpha_composite(shadow)

    # Squircle body.
    mask = squircle_mask(SIZE, 112, 232)
    body = vertical_gradient(SIZE, (58, 214, 150), (13, 138, 99))
    body = body.convert("RGBA")
    body.alpha_composite(radial_glow(SIZE, (330, 250), 560, (255, 255, 255), 0.22))
    body.alpha_composite(radial_glow(SIZE, (820, 880), 420, (0, 40, 30), 0.30))
    canvas.paste(body, (0, 0), mask)

    # Inner rim highlight.
    rim = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rim)
    rd.rounded_rectangle((114, 114, 910, 910), radius=231, outline=(255, 255, 255, 70), width=4)
    canvas.alpha_composite(rim)

    # Chat bubble with soft shadow.
    bubble = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bubble)
    bd.rounded_rectangle((238, 286, 786, 664), radius=112, fill=(255, 255, 255, 246))
    # tail
    bd.polygon([(330, 640), (300, 744), (430, 668)], fill=(255, 255, 255, 246))
    shadow_b = bubble.filter(ImageFilter.GaussianBlur(22))
    shadow_b.putalpha(shadow_b.getchannel("A").point(lambda a: int(a * 0.28)))
    canvas.alpha_composite(shadow_b, (0, 16))
    canvas.alpha_composite(bubble)

    # Three dots inside bubble (emerald).
    dots = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dots)
    for x in (389, 512, 635):
        dd.ellipse((x - 27, 448 - 27, x + 27, 448 + 27), fill=(16, 150, 108, 255))
    canvas.alpha_composite(dots)

    # AI sparkle at the bubble's top right, overlapping the rim.
    sparkle = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sdw = ImageDraw.Draw(sparkle)
    center = (742, 300)
    sdw.polygon(star_points(center[0] + 4, center[1] + 14, 128, 34), fill=(0, 45, 32, 110))
    sparkle = sparkle.filter(ImageFilter.GaussianBlur(14))
    canvas.alpha_composite(sparkle)

    star = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    st = ImageDraw.Draw(star)
    st.polygon(star_points(center[0], center[1], 122, 32), fill=(255, 255, 255, 255))
    st.polygon(star_points(center[0], center[1], 74, 18), fill=(214, 255, 236, 255))
    canvas.alpha_composite(star)

    # Tiny secondary sparkle top-left.
    small = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sm = ImageDraw.Draw(small)
    sm.polygon(star_points(318, 250, 44, 12), fill=(255, 255, 255, 220))
    canvas.alpha_composite(small)

    return canvas


def main() -> int:
    os.makedirs(OUT_DIR, exist_ok=True)
    master = make_master()
    master_path = os.path.join(OUT_DIR, "AppIcon-1024.png")
    master.save(master_path)

    if os.path.isdir(ICONSET):
        for f in os.listdir(ICONSET):
            os.remove(os.path.join(ICONSET, f))
    os.makedirs(ICONSET, exist_ok=True)

    variants = {
        "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
    }
    for name, size in variants.items():
        resized = master.resize((size, size), Image.LANCZOS)
        resized.save(os.path.join(ICONSET, name))

    icns = os.path.join(OUT_DIR, "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", icns], check=True)
    print(f"wrote {master_path}")
    print(f"wrote {icns}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
