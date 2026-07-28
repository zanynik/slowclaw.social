#!/usr/bin/env python3
"""Generate the SlowClaw app icon: a stylized three-prong claw mark in the
brand green (#16a37f) on a warm off-white (#fafaf9) background.

Minimalist and legible at small sizes (the iOS home screen renders the icon
down to ~60pt). No text, no fine detail. Symmetric, geometric.

Writes a single 1024x1024 RGBA PNG (modern Xcode single-size AppIcon).
"""
from PIL import Image, ImageDraw
import math

SIZE = 1024
GREEN = (22, 163, 127, 255)        # #16a37f
GREEN_DK = (18, 130, 100, 255)     # subtle darker shade for depth
BG = (250, 250, 249, 255)          # #fafaf9

img = Image.new("RGBA", (SIZE, SIZE), BG)
d = ImageDraw.Draw(img)


def claw_pry(origin_x, origin_y, length, angle_deg, base_w, tip_w):
    """One tapered curved prong: a filled quad from base to rounded tip,
    swept by a small angle so the three prongs fan out like a scratch."""
    a0 = math.radians(angle_deg - 6)
    a1 = math.radians(angle_deg + 6)
    bx, by = origin_x, origin_y
    tx = origin_x + length * math.cos(math.radians(angle_deg))
    ty = origin_y + length * math.sin(math.radians(angle_deg))
    # base perpendicular (wide), tip perpendicular (narrow)
    px, py = math.cos(math.radians(angle_deg + 90)), math.sin(math.radians(angle_deg + 90))
    p1 = (bx + px * base_w / 2, by + py * base_w / 2)
    p2 = (bx - px * base_w / 2, by - py * base_w / 2)
    p3 = (tx - px * tip_w / 2, ty - py * tip_w / 2)
    p4 = (tx + px * tip_w / 2, ty + py * tip_w / 2)
    d.polygon([p1, p2, p3, p4], fill=GREEN)
    # rounded tip cap
    r = tip_w / 2 + 4
    d.ellipse([tx - r, ty - r, tx + r, ty + r], fill=GREEN)
    # rounded base cap
    rb = base_w / 2
    d.ellipse([bx - rb, by - rb, bx + rb, by + rb], fill=GREEN)


# Three prongs fanning up-right from bottom-left, like a claw scratch.
# Origin a bit below-left of center so the mark reads centered in the squircle.
ox, oy = SIZE * 0.30, SIZE * 0.74
L = SIZE * 0.50
claw_pry(ox, oy, L, angle_deg=-60, base_w=120, tip_w=26)   # top prong
claw_pry(ox, oy, L, angle_deg=-45, base_w=130, tip_w=30)   # middle (longest feel)
claw_pry(ox, oy, L, angle_deg=-30, base_w=120, tip_w=26)   # lower prong

# A small soft pad under the base to suggest a paw/claw origin (subtle).
pad_r = SIZE * 0.05
d.ellipse([ox - pad_r * 1.4, oy - pad_r * 0.8, ox + pad_r * 1.4, oy + pad_r * 0.8], fill=GREEN_DK)

# Subtle vignette to tie to the app's warm palette (very light).
overlay = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
od = ImageDraw.Draw(overlay)
for i in range(40):
    alpha = int(2 * (40 - i) / 40)
    od.rectangle([i, i, SIZE - i, SIZE - i], outline=(0, 0, 0, alpha))
img = Image.alpha_composite(img, overlay)

out = "AppIcon-1024.png"
img.save(out, "PNG")
print(f"wrote {out} ({SIZE}x{SIZE})")
