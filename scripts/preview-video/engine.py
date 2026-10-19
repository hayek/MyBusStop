"""Composes an App Store preview from a recorded journey: the app's footage in a floating device
that a camera follows, kinetic captions, touches, a turn into wall mode, the device revealed on a
real wall, and an end card. A cut module (iphone.py, ipad.py, mac.py) describes one device's:
its scenes as stretches of the recording, where each tap landed, the camera's keys and the
captions. The camera is smoothed between its keys, scenes dissolve into each other, and a jump
inside the footage (a transition the recording missed) becomes a quick dissolve too."""
import math, subprocess, sys
from functools import lru_cache
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageChops

ROOT = Path(__file__).resolve().parents[2]
FONTS = ROOT / "BusBus/Resources/Fonts"
INK = (8, 8, 11)
YELLOW, RED, CYAN, WHITE, GREY = (255, 195, 0), (255, 59, 63), (34, 211, 238), (255, 255, 255), (160, 160, 174)
DARK_INK = (24, 22, 20)


def ease(x):
    x = min(1.0, max(0.0, x))
    return x * x * (3 - 2 * x)


def ease_out(x):
    x = min(1.0, max(0.0, x))
    return 1 - (1 - x) ** 3


def lerp(a, b, x):
    return a + (b - a) * x


def font(name, size):
    return ImageFont.truetype(str(FONTS / f"{name}.ttf"), size)


class Cut:
    def __init__(self, spec):
        self.s = spec
        self.W, self.H = spec.W, spec.H
        self.KICK = font("SpaceMono-Bold", spec.kicker_size)
        self.TITLE = font("Archivo-Black", spec.title_size)
        self.icon = Image.open(spec.icon).convert("RGB")
        self.wall = Image.open(spec.wall_image).convert("RGB") if getattr(spec, "wall_image", None) else None

    # MARK: Footage --------------------------------------------------------------------------

    @lru_cache(maxsize=6)
    def raw(self, n):
        s = self.s
        n = max(s.first_frame, min(n, s.last_frame))
        return Image.open(s.frames / f"{n:05d}.jpg").convert("RGB")

    def upright(self, src_t, rot):
        """The frame at source time, turned so its interface reads upright (rot: degrees CCW). A
        time between two frames blends them, so a clip played faster or slower still glides."""
        f = src_t * 30
        n = int(math.floor(f))
        x = f - n
        if x < 0.12:
            im = self.raw(n)
        elif x > 0.88:
            im = self.raw(n + 1)
        else:
            im = Image.blend(self.raw(n), self.raw(n + 1), x)
        return im.rotate(rot, expand=True) if rot else im

    @property
    def jumps(self):
        """Source times where the footage changes all at once from one frame to the next — a
        transition the recording missed, or a click filmed around — found by comparing small
        greyscale copies of the frames each clip plays."""
        if getattr(self, "_jumps", None) is not None:
            return self._jumps
        def thumb(n):
            n = max(self.s.first_frame, min(n, self.s.last_frame))
            im = Image.open(self.s.frames / f"{n:05d}.jpg")
            im.draft("L", (im.width // 8, im.height // 8))
            return list(im.convert("L").resize((40, 40)).getdata())
        found = []
        for c in self.s.clips:
            lo, hi = int(c["s0"] * 30), int(c["s1"] * 30)
            thumbs = [thumb(n) for n in range(lo, hi + 1)]
            diffs = [sum(abs(a - b) for a, b in zip(x, y)) / 1600 for x, y in zip(thumbs, thumbs[1:])]
            for i, d in enumerate(diffs):
                # neighbours one frame away may belong to the same quick jump; judge against those beyond
                around = [diffs[j] for j in (i - 3, i - 2, i + 2, i + 3) if 0 <= j < len(diffs)]
                if d > 6 and d > 2.2 * (max(around) if around else 0) and d >= max(diffs[max(0, i - 1):i + 2]):
                    found.append((lo + i + 1) / 30)
        self._jumps = sorted(set(found) | set(getattr(self.s, "extra_jumps", [])))
        print("jumps softened:", " ".join(f"{j:.2f}" for j in self._jumps), file=sys.stderr)
        return self._jumps

    def clip_at(self, t):
        for c in self.s.clips:
            if c["t0"] <= t < c["t1"]:
                return c
        return None

    def src_time(self, c, t):
        return c["s0"] + (t - c["t0"]) / (c["t1"] - c["t0"]) * (c["s1"] - c["s0"])

    def out_time(self, c, src):
        return c["t0"] + (src - c["s0"]) / (c["s1"] - c["s0"]) * (c["t1"] - c["t0"])

    # MARK: Camera ---------------------------------------------------------------------------

    def linear_camera(self, t):
        keys = self.s.cam
        for a, b in zip(keys, keys[1:]):
            if a[0] <= t <= b[0]:
                x = (t - a[0]) / max(1e-6, b[0] - a[0])
                return [lerp(a[i], b[i], x) for i in range(1, 6)]
        return list(keys[0][1:] if t < keys[0][0] else keys[-1][1:])

    @property
    def camera_path(self):
        """The camera at every frame: the keys joined by straight lines, then smoothed with a
        Gaussian so it never starts or stops abruptly. Smoothed in pieces split at the turn, whose
        two sides measure the footage in different orientations; the scale is smoothed in log."""
        if getattr(self, "_path", None) is not None:
            return self._path
        n = int(round(self.s.total * 30)) + 1
        raw = [self.linear_camera(i / 30) for i in range(n)]
        for r in raw:
            r[4] = math.log(r[4])
        cuts = [0, n]
        if self.s.turn:
            cuts = [0, int(round(self.s.turn["t0"] * 30)), int(round(self.s.turn["t1"] * 30)), n]
        sigma = getattr(self.s, "camera_smoothing", 0.32) * 30
        radius = int(sigma * 3)
        weights = [math.exp(-0.5 * (j / sigma) ** 2) for j in range(-radius, radius + 1)]
        path = [None] * n
        for lo, hi in zip(cuts, cuts[1:]):
            for i in range(lo, hi):
                acc, total = [0.0] * 5, 0.0
                for j, w in zip(range(-radius, radius + 1), weights):
                    r = raw[min(hi - 1, max(lo, i + j))]
                    for c in range(5):
                        acc[c] += r[c] * w
                    total += w
                path[i] = [v / total for v in acc]
        for p in path:
            p[4] = math.exp(p[4])
        self._path = path
        return path

    def camera(self, t):
        """(focus x, focus y in the footage's points, canvas x, canvas y, px per point)."""
        path = self.camera_path
        f = t * 30
        i = max(0, min(len(path) - 2, int(f)))
        x = f - i
        return [lerp(a, b, x) for a, b in zip(path[i], path[i + 1])]

    @staticmethod
    def centre(frame_size_pt, cam):
        px, py, cx, cy, k = cam
        w, h = frame_size_pt
        return cx - (px - w / 2) * k, cy - (py - h / 2) * k

    # MARK: Pieces ---------------------------------------------------------------------------

    @lru_cache(maxsize=1)
    def background(self):
        W, H = self.W, self.H
        bg = Image.new("RGB", (W, H), INK)
        glow = Image.new("RGB", (W, H), (0, 0, 0))
        d = ImageDraw.Draw(glow)
        for (x0, y0, x1, y1), c in self.s.glows:
            d.ellipse((x0 * W, y0 * H, x1 * W, y1 * H), fill=c)
        glow = glow.filter(ImageFilter.GaussianBlur(min(W, H) * 0.19))
        return ImageChops.add(bg, glow)

    def device(self, frame, w, h, k):
        """The screen at w x h in a thin floating bezel."""
        s = self.s
        bez = max(5, round(s.bezel_pt * k))
        R = round(s.radius_pt * k)
        full = Image.new("RGBA", (w + 2 * bez, h + 2 * bez), (0, 0, 0, 0))
        d = ImageDraw.Draw(full)
        d.rounded_rectangle((0, 0, full.width - 1, full.height - 1), radius=R + bez, fill=(26, 26, 32, 255),
                            outline=(72, 72, 84, 255), width=max(2, bez // 4))
        scr = frame.resize((w, h), Image.LANCZOS)
        full.paste(scr, (bez, bez), self.rounded_mask(w, h, R))
        return full

    @lru_cache(maxsize=16)
    def rounded_mask(self, w, h, r):
        m = Image.new("L", (w * 3, h * 3), 0)
        ImageDraw.Draw(m).rounded_rectangle((0, 0, w * 3 - 1, h * 3 - 1), radius=r * 3, fill=255)
        return m.resize((w, h), Image.LANCZOS)

    @lru_cache(maxsize=32)
    def shadow(self, w, h):
        pad = 140
        sh = Image.new("L", (w + 2 * pad, h + 2 * pad), 0)
        ImageDraw.Draw(sh).rounded_rectangle((pad, pad + 26, pad + w, pad + h + 26), radius=int(min(w, h) * 0.16), fill=170)
        return sh.filter(ImageFilter.GaussianBlur(48)), pad

    def paste(self, img, layer, x, y, alpha=1.0, shadow=True):
        if shadow:
            sh, pad = self.shadow(layer.width, layer.height)
            ox, oy = int(x - pad), int(y - pad)
            img.paste((0, 0, 0, 255), (ox, oy, ox + sh.width, oy + sh.height), sh.point(lambda v: int(v * 0.85 * alpha)))
        m = layer.split()[3]
        if alpha < 1:
            m = m.point(lambda v: int(v * alpha))
        img.paste(layer, (int(round(x)), int(round(y))), m)

    @lru_cache(maxsize=1)
    def scrim(self):
        s = self.s
        m = Image.new("L", (self.W, s.scrim_end), 255)
        d = ImageDraw.Draw(m)
        for y in range(s.scrim_solid, s.scrim_end):
            d.line((0, y, self.W, y), fill=int(255 * (1 - ease((y - s.scrim_solid) / (s.scrim_end - s.scrim_solid)))))
        return m

    # MARK: Captions -------------------------------------------------------------------------

    @lru_cache(maxsize=32)
    def layout(self, title):
        s = self.s
        lines, cur = [], []
        for w in title.split():
            if cur and self.TITLE.getlength(" ".join(cur + [w])) > s.cap_width:
                lines.append(cur); cur = [w]
            else:
                cur.append(w)
        lines.append(cur)
        placed, y = [], s.cap_top + s.kicker_size * 2.1
        space = self.TITLE.getlength(" ")
        for line in lines:
            x = s.cap_left if not s.cap_center else (self.W - self.TITLE.getlength(" ".join(line))) / 2
            for w in line:
                placed.append((w, x, y))
                x += self.TITLE.getlength(w) + space
            y += s.title_size * 1.05
        return placed

    def caption(self, img, t):
        s = self.s
        for cap in s.captions:
            t0, t1, kicker, title, accent = cap[:5]
            dark = len(cap) > 5 and cap[5] == "dark"
            if not (t0 <= t < t1):
                continue
            ink = DARK_INK if dark else WHITE
            kink = (110, 96, 70) if dark else accent
            local, remain = t - t0, t1 - t
            out = ease(1 - remain / 0.28) if remain < 0.28 else 0.0
            p = ease_out(local / 0.35)
            a = p * (1 - out)
            if a > 0:
                width = sum(self.KICK.getlength(c) + s.kicker_size * 0.18 for c in kicker) + s.kicker_size * 1.1
                layer = Image.new("RGBA", (int(width) + 20, int(s.kicker_size * 1.6)), (0, 0, 0, 0))
                ld = ImageDraw.Draw(layer)
                sq = s.kicker_size * 0.56
                ld.rectangle((0, s.kicker_size * 0.36, sq, s.kicker_size * 0.36 + sq), fill=kink + (255,))
                x = s.kicker_size * 1.1
                for ch in kicker:
                    ld.text((x, 0), ch, font=self.KICK, fill=kink + (255,))
                    x += self.KICK.getlength(ch) + s.kicker_size * 0.18
                lx = s.cap_left if not s.cap_center else (self.W - width) / 2
                img.paste(layer, (int(lx), int(s.cap_top - 10 * (1 - p) - 20 * out)), layer.split()[3].point(lambda v: int(v * a)))
            for i, (w, x, y) in enumerate(self.layout(title)):
                q = ease_out((local - 0.08 - i * 0.055) / 0.42)
                if q <= 0:
                    continue
                al = q * (1 - out)
                layer = Image.new("RGBA", (int(self.TITLE.getlength(w)) + 20, int(s.title_size * 1.45)), (0, 0, 0, 0))
                ImageDraw.Draw(layer).text((0, 0), w, font=self.TITLE, fill=ink + (255,))
                img.paste(layer, (int(x), int(y + s.title_size * 0.6 * (1 - q) - 24 * out)), layer.split()[3].point(lambda v: int(v * al)))

    # MARK: Touches --------------------------------------------------------------------------

    def touches(self, img, t, origin, k):
        c = self.clip_at(t)
        if not c:
            return
        d = ImageDraw.Draw(img, "RGBA")
        z = k / self.s.touch_ref_k
        def at(px, py):
            return origin[0] + px * k, origin[1] + py * k
        for src, px, py in self.s.taps:
            if not (c["s0"] <= src <= c["s1"]):
                continue
            dt = t - self.out_time(c, src)
            x, y = at(px, py)
            if -0.14 <= dt < 0:
                a = (dt + 0.14) / 0.14
                r = 30 * z
                d.ellipse((x - r, y - r, x + r, y + r), fill=(255, 255, 255, int(120 * a)))
            elif 0 <= dt <= 0.55:
                p = ease_out(dt / 0.55)
                r = (30 + 46 * p) * z
                d.ellipse((x - r, y - r, x + r, y + r), outline=(255, 255, 255, int(230 * (1 - p))), width=max(3, int(5 * z)))
                r2 = 30 * z * (1 - 0.3 * p)
                d.ellipse((x - r2, y - r2, x + r2, y + r2), fill=(255, 255, 255, int(120 * (1 - p))))
        for s0, s1, x0, y0, x1, y1 in getattr(self.s, "drags", []):
            if not (c["s0"] <= s0 <= c["s1"]):
                continue
            a0, a1 = self.out_time(c, s0), self.out_time(c, s1)
            if a0 - 0.12 <= t <= a1 + 0.25:
                p = ease((t - a0) / (a1 - a0))
                fade = 1 if t <= a1 else 1 - (t - a1) / 0.25
                for j in range(8):  # a short trail
                    q = max(0, p - j * 0.035)
                    x, y = at(lerp(x0, x1, q), lerp(y0, y1, q))
                    r = 30 * z * (1 - j * 0.09)
                    d.ellipse((x - r, y - r, x + r, y + r), fill=(255, 255, 255, int((130 if j == 0 else 40) * fade * (1 - j / 8))))

    # MARK: Wall -----------------------------------------------------------------------------

    def wall_layer(self, t, frame, cam):
        """The wall photo, framed so its device's screen sits where the camera puts the screen,
        with the footage in that screen."""
        s = self.s
        px, py, cx, cy, k = cam
        fw, fh = frame.size_pt
        sx0, sy0, sx1, sy1 = s.wall_screen
        m = k * fw / (sx1 - sx0)  # canvas px per photo px
        scx, scy = (sx0 + sx1) / 2, (sy0 + sy1) / 2
        # where the screen centre goes on the canvas
        ccx, ccy = cx - (px - fw / 2) * k, cy - (py - fh / 2) * k
        x0, y0 = scx - ccx / m, scy - ccy / m
        layer = self.wall.transform((self.W, self.H), Image.EXTENT, (x0, y0, x0 + self.W / m, y0 + self.H / m), Image.BICUBIC)
        w, h = int(round(fw * k)), int(round(fh * k))
        scr = frame.image.resize((w, h), Image.LANCZOS)
        layer.paste(scr, (int(round(ccx - w / 2)), int(round(ccy - h / 2))), self.rounded_mask(w, h, round(s.wall_radius * m)))
        return layer

    # MARK: End ------------------------------------------------------------------------------

    def end_card(self, img, t):
        s = self.s
        local = t - s.end[0]
        p = ease_out(local / 0.6)
        pop = 1 + 0.08 * math.sin(min(1, local / 0.6) * math.pi) if local < 0.6 else 1
        size = int(s.end_icon * (0.6 + 0.4 * p) * pop)
        if size > 4:
            ic = self.icon.resize((size, size), Image.LANCZOS)
            m = Image.new("L", (size, size), 0)
            ImageDraw.Draw(m).rounded_rectangle((0, 0, size - 1, size - 1), radius=int(size * 0.225), fill=int(255 * p))
            img.paste(ic, (self.W // 2 - size // 2, int(s.end_icon_y - size / 2)), m)
        tf = font("Archivo-Black", s.end_title)
        for i, line in enumerate(s.end_lines):
            q = ease_out((local - 0.25 - i * 0.08) / 0.5)
            if q <= 0:
                continue
            layer = Image.new("RGBA", (self.W, int(s.end_title * 1.4)), (0, 0, 0, 0))
            ImageDraw.Draw(layer).text((self.W / 2, 0), line, font=tf, fill=WHITE + (255,), anchor="ma")
            img.paste(layer, (0, int(s.end_text_y + i * s.end_title * 1.1 + 40 * (1 - q))), layer.split()[3].point(lambda v: int(v * q)))
        q = ease_out((local - 0.7) / 0.5)
        if q > 0:
            layer = Image.new("RGBA", (self.W, 60), (0, 0, 0, 0))
            dd = ImageDraw.Draw(layer)
            text = "IPHONE · IPAD · MAC"
            x = self.W / 2 - (sum(self.KICK.getlength(c) for c in text) + 6 * (len(text) - 1)) / 2
            for ch in text:
                dd.text((x, 0), ch, font=self.KICK, fill=GREY + (255,))
                x += self.KICK.getlength(ch) + 6
            img.paste(layer, (0, int(s.end_text_y + len(s.end_lines) * s.end_title * 1.1 + 50)), layer.split()[3].point(lambda v: int(v * q)))

    # MARK: Frame ----------------------------------------------------------------------------

    def render(self, t):
        s = self.s
        img = self.background().copy().convert("RGBA")
        cam = self.camera(t)
        px, py, cx, cy, k = cam
        end_a = 1 - ease((t - s.end[0]) / 0.45) if t >= s.end[0] else 1.0
        wall_a = 0.0
        if self.wall is not None and t >= s.wall_in[0]:
            wall_a = ease((t - s.wall_in[0]) / (s.wall_in[1] - s.wall_in[0]))

        if end_a > 0:
            turn = s.turn
            if turn and turn["t0"] <= t < turn["t1"]:
                x = (t - turn["t0"]) / (turn["t1"] - turn["t0"])
                e = ease(x)
                theta = turn["angle"] * e
                a_img = self.upright(turn["src_a"], turn["rot_a"])
                b_img = self.upright(turn["src_b"], turn["rot_b"])
                ka = lerp(turn["k_a"], turn["k_b"], e)
                aw, ah = int(a_img.width / s.src_px_per_pt * ka), int(a_img.height / s.src_px_per_pt * ka)
                da = self.device(a_img, aw, ah, ka).rotate(theta, resample=Image.BICUBIC, expand=True)
                if x > 0.45:
                    bw, bh = int(b_img.width / s.src_px_per_pt * ka), int(b_img.height / s.src_px_per_pt * ka)
                    db = self.device(b_img, bw, bh, ka).rotate(theta - turn["angle"], resample=Image.BICUBIC, expand=True)
                    blend = ease((x - 0.45) / 0.3)
                    canvas = Image.new("RGBA", (max(da.width, db.width), max(da.height, db.height)), (0, 0, 0, 0))
                    canvas.paste(da, ((canvas.width - da.width) // 2, (canvas.height - da.height) // 2))
                    canvas2 = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
                    canvas2.paste(db, ((canvas.width - db.width) // 2, (canvas.height - db.height) // 2))
                    da = Image.blend(canvas, canvas2, blend)
                self.paste(img, da, turn["cx"] - da.width / 2, turn["cy"] - da.height / 2, end_a, shadow=False)
            else:
                c = self.clip_at(t) or s.clips[-1]
                src = self.src_time(c, min(t, c["t1"]))
                frame_img = self.upright(src, c.get("rot", 0))
                dissolve = getattr(s, "dissolve", 0.45)
                i = s.clips.index(c)
                if i > 0 and t - c["t0"] < dissolve:
                    p = s.clips[i - 1]
                    if abs(p["t1"] - c["t0"]) < 1e-6 and p.get("rot", 0) == c.get("rot", 0):
                        before = self.upright(p["s1"] - 1 / 30, p.get("rot", 0))
                        if before.size == frame_img.size:
                            frame_img = Image.blend(before, frame_img, ease((t - c["t0"]) / dissolve))
                # a jump inside the footage becomes a quick dissolve
                rate = (c["s1"] - c["s0"]) / (c["t1"] - c["t0"])
                window = 0.36 * rate
                for j in self.jumps:
                    if j <= src < j + window and j - 1 / 30 >= c["s0"]:
                        before = self.upright(j - 1 / 30, c.get("rot", 0))
                        if before.size == frame_img.size:
                            frame_img = Image.blend(before, frame_img, ease((src - j) / window))
                        break
                fw, fh = frame_img.width / s.src_px_per_pt, frame_img.height / s.src_px_per_pt
                ccx, ccy = cx - (px - fw / 2) * k, cy - (py - fh / 2) * k
                w, h = int(round(fw * k)), int(round(fh * k))
                if wall_a < 1:
                    dev = self.device(frame_img, w, h, k)
                    bez = (dev.width - w) / 2
                    self.paste(img, dev, ccx - w / 2 - bez, ccy - h / 2 - bez, end_a)
                    self.touches(img, t, (ccx - w / 2, ccy - h / 2), k)
                if wall_a > 0:
                    class F: pass
                    f = F(); f.image = frame_img; f.size_pt = (fw, fh)
                    wl = self.wall_layer(t, f, cam).convert("RGBA")
                    a = wall_a * end_a
                    img.paste(wl, (0, 0), Image.new("L", wl.size, int(255 * a)))
            scrim_a = (1 - wall_a) * end_a
            if scrim_a > 0:
                img.paste(self.background().crop((0, 0, self.W, s.scrim_end)), (0, 0),
                          self.scrim().point(lambda v: int(v * scrim_a)))
            self.caption(img, t)
        if t >= s.end[0]:
            self.end_card(img, t)
        fade = min(1, t / 0.25, (s.total - t) / 0.3)
        out = img.convert("RGB")
        if fade < 1:
            out = Image.blend(Image.new("RGB", out.size, (0, 0, 0)), out, max(0, fade))
        return out

    def stills(self, times, folder):
        Path(folder).mkdir(parents=True, exist_ok=True)
        for t in times:
            self.render(t).save(Path(folder) / f"still_{t:05.2f}.png")

    def encode(self, out):
        n = int(round(self.s.total * 30))
        ff = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{self.W}x{self.H}",
                               "-r", "30", "-i", "-", "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
                               "-shortest", "-c:v", "libx264", "-profile:v", "high", "-level", "4.0", "-preset", "slow",
                               "-crf", "15", "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-c:a", "aac", "-b:a", "256k",
                               str(out)], stdin=subprocess.PIPE)
        for i in range(n):
            ff.stdin.write(self.render(i / 30).tobytes())
            if i % 90 == 0:
                print(f"  {i}/{n}", file=sys.stderr)
        ff.stdin.close()
        ff.wait()
