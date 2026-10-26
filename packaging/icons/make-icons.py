#!/usr/bin/env python3
"""Draw the SpareKey icon and export it for both apps (needs Pillow):
    python3 packaging/icons/make-icons.py
-> packaging/icons/sparekey.png (1024 px), packaging/icons/hicolor/<size>/apps/sparekey.png (Linux)
   and macos/AppIcon.icns (macOS)."""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
N = 1024
LINUX_SIZES = (16, 24, 32, 48, 64, 128, 256, 512)


def draw():
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    # macOS-style tile: rounded square with a soft vertical gradient and a drop shadow
    pad, r = 100, 185
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((pad, pad + 18, N - pad, N - pad + 18), r, fill=(0, 0, 0, 110))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(22)))
    grad = Image.new("RGBA", (1, N))
    for y in range(N):
        t = y / N
        grad.putpixel((0, y), (int(46 + 20 * t), int(56 + 18 * t), int(78 + 22 * t), 255))
    grad = grad.resize((N, N))
    mask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(mask).rounded_rectangle((pad, pad, N - pad, N - pad), r, fill=255)
    tile = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    tile.paste(grad, (0, 0), mask)
    img.alpha_composite(tile)
    d = ImageDraw.Draw(img)

    # keyboard body
    bx0, by0, bx1, by1 = 190, 400, 834, 760
    d.rounded_rectangle((bx0, by0, bx1, by1), 46, fill=(226, 230, 238, 255))
    d.rounded_rectangle((bx0, by0 + 330, bx1, by1), 46, fill=(196, 202, 214, 255))
    d.rounded_rectangle((bx0, by0, bx1, by1 - 14), 46, fill=(236, 239, 245, 255))
    # keys: three staggered rows, then a row with a wide space bar
    key = (150, 160, 178, 255)
    kw, kh, gap = 52, 52, 14
    x_start, y_start = 222, 430
    for row in range(3):
        x = x_start + row * 14
        while x + kw <= bx1 - 30:
            d.rounded_rectangle((x, y_start + row * (kh + gap), x + kw, y_start + row * (kh + gap) + kh), 10, fill=key)
            x += kw + gap
    yb = y_start + 3 * (kh + gap)
    d.rounded_rectangle((x_start, yb, x_start + kw, yb + kh), 10, fill=key)
    d.rounded_rectangle((x_start + kw + gap, yb, bx1 - 32 - 2 * (kw + gap), yb + kh), 10, fill=key)
    for i in (2, 1):
        x = bx1 - 32 - i * (kw + gap) + gap
        d.rounded_rectangle((x, yb, x + kw, yb + kh), 10, fill=key)

    # the S98's little screen, glowing, on a raised panel top-right
    sx0, sy0, sx1, sy1 = 560, 250, 820, 385
    d.rounded_rectangle((sx0 - 14, sy0 - 14, sx1 + 14, sy1 + 14), 30, fill=(236, 239, 245, 255))
    glow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(glow).rounded_rectangle((sx0, sy0, sx1, sy1), 18, fill=(80, 200, 255, 170))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(18)))
    scr = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    sd = ImageDraw.Draw(scr)
    for y in range(sy0, sy1):
        t = (y - sy0) / (sy1 - sy0)
        sd.line((sx0, y, sx1, y), fill=(int(40 + 80 * t), int(120 + 60 * t), int(255 - 40 * t), 255))
    m2 = Image.new("L", (N, N), 0)
    ImageDraw.Draw(m2).rounded_rectangle((sx0, sy0, sx1, sy1), 18, fill=255)
    img.paste(scr, (0, 0), m2)

    # a small key glyph on the screen ("spare key")
    d = ImageDraw.Draw(img)
    cx, cy, white = 650, 318, (255, 255, 255, 255)
    d.ellipse((cx - 34, cy - 34, cx + 34, cy + 34), outline=white, width=14)
    d.rectangle((cx + 30, cy - 7, cx + 130, cy + 7), fill=white)
    d.rectangle((cx + 92, cy + 7, cx + 106, cy + 30), fill=white)
    d.rectangle((cx + 116, cy + 7, cx + 130, cy + 24), fill=white)
    return img


def main():
    img = draw()
    img.save(HERE / "sparekey.png")
    for s in LINUX_SIZES:
        out = HERE / "hicolor" / f"{s}x{s}" / "apps" / "sparekey.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        img.resize((s, s), Image.LANCZOS).save(out)
    img.save(HERE.parent.parent / "macos" / "AppIcon.icns",
             sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    print("icons written")


if __name__ == "__main__":
    main()
