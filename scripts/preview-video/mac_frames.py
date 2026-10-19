#!/usr/bin/env python3
"""Turns the Mac journey's window shots (<ms>.jpg, taken as fast as XCTest allows, about twelve a
second) into 30 fps frames: each frame blends the two shots around its moment, so the board's buses
glide; across a longer gap (a click, when nothing is filmed) the last shot is held.

    scripts/preview-video/mac_frames.py <shots folder> <frames folder>
"""
import bisect, sys
from pathlib import Path
from PIL import Image

shots_dir, frames_dir = Path(sys.argv[1]), Path(sys.argv[2])
frames_dir.mkdir(parents=True, exist_ok=True)
shots = sorted(shots_dir.glob("*.jpg"))
ms = [int(p.stem) for p in shots]
cache = {}


def load(i):
    if i not in cache:
        if len(cache) > 4:
            cache.pop(next(iter(cache)))
        cache[i] = Image.open(shots[i]).convert("RGB")
    return cache[i]


for n in range(ms[-1] * 30 // 1000 + 1):
    t = n * 1000 / 30
    i = max(0, bisect.bisect_right(ms, t) - 1)
    frame = load(i)
    if i + 1 < len(ms) and ms[i + 1] - ms[i] < 220:
        x = (t - ms[i]) / (ms[i + 1] - ms[i])
        if x > 0.02:
            frame = Image.blend(frame, load(i + 1), x)
    frame.save(frames_dir / f"{n:05d}.jpg", quality=92)
print(f"{n + 1} frames in {frames_dir}")
