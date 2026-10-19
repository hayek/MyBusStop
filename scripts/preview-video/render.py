#!/usr/bin/env python3
"""Renders the App Store previews from the recordings in build/preview (scripts/preview-video.sh
record makes them) to screenshots/store/final/<device>/en/preview.mp4.

    scripts/preview-video/render.py                 # iphone, ipad and mac
    scripts/preview-video/render.py ipad
    scripts/preview-video/render.py iphone --stills 1.5 20.8   # single frames, to check a cut
"""
import argparse, html, importlib, importlib.util, os, re, subprocess, sys, tempfile
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))
from engine import Cut, ROOT
import wall

BUILD = ROOT / "build/preview"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


def icon():
    """The design's app icon, drawn from store-art.py's SVG by Chrome."""
    out = BUILD / "icon.png"
    if out.exists():
        return
    svg = re.search(r'ICON_SVG = """(.*?)"""', (ROOT / "scripts/store-art.py").read_text(), re.S).group(1)
    svg = svg.replace('width="100%" height="100%"', 'width="1024" height="1024"')
    BUILD.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
        f.write(f'<html><body style="margin:0">{svg}</body></html>')
    try:
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                        "--window-size=1024,1024", f"--screenshot={out}", Path(f.name).as_uri()],
                       check=True, capture_output=True)
    finally:
        os.unlink(f.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("devices", nargs="*", default=["iphone", "ipad", "mac"])
    parser.add_argument("--stills", nargs="*", type=float)
    args = parser.parse_args()
    icon()
    for device in args.devices:
        cut = importlib.import_module(device)
        if not list(cut.frames.glob("*.jpg")):
            sys.exit(f"No recording in {cut.frames}; run scripts/preview-video.sh record {device}")
        if getattr(cut, "wall_mount", None) and not cut.wall_image.exists():
            wall.mount(cut.wall_image, **cut.wall_mount)
        if args.stills:
            Cut(cut).stills(args.stills, BUILD / f"{device}/stills")
            print(f"build/preview/{device}/stills")
            continue
        out = ROOT / f"screenshots/store/final/{device}/en/preview.mp4"
        out.parent.mkdir(parents=True, exist_ok=True)
        Cut(cut).encode(out)
        print(out.relative_to(ROOT))


if __name__ == "__main__":
    main()
