"""The Mac preview: 1920 x 1080, the app's window floating, filmed as window shots (frames made
by mac_frames.py). A Mac hangs on no wall: it ends on wall mode filling the window. Pinned to
build/preview/mac."""
from engine import ROOT, YELLOW, RED, CYAN
import wall

BUILD = ROOT / "build/preview"

W, H = 1920, 1080
frames = BUILD / "mac/frames"
first_frame, last_frame = 0, len(list(frames.glob("*.jpg"))) - 1
src_px_per_pt = 2.0            # 2560 px shots of a 1280 pt window
radius_pt, bezel_pt = 11, 1
touch_ref_k = 1.0
icon = BUILD / "icon.png"
wall_image = None
turn = None
glows = [((0.6, -0.5, 1.25, 0.45), (70, 52, 0)), ((-0.3, 0.55, 0.3, 1.5), (70, 14, 16)),
         ((-0.12, 0.0, 0.2, 0.5), (0, 36, 44))]
scrim_solid, scrim_end = 190, 232
kicker_size, title_size = 22, 56
cap_left, cap_top, cap_width, cap_center = 110, 62, 1700, False
end_icon, end_icon_y, end_title, end_text_y = 240, 420, 72, 590
end_lines = ["Every bus to your stop, live."]

def C(t0, t1, s0, s1):
    return dict(t0=t0, t1=t1, s0=s0, s1=s1, rot=0)

A, B1, B2, CC, D, E, F = (0.0, 3.0), (3.0, 6.1), (6.1, 9.0), (9.0, 12.6), (12.6, 16.0), (16.0, 19.3), (19.3, 24.3)
end = (24.3, 27.3)
total = end[1]

clips = [C(*A, 11.6, 15.26), C(*B1, 0.36, 4.93), C(*B2, 4.93, 10.65), C(*CC, 15.26, 21.63), C(*D, 21.63, 26.84),
         C(*E, 26.84, 35.22), C(F[0], end[0] + 0.5, 35.22, 41.9)]
taps = [(2.58, 950, 665), (6.71, 334, 279), (8.35, 130, 279), (10.19, 1094, 728), (21.78, 545, 328),
        (27.06, 1218, 86), (30.69, 827, 219), (34.01, 823, 660)]

REST = (640, 400, 960, 628, 1.0)
cam = [
    (0.0, 640, 560, 960, 650, 1.45), (1.9, 640, 540, 960, 650, 1.32), (2.95, *REST),
    (3.0, *REST), (3.8, 950, 520, 960, 640, 1.32), (6.05, 950, 520, 960, 640, 1.32),
    (6.1, 640, 430, 960, 640, 1.05), (8.95, 640, 430, 960, 640, 1.05),
    (9.0, *REST), (12.55, 640, 330, 960, 620, 1.25),
    (12.65, 640, 330, 960, 620, 1.25), (13.6, 523, 520, 960, 640, 1.38), (15.9, 523, 520, 960, 640, 1.38),
    (16.05, *REST), (16.8, 700, 360, 960, 640, 1.35), (19.2, 700, 360, 960, 640, 1.35),
    (19.35, *REST), (20.6, 330, 520, 960, 640, 1.5), (23.6, 930, 450, 960, 640, 1.5),
    (24.3, *REST), (end[1], *REST),
]

captions = [
    (*A, "LIVE MAP", "Every bus to your stop, live.", YELLOW),
    (*B1, "NEARBY", "Your nearest stop, one click away.", CYAN),
    (*B2, "UP TO THREE LINES", "Pick only the buses you take.", YELLOW),
    (*CC, "LIVE", "Watch them come to you.", RED),
    (*D, "CLICK A BUS", "See exactly where it is.", YELLOW),
    (*E, "WALL MODE", "One switch makes it a bus board.", CYAN),
    (*F, "AT A GLANCE", "Readable from across the room.", YELLOW),
]
