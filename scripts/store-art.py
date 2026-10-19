#!/usr/bin/env python3
"""Sets the app's real screens in the App Store designs, in every listing language.

    scripts/screenshots.sh store      # first: the raw shots and clips, per language
    scripts/store-art.py              # then: every screenshot and preview
    scripts/store-art.py --languages he ja --devices iphone --only shots
    scripts/store-art.py --only creative   # the product page header and search results artwork and videos

Reads   screenshots/store/raw/<iphone|ipad|mac>/<language>/<name>.png|.mov, <name>-clip/<ms>.png
Writes  screenshots/store/final/<iphone|ipad|mac>/<language>/<nn>-<name>.png
        screenshots/store/final/<iphone|ipad|mac>/<language>/preview.mp4
        screenshots/store/final/creative/universal.png, header.mp4, search.mp4 (--only creative)

The frames follow the "App Store" page of the design canvas: the caption over a coloured ground,
the app's screen in a device outline, at App Store Connect's exact sizes (iPhone 6.9" 1320 x 2868,
iPad 13" 2752 x 2064, Mac 2880 x 1800). The captions come from store-art/captions.json. Each preview is four
scenes, 22 s at 30 fps, H.264 with a silent AAC track (App Store Connect wants one): the recorded
clips framed the same way, cross-faded, ending on the icon card.

Chrome draws each frame (headless, with the app's own fonts); ffmpeg lays the clips into the
video frames between an opaque ground and a transparent top (the device outline covers the
clip's square corners).
"""
import argparse, bisect, html, json, math, os, shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "screenshots/store/raw"
FINAL = ROOT / "screenshots/store/final"
FONTS = ROOT / "BusBus/Resources/Fonts"
CAPTIONS = json.loads((Path(__file__).parent / "store-art/captions.json").read_text())
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

RTL = {"ar", "he"}
# The app's rule (LocaleAwareBusFont): letter-spacing only for the alphabets it was drawn for.
TRACKED = {"en", "de", "es", "fi", "fr", "it", "nb", "pl", "pt-BR", "pt-PT", "ru", "sv", "tr", "vi"}
# Archivo has Latin and Vietnamese; the rest fall back to the system's face for their script.
FALLBACK = {
    "ja": '"Hiragino Sans"', "ko": '"Apple SD Gothic Neo"', "zh-Hans": '"PingFang SC"',
    "zh-Hant": '"PingFang HK"', "ar": '"SF Arabic", "Geeza Pro"', "he": '"SF Hebrew", "Arial Hebrew"',
    "hi": '"Kohinoor Devanagari"', "pa": '"Mukta Mahee", "Gurmukhi MN"',
}

INK, NIGHT, WALL, BAND = "#08080B", "#08080B", "#0D0D12", "#0B0B0F"
YELLOW, RED, CYAN, PAPER = "#FFC300", "#FF3B3F", "#22D3EE", "#F4F2EC"

# The design's app icon, full bleed; the frame rounds it.
ICON_SVG = """<svg width="100%" height="100%" viewBox="0 0 1024 1024" aria-hidden="true">
<rect width="1024" height="1024" fill="#F4F2EC"/>
<g fill="none" stroke-width="76" stroke-linecap="round">
<path d="M232 -60 V230 C232 330 292 400 392 400 H1084" stroke="#D32029"/>
<path d="M232 1084 V794 C232 694 292 624 392 624 H1084" stroke="#0E7C86"/>
<path d="M-60 512 H1084" stroke="#EFA400"/></g>
<rect x="440" y="318" width="144" height="388" rx="72" fill="#FFFFFF" stroke="#14140F" stroke-width="36"/>
</svg>"""


def font_css():
    faces = [("Archivo", 500, "Archivo-Medium"), ("Archivo", 700, "Archivo-Bold"),
             ("Archivo", 800, "Archivo-ExtraBold"), ("Archivo", 900, "Archivo-Black"),
             ("Space Mono", 400, "SpaceMono-Regular"), ("Space Mono", 700, "SpaceMono-Bold")]
    return "\n".join(f'@font-face {{ font-family: "{f}"; font-weight: {w}; src: url("{(FONTS / n).as_uri()}.ttf"); }}'
                     for f, w, n in faces)


def page(lang, width, height, body, transparent=False):
    fallback = FALLBACK.get(lang, "")
    stack = f'Archivo, {fallback + ", " if fallback else ""}system-ui, "Helvetica Neue", sans-serif'
    mono = f'"Space Mono", {fallback + ", " if fallback else ""}ui-monospace, monospace'
    track = lang in TRACKED
    return f"""<!doctype html><html lang="{lang}" dir="{'rtl' if lang in RTL else 'ltr'}"><head><meta charset="utf-8">
<style>{font_css()}
html, body {{ margin: 0; width: {width}px; height: {height}px; overflow: hidden;
  background: {'transparent' if transparent else '#000'}; }}
body {{ font-family: {stack}; -webkit-font-smoothing: antialiased; }}
.abs {{ position: absolute; }}
.kicker {{ font: 700 var(--k) {mono}; letter-spacing: {'0.18em' if track else '0'}; text-transform: uppercase; }}
.title {{ margin: 0; font-weight: 900; line-height: {'1.02' if track else '1.18'}; letter-spacing: {'-0.02em' if track else '0'}; }}
.sub {{ margin: 0; font-weight: 600; line-height: 1.4; }}
.caption {{ display: flex; flex-direction: column; }}
.caption {{ box-sizing: border-box; }}
.shot {{ display: block; width: 100%; height: 100%; object-fit: cover; object-position: top; }}
</style></head><body>{body}
<script>
document.fonts.ready.then(() => {{
  for (const box of document.querySelectorAll(".caption[data-bottom]")) {{
    const title = box.querySelector(".title"), limit = +box.dataset.bottom;
    let size = parseFloat(getComputedStyle(title).fontSize);
    while (box.offsetTop + box.offsetHeight > limit && size > 12) {{ size *= 0.96; title.style.fontSize = size + "px"; }}
  }}
}});
</script></body></html>"""


def t(lang, key):
    return html.escape(CAPTIONS.get(lang, {}).get(key) or CAPTIONS["en"][key])


def caption(lang, kicker, title, *, left, right, top, k, size, gap, ink, accent=None, sub=None, sub_ink=None, sub_size=None,
            bottom=None):
    """The kicker over the headline. A headline that would run past `bottom` (in the same
    coordinates as `top`) is set smaller until it fits: some languages run much longer."""
    extra = f'<p class="sub" style="color: {sub_ink}; font-size: {sub_size}px; margin-top: 4px;">{t(lang, sub)}</p>' if sub else ""
    fit = f' data-bottom="{bottom}"' if bottom else ""
    return (f'<div class="abs caption"{fit} style="left: {left}px; right: {right}px; top: {top}px; gap: {gap}px;">'
            f'<span class="kicker" style="--k: {k}px; color: {accent or ink};">{t(lang, kicker)}</span>'
            f'<h1 class="title" style="font-size: {size}px; color: {ink};">{t(lang, title)}</h1>{extra}</div>')


def img(path):
    return f'<img class="shot" src="{Path(path).as_uri()}">'


# MARK: Screenshots

def iphone_shots(lang, raw):
    """1320 x 2868, drawn at 440 x 956 and scaled 3x, as the design's artboards are."""
    def portrait(bg, ink, kicker, title, shot):
        return (f'<div class="abs" style="inset: 0; background: {bg};"></div>'
                f'<div class="abs" style="left: 0; top: 0; width: 440px; height: 956px; transform: scale(3); transform-origin: 0 0;">'
                + caption(lang, kicker, title, left=32, right=32, top=64, k=14, size=38, gap=12, ink=ink, bottom=200)
                + f'<div class="abs" style="left: 40px; top: 214px; width: 359px; height: 776px; border-radius: 44px; overflow: hidden; box-shadow: 0 0 0 6px {ink};">{img(raw / shot)}</div></div>')

    # The wall: the phone on its side, 360 wide at the screen's own 2868:1320.
    inner_h = round(360 * 1320 / 2868)
    wall = (f'<div class="abs" style="inset: 0; background: {WALL};"></div>'
            f'<div class="abs" style="left: 0; top: 0; width: 440px; height: 956px; transform: scale(3); transform-origin: 0 0;">'
            f'<svg class="abs" width="440" height="956" viewBox="0 0 440 956" style="left: 0; top: 0;" aria-hidden="true">'
            f'<defs><radialGradient id="g" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="{YELLOW}" stop-opacity="0.2"/>'
            f'<stop offset="1" stop-color="{YELLOW}" stop-opacity="0"/></radialGradient></defs>'
            f'<rect x="0" y="900" width="440" height="56" fill="#0A0A0E"/><path d="M0 900 H440" stroke="#1C1C24" stroke-width="2"/>'
            f'<ellipse cx="220" cy="{420 + (inner_h + 20) / 2}" rx="270" ry="180" fill="url(#g)"/>'
            f'<rect x="52" y="690" width="18" height="30" rx="3" fill="none" stroke="#2A2A34" stroke-width="3"/>'
            f'<path d="M340 {420 + inner_h + 20} C340 {520 + inner_h} 328 750 340 800" fill="none" stroke="#8C8C9A" stroke-width="3" stroke-linecap="round"/>'
            f'<rect x="325" y="800" width="30" height="38" rx="5" fill="none" stroke="#2A2A34" stroke-width="3"/>'
            f'<path d="M335 812 V822 M345 812 V822" stroke="#2A2A34" stroke-width="3" stroke-linecap="round"/></svg>'
            + caption(lang, "wall.kicker", "wall.iphone.title", left=32, right=32, top=64, k=14, size=38, gap=12,
                      ink="#FFFFFF", accent=YELLOW, sub="wall.iphone.sub", sub_ink="#C4C4CE", sub_size=17, bottom=400)
            + f'<div class="abs" style="left: 30px; top: 420px; width: 380px; box-sizing: border-box; padding: 10px; border-radius: 26px; background: #1A1A22; box-shadow: 0 0 0 3px #FFFFFF;">'
            f'<div style="width: 360px; height: {inner_h}px; border-radius: 12px; overflow: hidden;">{img(raw / "wall.png")}</div></div></div>')
    return [
        ("01-live", portrait(YELLOW, INK, "live.kicker", "live.title", "board.png")),
        ("02-wall", wall),
        ("03-tap", portrait(CYAN, INK, "tap.kicker", "tap.title", "tapped.png")),
        ("04-lines", portrait(PAPER, "#14140F", "lines.kicker", "lines.title", "lines.png")),
    ]


def ipad_shots(lang, raw):
    """2752 x 2064, drawn at 1376 x 1032 and scaled 2x."""
    # The screen is 4:3, so it stands 700 tall and is centred, where the design's 16:9 ran wide.
    h = 700
    w = round(h * 2752 / 2064)

    def landscape(bg, ink, kicker, title, shot):
        return (f'<div class="abs" style="inset: 0; background: {bg};"></div>'
                f'<div class="abs" style="left: 0; top: 0; width: 1376px; height: 1032px; transform: scale(2); transform-origin: 0 0;">'
                + caption(lang, kicker, title, left=80, right=80, top=72, k=16, size=56, gap=14, ink=ink, bottom=228)
                + f'<div class="abs" style="left: {(1376 - w) // 2}px; top: 250px; width: {w}px; height: {h}px; border-radius: 28px; overflow: hidden; box-shadow: 0 0 0 8px {ink};">{img(raw / shot)}</div></div>')

    inner_w = 421
    inner_h = round(inner_w * 2752 / 2064)
    x0 = 480 if lang not in RTL else 80
    wall = (f'<div class="abs" style="inset: 0; background: {WALL};"></div>'
            f'<div class="abs" style="left: 0; top: 0; width: 1376px; height: 1032px; transform: scale(2); transform-origin: 0 0;">'
            f'<svg class="abs" width="1376" height="1032" viewBox="0 0 1376 1032" style="left: 0; top: 0;" aria-hidden="true">'
            f'<defs><radialGradient id="g" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="{YELLOW}" stop-opacity="0.18"/>'
            f'<stop offset="1" stop-color="{YELLOW}" stop-opacity="0"/></radialGradient></defs>'
            f'<rect x="0" y="970" width="1376" height="62" fill="#0A0A0E"/><path d="M0 970 H1376" stroke="#1C1C24" stroke-width="2"/>'
            f'<rect x="80" y="300" width="250" height="670" fill="none" stroke="#1C1C24" stroke-width="4"/>'
            f'<rect x="92" y="312" width="226" height="658" rx="4" fill="#101016" stroke="#2A2A34" stroke-width="5"/>'
            f'<rect x="120" y="344" width="170" height="250" rx="4" fill="none" stroke="#1C1C24" stroke-width="4"/>'
            f'<rect x="120" y="620" width="170" height="320" rx="4" fill="none" stroke="#1C1C24" stroke-width="4"/>'
            f'<circle cx="292" cy="640" r="9" fill="#3A3A46"/>'
            f'<rect x="380" y="600" width="24" height="38" rx="4" fill="none" stroke="#2A2A34" stroke-width="4"/>'
            f'<ellipse cx="880" cy="600" rx="420" ry="360" fill="url(#g)"/>'
            f'<path d="M1040 {250 + inner_h + 40} C1040 {300 + inner_h + 40} 1028 880 1040 920" fill="none" stroke="#8C8C9A" stroke-width="4" stroke-linecap="round"/>'
            f'<rect x="1025" y="920" width="30" height="40" rx="5" fill="none" stroke="#2A2A34" stroke-width="4"/>'
            f'<path d="M1035 932 V944 M1045 932 V944" stroke="#2A2A34" stroke-width="4" stroke-linecap="round"/></svg>'
            + caption(lang, "wall.kicker", "wall.ipad.title", left=x0, right=80 if lang not in RTL else 480, top=72,
                      k=16, size=56, gap=14, ink="#FFFFFF", accent=YELLOW, bottom=228)
            + f'<div class="abs" style="left: 650px; top: 250px; width: {inner_w + 40}px; box-sizing: border-box; padding: 20px; border-radius: 36px; background: #1A1A22; box-shadow: 0 0 0 3px #FFFFFF;">'
            f'<div style="width: {inner_w}px; height: {inner_h}px; border-radius: 16px; overflow: hidden;">{img(raw / "wall.png")}</div></div></div>')
    return [
        ("01-live", landscape(YELLOW, INK, "live.kicker", "live.title", "board.png")),
        ("02-wall", wall),
        ("03-tap", landscape(RED, INK, "tap.kicker", "tap.title", "tapped.png")),
        ("04-routes", landscape(CYAN, INK, "routes.kicker", "routes.title", "routes.png")),
    ]


def mac_shots(lang, raw):
    """2880 x 1800, drawn at 1440 x 900 and scaled 2x. The window is the app's own, title bar and
    all, where the design drew one."""
    h = 651
    w = round(h * 1.6)

    def window(bg, ink, kicker, title, shot, accent=None):
        return (f'<div class="abs" style="inset: 0; background: {bg};"></div>'
                f'<div class="abs" style="left: 0; top: 0; width: 1440px; height: 900px; transform: scale(2); transform-origin: 0 0;">'
                + caption(lang, kicker, title, left=169, right=169, top=56, k=15, size=50, gap=12, ink=ink, accent=accent, bottom=184)
                + f'<div class="abs" style="left: {(1440 - w) // 2}px; top: 196px; width: {w}px; height: {h}px; border-radius: 12px; overflow: hidden; '
                f'box-shadow: 0 0 0 1px rgba(8, 8, 11, 0.6), 0 28px 60px rgba(8, 8, 11, 0.35);">{img(raw / shot)}</div></div>')
    return [
        ("01-live", window(YELLOW, INK, "live.kicker", "live.title", "board.png")),
        ("02-tap", window(RED, INK, "tap.kicker", "tap.title", "tapped.png")),
        ("03-lines", window(WALL, "#FFFFFF", "lines.kicker", "lines.title", "lines.png", accent=YELLOW)),
        ("04-routes", window(CYAN, INK, "routes.kicker", "routes.title", "routes.png")),
    ]


def mac_scenes(lang):
    """1920 x 1080, drawn at 960 x 540 and scaled 2x: the caption on top, the window below."""
    wrap = lambda inner: f'<div class="abs" style="left: 0; top: 0; width: 960px; height: 540px; transform: scale(2); transform-origin: 0 0;">{inner}</div>'
    band = lambda kicker, title, accent: (f'<div class="abs" style="left: 0; top: 0; width: 960px; height: 112px; background: {BAND};"></div>'
                                          + caption(lang, kicker, title, left=106, right=106, top=22, k=14, size=36, gap=8,
                                                    ink="#FFFFFF", accent=accent, bottom=106))
    h = 400
    w = round(h * 1.6)
    x, y = (960 - w) // 2, 122
    ground = wrap(f'<div class="abs" style="inset: 0; width: 960px; height: 540px; background: {BAND};"></div>')
    top = lambda kicker, title, accent: wrap(ring(x, y, w + 4, h + 4, 10, 2, "#2A2A34") + band(kicker, title, accent))
    return (1920, 1080), [
        dict(clip="board-clip", seconds=7.2, ground=ground, top=top("live.kicker", "live.title", YELLOW), box=(x, y, w, h), scale=2),
        dict(clip="tapped-clip", seconds=5.4, ground=ground, top=top("tap.kicker", "tap.title", RED), box=(x, y, w, h), scale=2),
        dict(clip="lines.png", seconds=5.0, ground=ground, top=top("lines.kicker", "lines.title", CYAN), box=(x, y, w, h), scale=2),
        dict(clip=None, seconds=5.6, ground=wrap(end_card(lang, 960, 540, 150, 42)), top=None),
    ]


# MARK: Previews

# Each scene as (clip or None, seconds). Cross-fades of FADE s overlap them, 22 s in all.
FADE = 0.4
FPS = 30


def ring(x, y, w, h, radius, width, color):
    """A device outline around the clip's box (x, y, w - 2 width, h - 2 width): its inside edge is
    rounded to `radius`, and the border paints the wedges between that curve and the clip's square
    corners, so the clip reads as a rounded screen."""
    return (f'<div class="abs" style="left: {x - width}px; top: {y - width}px; width: {w}px; height: {h}px; '
            f'box-sizing: border-box; border: {width}px solid {color}; border-radius: {radius + width}px;"></div>')


def iphone_scenes(lang):
    """886 x 1920, drawn at 443 x 960 and scaled 2x. The clips stand in a phone outline above the
    caption band; the wall scene has the phone on its side, hung over the design's hallway."""
    band = lambda kicker, title: (f'<div class="abs" style="left: 0; top: 720px; width: 443px; height: 240px; background: {BAND};"></div>'
                                  + caption(lang, kicker, title, left=24, right=24, top=756, k=14, size=36, gap=12,
                                            ink="#FFFFFF", accent=YELLOW, bottom=936))
    wrap = lambda inner: f'<div class="abs" style="left: 0; top: 0; width: 443px; height: 960px; transform: scale(2); transform-origin: 0 0;">{inner}</div>'

    # Portrait: the screen 640 tall at 1320:2868, centred over the band.
    ph = 640
    pw = round(ph * 1320 / 2868)
    px, py = (443 - pw) // 2, 40
    portrait_ground = wrap(f'<div class="abs" style="inset: 0; width: 443px; height: 960px; background: {NIGHT};"></div>')

    def portrait_top(kicker, title):
        return wrap(ring(px, py, pw + 12, ph + 12, 34, 6, "#2A2A34") + band(kicker, title))

    # The wall: the phone on its side, 380 wide.
    lw = 380
    lh = round(lw * 1320 / 2868)
    lx, ly = (443 - lw) // 2, 300
    wall_ground = wrap(
        f'<div class="abs" style="inset: 0; width: 443px; height: 960px; background: {WALL};"></div>'
        f'<svg class="abs" width="443" height="720" viewBox="0 0 443 720" style="left: 0; top: 0;" aria-hidden="true">'
        f'<defs><radialGradient id="g" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="{YELLOW}" stop-opacity="0.22"/>'
        f'<stop offset="1" stop-color="{YELLOW}" stop-opacity="0"/></radialGradient></defs>'
        f'<rect x="0" y="660" width="443" height="60" fill="#0A0A0E"/><path d="M0 660 H443" stroke="#1C1C24" stroke-width="2"/>'
        f'<ellipse cx="221" cy="{ly + lh / 2}" rx="260" ry="170" fill="url(#g)"/>'
        f'<path d="M340 {ly + lh + 12} C340 {ly + lh + 80} 328 560 340 610" fill="none" stroke="#8C8C9A" stroke-width="3" stroke-linecap="round"/>'
        f'<rect x="325" y="610" width="30" height="38" rx="5" fill="none" stroke="#2A2A34" stroke-width="3"/>'
        f'<path d="M335 622 V632 M345 622 V632" stroke="#2A2A34" stroke-width="3" stroke-linecap="round"/></svg>')
    wall_top = wrap(ring(lx, ly, lw + 20, lh + 20, 10, 10, "#1A1A22")
                    + f'<div class="abs" style="left: {lx - 13}px; top: {ly - 13}px; width: {lw + 20}px; height: {lh + 20}px; border: 3px solid #FFFFFF; border-radius: 24px;"></div>'
                    + band("wall.kicker", "wall.iphone.video"))
    end = end_card(lang, 443, 960, 180, 38)
    return (886, 1920), [
        dict(clip="board.mov", seconds=6.8, ground=portrait_ground, top=portrait_top("live.kicker", "live.title"),
             box=(px, py, pw, ph), scale=2),
        dict(clip="wall.mov", seconds=5.6, ground=wall_ground, top=wall_top, box=(lx, ly, lw, lh), scale=2, landscape=True),
        dict(clip="stops.mov", seconds=5.2, ground=portrait_ground, top=portrait_top("nearby.kicker", "nearby.title"),
             box=(px, py, pw, ph), scale=2),
        dict(clip=None, seconds=5.6, ground=wrap(end), top=None),
    ]


def ipad_scenes(lang):
    """1600 x 1200, drawn at 800 x 600 and scaled 2x: the caption band on top, the screen below."""
    wrap = lambda inner: f'<div class="abs" style="left: 0; top: 0; width: 800px; height: 600px; transform: scale(2); transform-origin: 0 0;">{inner}</div>'
    band = lambda kicker, title, accent=YELLOW: (f'<div class="abs" style="left: 0; top: 0; width: 800px; height: 150px; background: {BAND};"></div>'
                                                 + caption(lang, kicker, title, left=36, right=36, top=30, k=14, size=38, gap=10,
                                                           ink="#FFFFFF", accent=accent, bottom=140))
    h = 410
    w = round(h * 2752 / 2064)
    x, y = (800 - w) // 2, 168
    ground = wrap(f'<div class="abs" style="inset: 0; width: 800px; height: 600px; background: {NIGHT};"></div>')
    top = lambda kicker, title, accent=YELLOW: wrap(ring(x, y, w + 12, h + 12, 16, 6, "#2A2A34") + band(kicker, title, accent))

    ph = 400
    pw = round(ph * 2064 / 2752)
    wx, wy = (800 - pw) // 2 + 60, 176
    wall_ground = wrap(
        f'<div class="abs" style="inset: 0; width: 800px; height: 600px; background: {WALL};"></div>'
        f'<svg class="abs" width="800" height="600" viewBox="0 0 800 600" style="left: 0; top: 0;" aria-hidden="true">'
        f'<defs><radialGradient id="g" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="{YELLOW}" stop-opacity="0.2"/>'
        f'<stop offset="1" stop-color="{YELLOW}" stop-opacity="0"/></radialGradient></defs>'
        f'<rect x="0" y="584" width="800" height="16" fill="#0A0A0E"/>'
        f'<rect x="90" y="200" width="150" height="384" fill="none" stroke="#1C1C24" stroke-width="3"/>'
        f'<rect x="98" y="208" width="134" height="376" rx="3" fill="#101016" stroke="#2A2A34" stroke-width="4"/>'
        f'<circle cx="222" cy="400" r="6" fill="#3A3A46"/>'
        f'<ellipse cx="{wx + pw / 2}" cy="{wy + ph / 2}" rx="300" ry="240" fill="url(#g)"/></svg>')
    wall_top = wrap(ring(wx, wy, pw + 24, ph + 24, 12, 12, "#1A1A22")
                    + f'<div class="abs" style="left: {wx - 15}px; top: {wy - 15}px; width: {pw + 24}px; height: {ph + 24}px; border: 3px solid #FFFFFF; border-radius: 28px;"></div>'
                    + band("wall.kicker", "wall.ipad.video"))
    end = end_card(lang, 800, 600, 150, 42)
    return (1600, 1200), [
        dict(clip="board.mov", seconds=7.2, ground=ground, top=top("live.kicker", "live.title"), box=(x, y, w, h), scale=2, landscape=True),
        dict(clip="tapped.mov", seconds=5.4, ground=ground, top=top("tap.kicker", "tap.title", RED), box=(x, y, w, h), scale=2, landscape=True),
        dict(clip="wall.mov", seconds=5.0, ground=wall_ground, top=wall_top, box=(wx, wy, pw, ph), scale=2),
        dict(clip=None, seconds=5.6, ground=wrap(end), top=None),
    ]


def end_card(lang, w, h, icon, size):
    return (f'<div class="abs" style="inset: 0; width: {w}px; height: {h}px; background: {NIGHT}; display: flex; flex-direction: column; '
            f'align-items: center; justify-content: center; gap: 34px;">'
            f'<div style="width: {icon}px; height: {icon}px; border-radius: {icon * 0.225}px; overflow: hidden;">{ICON_SVG}</div>'
            f'<div style="display: flex; flex-direction: column; align-items: center; gap: 14px; padding: 0 32px; text-align: center;">'
            f'<span class="title" style="font-size: {size}px; color: #FFFFFF;">{t(lang, "live.title")}</span>'
            f'<span class="kicker" style="--k: 15px; color: #A0A0AE;">iPhone · iPad · Mac</span></div></div>')


# MARK: Creative asset

def creative():
    """The universal creative asset, 5244 x 2950: the product page header and the search results
    artwork on iPhone and iPad (iOS 27), drawn at 2622 x 1475 and scaled 2x. No words, so the one
    upload serves every language: the App Store sets the app's name over it. The icon's three lines
    run across into the stop, behind the board on an iPad and an iPhone, all on the mock's Harbor
    Gate. The header crops to 3840 x 1646 and search results to 3840 x 2560, so what matters stays in
    x 205..2417, y 176..1300; the product page covers the lower half with the app's card, so the
    route maps sit high."""
    w, h = 2622, 1475
    shots = ROOT / "screenshots"
    ipad, iphone = shots / "ipad/landscape/dark/board-2-lines.png", shots / "iphone/portrait/dark/board-2-lines.png"
    k, cy, x0, stop = 1.12, 738, 330, 2200
    y = lambda v: cy + (v - 512) * k
    glow = lambda name, colour, opacity: (f'<radialGradient id="{name}" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="{colour}" '
                                          f'stop-opacity="{opacity}"/><stop offset="1" stop-color="{colour}" stop-opacity="0"/></radialGradient>')
    svg = lambda inner: f'<svg class="abs" width="{w}" height="{h}" viewBox="0 0 {w} {h}" style="left: 0; top: 0;" aria-hidden="true">{inner}</svg>'
    lines = svg(f'<defs>{glow("gy", YELLOW, 0.16)}{glow("gr", RED, 0.12)}{glow("gc", CYAN, 0.10)}</defs>'
                f'<ellipse cx="1311" cy="760" rx="1100" ry="620" fill="url(#gy)"/>'
                f'<ellipse cx="380" cy="300" rx="700" ry="520" fill="url(#gr)"/><ellipse cx="420" cy="1250" rx="700" ry="520" fill="url(#gc)"/>'
                f'<g fill="none" stroke-width="{76 * k}" stroke-linecap="round" opacity="0.85">'
                f'<path d="M{x0} -120 V{y(230)} C{x0} {y(330)} {x0 + 60 * k} {y(400)} {x0 + 160 * k} {y(400)} H{stop}" stroke="#D32029"/>'
                f'<path d="M{x0} {h + 120} V{y(794)} C{x0} {y(694)} {x0 + 60 * k} {y(624)} {x0 + 160 * k} {y(624)} H{stop}" stroke="#0E7C86"/>'
                f'<path d="M-120 {y(512)} H{stop}" stroke="#EFA400"/></g>')
    the_stop = svg(f'<rect x="{stop - 72 * k}" y="{y(318)}" width="{144 * k}" height="{388 * k}" rx="{72 * k}" fill="#FFFFFF" '
                   f'stroke="{NIGHT}" stroke-width="{30 * k}"/>')
    def device(x, top, dw, dh, radius, bezel, shot):
        return (f'<div class="abs" style="left: {x - bezel}px; top: {top - bezel}px; width: {dw + 2 * bezel}px; height: {dh + 2 * bezel}px; '
                f'border-radius: {radius + bezel}px; background: #16161C; box-shadow: 0 0 0 3px #2E2E38, 0 40px 120px rgba(0, 0, 0, 0.65);"></div>'
                f'<div class="abs" style="left: {x}px; top: {top}px; width: {dw}px; height: {dh}px; border-radius: {radius}px; overflow: hidden;">{img(shot)}</div>')
    pad_h = 760
    pad_w = round(pad_h * 2752 / 2064)
    pad_x = 1311 - pad_w // 2 - 120
    phone_h = 900
    phone_w = round(phone_h * 1320 / 2868)
    wrap = lambda inner: f'<div class="abs" style="left: 0; top: 0; width: {w}px; height: {h}px; transform: scale(2); transform-origin: 0 0;">{inner}</div>'
    ground = f'<div class="abs" style="inset: 0; background: {NIGHT};"></div>' + wrap(lines)
    top = wrap(the_stop + device(pad_x, 330, pad_w, pad_h, 30, 22, ipad)
               + device(pad_x + pad_w - phone_w // 2 - 40, 300, phone_w, phone_h, 58, 16, iphone))
    out = FINAL / "creative"
    out.mkdir(parents=True, exist_ok=True)
    chrome(page("en", w * 2, h * 2, ground + top), out / "universal.png", w * 2, h * 2)
    print(f"   {(out / 'universal.png').relative_to(ROOT)}")
    creative_videos(out)


# The videos: no devices, just the icon's three lines across a dark city, running together where
# they share a road and parting again. Red (18) joins yellow (41) from the top, teal (7) joins them
# from below for the trunk through the big stop, then red leaves upward and teal later downward.
# Every bus slows into each stop on its line, waits, and pulls away.
LOOP, CRUISE = 24, 110          # seconds; scene points a second between stops
PITCH, LINE_W, CORNER = 78, 60, 190
DWELL, EASE = 120, 220          # what a stop takes, in the points a bus would have run: waiting, and braking plus pulling away
TRUNK = 600
PUCK_W, PUCK_H, PUCK_R, PUCK_FONT, PUCK_HALO, PUCK_GLOW = 88, 72, 20, 40, 9, 40
LINES = [  # number, colour, ink, corners (off the canvas at each end), buses on the line per loop, phase
    ("18", "#D32029", "#FFFFFF", [(330, -160), (330, TRUNK - PITCH), (1700, TRUNK - PITCH), (1700 + TRUNK - PITCH + 160, -160)], 2, 0.15),
    ("41", "#EFA400", INK, [(-160, TRUNK), (2782, TRUNK)], 2, 0.55),
    ("7", "#0E7C86", "#FFFFFF", [(560, 1635), (560, 1300), (560 + 1300 - TRUNK - PITCH, TRUNK + PITCH), (2250, TRUNK + PITCH),
                                 (2250 + 1635 - TRUNK - PITCH, 1635)], 2, 0.85),
]
# The stops: centre, the line's heading there (degrees), and the lines they serve.
STOPS = [
    (330, 210, 90, "18"), (880, TRUNK - PITCH / 2, 0, "18 41"), (1440, TRUNK, 0, "18 41 7"),
    (1990, TRUNK + PITCH / 2, 0, "41 7"), (871, 989, -45, "7"), (1960, TRUNK - PITCH - 260, -45, "18"),
    (560, 1420, 90, "7"),
]
# Other lines of the city, faint, without buses.
STREETS = [[(-160, 1210), (2782, 1210)], [(2060, 1635), (2060, 960), (2735, 285), (2735, -160)],
           [(1150, 1635), (1150, 1380), (1395, 1135), (2782, 1135)]]


def route(corners, radius=CORNER, step=2.0):
    """SVG path data for a line through `corners`, each turned on a curve, and the same line as points
    every `step` scene points with the distance along it at each."""
    unit = lambda a, b: ((b[0] - a[0]) / ((b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2) ** 0.5,
                         (b[1] - a[1]) / ((b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2) ** 0.5)
    data, fine = f"M{corners[0][0]:.1f} {corners[0][1]:.1f}", [corners[0]]
    for a, b, c in zip(corners, corners[1:], corners[2:]):
        (ux, uy), (vx, vy) = unit(a, b), unit(b, c)
        p, q = (b[0] - ux * radius, b[1] - uy * radius), (b[0] + vx * radius, b[1] + vy * radius)
        data += f" L{p[0]:.1f} {p[1]:.1f} Q{b[0]} {b[1]} {q[0]:.1f} {q[1]:.1f}"
        fine += [p] + [((1 - u) ** 2 * p[0] + 2 * (1 - u) * u * b[0] + u ** 2 * q[0], (1 - u) ** 2 * p[1] + 2 * (1 - u) * u * b[1] + u ** 2 * q[1])
                       for u in (i / 200 for i in range(1, 201))]
    data += f" L{corners[-1][0]} {corners[-1][1]}"
    fine.append(corners[-1])
    points, lengths = [fine[0]], [0.0]
    for (ax, ay), (bx, by) in zip(fine, fine[1:]):
        seg = ((bx - ax) ** 2 + (by - ay) ** 2) ** 0.5
        n = max(1, int(seg / step))
        for i in range(1, n + 1):
            x, y = ax + (bx - ax) * i / n, ay + (by - ay) * i / n
            lengths.append(lengths[-1] + ((x - points[-1][0]) ** 2 + (y - points[-1][1]) ** 2) ** 0.5)
            points.append((x, y))
    return data, points, lengths


def at(points, lengths, s):
    i = min(max(bisect.bisect_left(lengths, s), 1), len(lengths) - 1)
    (ax, ay), (bx, by), la, lb = points[i - 1], points[i], lengths[i - 1], lengths[i]
    f = 0 if lb == la else min(max((s - la) / (lb - la), 0), 1)
    return ax + (bx - ax) * f, ay + (by - ay) * f


def held(x):
    """How much of a bus's progress a stop `x` run-points away takes: all of it while it waits (the
    middle DWELL), easing in and out over EASE either side, so it brakes and pulls away smoothly."""
    x, a = abs(x), DWELL / 2
    return 1.0 if x <= a else 0.0 if x >= a + EASE else 0.5 * (1 + math.cos(math.pi * (x - a) / EASE))


def taken(x):
    """The integral of held() up to `x`: the run-points a stop has taken by then."""
    a, whole = DWELL / 2, DWELL + EASE
    if x <= -a - EASE:
        return 0.0
    if x >= a + EASE:
        return whole
    if x < -a:
        y = x + a + EASE  # 0..EASE
        return 0.5 * (y - EASE / math.pi * math.sin(math.pi * y / EASE))
    if x <= a:
        return EASE / 2 + (x + a)
    return whole - taken(-x)


def city():
    """The scene: its ground (SVG), and each line's number, colours, points and lengths, stops along
    it (as distances) and buses."""
    w, h = 2622, 1475
    glow = lambda name, colour, opacity: (f'<radialGradient id="{name}" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="{colour}" '
                                          f'stop-opacity="{opacity}"/><stop offset="1" stop-color="{colour}" stop-opacity="0"/></radialGradient>')
    lines = [(number, fill, ink, *route(corners), buses, phase) for number, fill, ink, corners, buses, phase in LINES]
    streets = "".join(f'<path d="{route(c, 140)[0]}"/>' for c in STREETS)
    tracks = "".join(f'<path d="{data}" stroke="{fill}"/>' for _, fill, _, data, *_ in lines)
    pills = ""
    for x, y, heading, served in STOPS:
        n = len(served.split())
        length, thick = (n - 1) * PITCH + LINE_W + 34, 46
        pills += (f'<rect x="{-thick / 2}" y="{-length / 2}" width="{thick}" height="{length}" rx="{thick / 2}" fill="#FFFFFF" '
                  f'stroke="{NIGHT}" stroke-width="10" transform="translate({x} {y}) rotate({heading})"/>')
    ground = (f'<svg class="abs" width="{w}" height="{h}" viewBox="0 0 {w} {h}" style="left: 0; top: 0;" aria-hidden="true">'
              f'<defs>{glow("gy", YELLOW, 0.13)}{glow("gr", RED, 0.12)}{glow("gc", CYAN, 0.10)}'
              f'<radialGradient id="vignette" cx="0.5" cy="0.45" r="0.75"><stop offset="0.55" stop-color="#000" stop-opacity="0"/>'
              f'<stop offset="1" stop-color="#000" stop-opacity="0.55"/></radialGradient></defs>'
              f'<rect width="{w}" height="{h}" fill="{NIGHT}"/>'
              f'<ellipse cx="1400" cy="{TRUNK}" rx="1250" ry="560" fill="url(#gy)"/>'
              f'<ellipse cx="420" cy="260" rx="760" ry="520" fill="url(#gr)"/><ellipse cx="2200" cy="1180" rx="820" ry="560" fill="url(#gc)"/>'
              f'<g fill="none" stroke="#17171F" stroke-width="34" stroke-linecap="round" stroke-linejoin="round">{streets}</g>'
              f'<g fill="none" stroke-width="{LINE_W}" stroke-linecap="round" opacity="0.92">{tracks}</g>{pills}'
              f'<rect width="{w}" height="{h}" fill="url(#vignette)"/></svg>')
    out = []
    for number, fill, ink, _, points, lengths, buses, phase in lines:
        stops = []
        for x, y, _, served in STOPS:
            if number in served.split():
                stops.append(min(range(len(points)), key=lambda i: (points[i][0] - x) ** 2 + (points[i][1] - y) ** 2))
        stops = sorted(lengths[i] for i in stops)
        out.append((number, fill, ink, points, lengths, stops, buses, phase))
    return w, h, ground, out


def buses_at(line, t):
    """Where each bus on `line` is `t` seconds into the loop. A bus runs at CRUISE in "run" points; a
    stop holds it for DWELL + EASE of them, so it is at distance run - (what the stops took by then)."""
    _, _, _, points, lengths, stops, buses, phase = line
    centres = [s + (DWELL + EASE) * (k + 0.5) for k, s in enumerate(stops)]  # each stop's middle, in run points
    total = lengths[-1] + (DWELL + EASE) * len(stops)
    gap = CRUISE * LOOP / buses
    run = (phase * gap + CRUISE * t) % gap
    found = []
    while run < total:
        found.append(at(points, lengths, run - sum(taken(run - c) for c in centres)))
        run += gap
    return found


def creative_videos(out):
    """The header (21:9, 3840 x 1646) and search results (3:2, 3840 x 2560) videos: the city with
    the buses running, cropped about its middle as the App Store crops the still, LOOP seconds at
    30 fps that loop seamlessly (both placements loop and play muted). Chrome draws the ground and
    each puck at 2x; Pillow lays the pucks on per frame, a fraction of a pixel at a time; ffmpeg
    encodes."""
    from PIL import Image, ImageChops

    w, h, ground, lines = city()
    work = Path(tempfile.mkdtemp(dir=out))
    try:
        wrap = lambda inner, ww, hh: f'<div class="abs" style="left: 0; top: 0; width: {ww}px; height: {hh}px; transform: scale(2); transform-origin: 0 0;">{inner}</div>'
        chrome(page("en", w * 2, h * 2, wrap(ground, w, h)), work / "ground.png", w * 2, h * 2)
        m = PUCK_GLOW + PUCK_HALO
        pw, ph = PUCK_W + 2 * m, PUCK_H + 2 * m
        for number, fill, ink, *_ in lines:
            puck = (f'<div class="abs" style="left: {PUCK_GLOW}px; top: {PUCK_GLOW}px; width: {PUCK_W + 2 * PUCK_HALO}px; height: {PUCK_H + 2 * PUCK_HALO}px; '
                    f'border-radius: {PUCK_R + PUCK_HALO}px; background: {NIGHT}; box-shadow: 0 0 {PUCK_GLOW * 0.8}px {fill}66;"></div>'
                    f'<div class="abs" style="left: {m}px; top: {m}px; width: {PUCK_W}px; height: {PUCK_H}px; border-radius: {PUCK_R}px; '
                    f'background: {fill}; color: {ink}; display: flex; align-items: center; justify-content: center; '
                    f'font-weight: 900; font-size: {PUCK_FONT}px; line-height: 1;">{number}</div>')
            chrome(page("en", pw * 2, ph * 2, wrap(puck, pw, ph), transparent=True), work / f"puck-{number}.png", pw * 2, ph * 2, transparent=True)
        full = Image.open(work / "ground.png").convert("RGB")
        pucks = [Image.open(work / f"puck-{number}.png").convert("RGBa") for number, *_ in lines]

        for name, (W, H) in [("header", (3840, 1646)), ("search", (3840, 2560))]:
            cw, ch = min(w, h * W / H), min(h, w * H / W)
            cx, cy, scale = (w - cw) / 2, (h - ch) / 2, W / cw
            still = full.crop(tuple(round(v * 2) for v in (cx, cy, cx + cw, cy + ch))).resize((W, H), Image.LANCZOS)
            # A touch of fixed grain, so the dim glows don't band once encoded.
            still = ImageChops.add(still, Image.merge("RGB", [Image.effect_noise((W, H), 1.6)] * 3), 1, -128)
            sprites = [p.resize((round(pw * scale), round(ph * scale)), Image.LANCZOS) for p in pucks]

            target = out / f"{name}.mp4"
            encoder = subprocess.Popen(
                ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
                 "-f", "lavfi", "-t", f"{LOOP}", "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
                 "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-profile:v", "high", "-preset", "slow", "-crf", "16", "-g", str(LOOP * FPS),
                 "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-t", f"{LOOP}", "-movflags", "+faststart", str(target)],
                stdin=subprocess.PIPE)
            for i in range(LOOP * FPS):
                frame = still.copy()
                for line, sprite in zip(lines, sprites):
                    for bx, by in buses_at(line, i / FPS):
                        x, y = (bx - cx) * scale - sprite.width / 2, (by - cy) * scale - sprite.height / 2
                        if -sprite.width < x < W and -sprite.height < y < H:
                            ix, iy = math.floor(x), math.floor(y)
                            moved = sprite.transform((sprite.width + 1, sprite.height + 1), Image.AFFINE,
                                                     (1, 0, ix - x, 0, 1, iy - y), resample=Image.BICUBIC).convert("RGBA")
                            frame.paste(moved.convert("RGB"), (ix, iy), moved.getchannel("A"))
                encoder.stdin.write(frame.tobytes())
            encoder.stdin.close()
            if encoder.wait():
                sys.exit(f"ffmpeg failed on {target}")
            print(f"   {target.relative_to(ROOT)} ({LOOP} s)")
    finally:
        shutil.rmtree(work)


# MARK: Rendering

def chrome(html_text, out, width, height, transparent=False):
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False, dir=out.parent) as f:
        f.write(html_text)
    try:
        args = [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                "--allow-file-access-from-files", f"--window-size={width},{height}", f"--screenshot={out}",
                "--virtual-time-budget=3000"]
        if transparent:
            args.append("--default-background-color=00000000")
        subprocess.run(args + [Path(f.name).as_uri()], check=True, capture_output=True)
    finally:
        os.unlink(f.name)


def render_shots(device, lang):
    raw, out = RAW / device / lang, FINAL / device / lang
    size = {"iphone": (1320, 2868), "ipad": (2752, 2064), "mac": (2880, 1800)}[device]
    shots = {"iphone": iphone_shots, "ipad": ipad_shots, "mac": mac_shots}[device](lang, raw)
    out.mkdir(parents=True, exist_ok=True)
    for name, body in shots:
        target = out / f"{name}.png"
        chrome(page(lang, *size, body), target, *size)
        # No alpha: App Store Connect refuses screenshots with transparency.
        subprocess.run(["sips", "-s", "format", "jpeg", target, "--out", target.with_suffix(".jpg")], check=True, capture_output=True)
        subprocess.run(["sips", "-s", "format", "png", target.with_suffix(".jpg"), "--out", target], check=True, capture_output=True)
        target.with_suffix(".jpg").unlink()
        print(f"   final/{device}/{lang}/{name}.png")


def clip_input(clip, listing):
    """ffmpeg's input for a scene's footage: a recorded movie; a Mac run of window shots named
    after the millisecond each was taken at, each held until the next; or a still."""
    if clip.is_dir():
        frames = sorted(clip.glob("*.png"))
        times = [int(f.stem) / 1000 for f in frames] + [int(frames[-1].stem) / 1000 + 0.2]
        listing.write_text("".join(f"file '{f}'\nduration {times[i + 1] - times[i]:.3f}\n" for i, f in enumerate(frames))
                           + f"file '{frames[-1]}'\n")
        return ["-f", "concat", "-safe", "0", "-i", str(listing)]
    if clip.suffix == ".png":
        return ["-loop", "1", "-framerate", str(FPS), "-i", str(clip)]
    return ["-i", str(clip)]


def render_preview(device, lang):
    raw, out = RAW / device / lang, FINAL / device / lang
    (W, H), scenes = {"iphone": iphone_scenes, "ipad": ipad_scenes, "mac": mac_scenes}[device](lang)
    out.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(dir=out))
    try:
        segments = []
        for i, scene in enumerate(scenes):
            ground, top, seg = work / f"g{i}.png", work / f"t{i}.png", work / f"s{i}.mp4"
            chrome(page(lang, W, H, scene["ground"]), ground, W, H)
            inputs = ["-loop", "1", "-framerate", str(FPS), "-i", str(ground)]
            if scene["clip"]:
                chrome(page(lang, W, H, scene["top"], transparent=True), top, W, H, transparent=True)
                x, y, w, h = (v * scene["scale"] for v in scene["box"])
                # A clip shorter than its scene holds its last frame. A landscape clip is recorded in the
                # screen's portrait pixels: the iPhone's with a rotation tag, which ffmpeg applies as it
                # reads it; the iPad's without, so it is turned here as the stills are (sips -r 270).
                turn = "transpose=2," if scene.get("landscape") and untagged_portrait(raw / scene["clip"]) else ""
                # A recorded clip holds on the staged clock's first minute for about a second before it
                # runs (scripts/screenshots.sh sim_clip): kept, it reads as the board settling in.
                lead = 0.1 if scene["clip"].endswith(".mov") else 0
                graph = (f"[1:v]trim=start={lead},setpts=PTS-STARTPTS,fps={FPS},{turn}scale={w}:{h},"
                         f"tpad=stop_mode=clone:stop_duration=10[c];[0:v][c]overlay={x}:{y}:shortest=0[b];"
                         f"[b][2:v]overlay=0:0,format=yuv420p[v]")
                inputs += [*clip_input(raw / scene["clip"], work / f"c{i}.txt"),
                           "-loop", "1", "-framerate", str(FPS), "-i", str(top)]
            else:
                graph = "[0:v]format=yuv420p[v]"
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", graph, "-map", "[v]",
                            "-t", f"{scene['seconds']}", "-r", str(FPS), "-c:v", "libx264", "-preset", "slow", "-crf", "16",
                            "-pix_fmt", "yuv420p", str(seg)], check=True)
            segments.append((seg, scene["seconds"]))

        # Cross-fade the scenes, then add the silent stereo track App Store Connect asks for.
        inputs, chain, offset, last = [], [], 0.0, "0:v"
        for seg, _ in segments:
            inputs += ["-i", str(seg)]
        for i in range(1, len(segments)):
            offset += segments[i - 1][1] - FADE
            label = f"x{i}"
            chain.append(f"[{last}][{i}:v]xfade=transition=fade:duration={FADE}:offset={offset:.3f}[{label}]")
            last = label
        total = sum(s for _, s in segments) - FADE * (len(segments) - 1)
        target = out / "preview.mp4"
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs,
                        "-f", "lavfi", "-t", f"{total}", "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
                        "-filter_complex", ";".join(chain), "-map", f"[{last}]", "-map", f"{len(segments)}:a",
                        "-t", f"{total}", "-r", str(FPS), "-c:v", "libx264", "-profile:v", "high", "-level", "4.0",
                        "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "256k",
                        "-movflags", "+faststart", str(target)], check=True)
        print(f"   final/{device}/{lang}/preview.mp4 ({total:.1f} s)")
    finally:
        shutil.rmtree(work)


def untagged_portrait(clip):
    """A recording in portrait pixels that carries no rotation for ffmpeg to apply."""
    if clip.suffix != ".mov":
        return False
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                            "stream=width,height:stream_side_data=rotation", "-of", "csv=p=0", str(clip)],
                           capture_output=True, text=True, check=True).stdout.split()
    width, height, *rotation = probe[0].split(",") + probe[1:]
    return int(width) < int(height) and not any(r.strip(",") for r in rotation)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--languages", nargs="*")
    parser.add_argument("--devices", nargs="*", default=["iphone", "ipad", "mac"])
    parser.add_argument("--only", choices=["shots", "previews", "creative"])
    args = parser.parse_args()
    if args.only == "creative":
        return creative()
    for device in args.devices:
        languages = args.languages or sorted(p.name for p in (RAW / device).iterdir() if p.is_dir())
        for lang in languages:
            if not (RAW / device / lang).is_dir():
                sys.exit(f"No raw captures for {device}/{lang}: run scripts/screenshots.sh store first")
            if args.only != "previews":
                render_shots(device, lang)
            if args.only != "shots":
                render_preview(device, lang)


if __name__ == "__main__":
    main()
