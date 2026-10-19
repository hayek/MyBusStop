"""Mounts a device on the wall photo: a soft shadow, a cable from its port curving down behind the
books, the body with a metal edge, and a black screen for the footage to go in.

The photo (wall-photo.jpg) is by an Unsplash photographer, under the Unsplash License: free for
commercial use, no credit required."""
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).parent
PHOTO = HERE / "wall-photo.jpg"
SS = 4  # the body is drawn this much larger, for clean edges


def mount(out_path, cx, cy, sw, sh, bezel, screen_r, body_r, port, cable_end_y):
    """Writes the composite; returns the screen's rectangle in the photo's pixels."""
    photo = Image.open(PHOTO).convert("RGB")
    W, H = photo.size
    bw, bh = sw + 2 * bezel, sh + 2 * bezel
    body = (cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2)
    scr = (cx - sw / 2, cy - sh / 2, cx + sw / 2, cy + sh / 2)
    out = photo.convert("RGBA")
    # the device's soft shadow on the wall, light from the upper left
    shl = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shl).rounded_rectangle((body[0] + 12, body[1] + 24, body[2] + 12, body[3] + 28), radius=body_r, fill=140)
    shl = shl.filter(ImageFilter.GaussianBlur(28))
    shadow = Image.new("RGBA", (W, H), (45, 36, 26, 255))
    shadow.putalpha(shl)
    out.alpha_composite(shadow)
    # the cable: out of the port, a bend, then straight down
    if port == "right":
        x, y = body[2] - 2, cy
        pts = [(x + i, y) for i in range(0, 26)]
        R = 46
        ox, oy = x + 25, y + R
        pts += [(ox + R * math.sin(a), oy - R * math.cos(a)) for a in [i * math.pi / 2 / 30 for i in range(31)]]
        pts += [(ox + R, yy) for yy in range(int(oy), cable_end_y, 4)]
    else:
        x, y = cx, body[3] - 2
        pts = [(x, yy) for yy in range(int(y), cable_end_y, 4)]
    cable = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(cable)
    d.line([(px + 7, py + 6) for px, py in pts], fill=(50, 40, 30, 60), width=14, joint="curve")
    d.line(pts, fill=(232, 230, 224, 255), width=12, joint="curve")
    d.line([(px - 3, py) for px, py in pts], fill=(252, 252, 250, 255), width=4, joint="curve")
    d.line([(px + 4, py) for px, py in pts], fill=(200, 196, 188, 255), width=3, joint="curve")
    if port == "right":  # the plug's boot
        d.rounded_rectangle((body[2] - 2, cy - 11, body[2] + 22, cy + 11), radius=6, fill=(236, 234, 228, 255))
    out.alpha_composite(cable.filter(ImageFilter.GaussianBlur(0.7)))
    # the body
    pad = 40
    bx0, by0 = int(body[0]) - pad, int(body[1]) - pad
    bwid, bhei = int(bw) + 2 * pad, int(bh) + 2 * pad
    big = Image.new("RGBA", (bwid * SS, bhei * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    def r(b):
        return tuple(int((v - o) * SS) for v, o in zip(b, (bx0, by0, bx0, by0)))
    d.rounded_rectangle(r(body), radius=body_r * SS, fill=(20, 20, 23, 255))
    d.rounded_rectangle(r(body), radius=body_r * SS, outline=(118, 116, 120, 255), width=4 * SS)
    d.rounded_rectangle(r((body[0] + 4, body[1] + 4, body[2] - 4, body[3] - 4)), radius=(body_r - 4) * SS,
                        outline=(8, 8, 10, 255), width=2 * SS)
    d.rounded_rectangle(r(scr), radius=screen_r * SS, fill=(4, 4, 6, 255))
    out.alpha_composite(big.resize((bwid, bhei), Image.LANCZOS), (bx0, by0))
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    out.convert("RGB").save(out_path, quality=95)
    return scr


def screen(m):
    """A mount's screen rectangle in the photo's pixels."""
    return (m["cx"] - m["sw"] / 2, m["cy"] - m["sh"] / 2, m["cx"] + m["sw"] / 2, m["cy"] + m["sh"] / 2)


# Above the candle, where an old phone or iPad would hang by the door: the iPhone on its side with
# its cable from the port, the iPad upright with its cable from the bottom; both cables end behind
# the books. Sizes are the devices' real ones against the sideboard (about 3,500 px a metre).
IPHONE = dict(cx=1180, cy=1650, sw=556, sh=256, bezel=18, screen_r=36, body_r=54, port="right", cable_end_y=3290)
IPAD = dict(cx=1500, cy=1500, sw=690, sh=920, bezel=32, screen_r=12, body_r=44, port="bottom", cable_end_y=3290)
