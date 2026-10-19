"""The iPad preview: 1600 x 1200, landscape, for the 13" slot; its wall is a portrait iPad. The
recording is the simulator's portrait pixels with the landscape interface turned in them, so the
journey's scenes are turned 90° to read upright (rot). Pinned to build/preview/ipad."""
from engine import ROOT, YELLOW, RED, CYAN
import wall

BUILD = ROOT / "build/preview"

W, H = 1600, 1200
frames = BUILD / "ipad/frames"
first_frame, last_frame = 0, len(list(frames.glob("*.jpg"))) - 1
src_px_per_pt = 1.5            # 1548 px frames of a 1032 pt screen
radius_pt, bezel_pt = 18, 16
touch_ref_k = 0.95
icon = BUILD / "icon.png"
wall_image = BUILD / "wall-ipad.jpg"
wall_mount = wall.IPAD
wall_screen = wall.screen(wall.IPAD)
wall_radius = 12
glows = [((0.55, -0.45, 1.25, 0.45), (70, 52, 0)), ((-0.35, 0.55, 0.35, 1.45), (70, 14, 16)),
         ((-0.15, 0.05, 0.25, 0.55), (0, 36, 44))]
scrim_solid, scrim_end = 235, 305
kicker_size, title_size = 22, 60
cap_left, cap_top, cap_width, cap_center = 90, 70, 1420, False
end_icon, end_icon_y, end_title, end_text_y = 260, 470, 76, 660
end_lines = ["Every bus to your stop, live."]

def C(t0, t1, s0, s1, rot=90):
    return dict(t0=t0, t1=t1, s0=s0, s1=s1, rot=rot)

A, B1, B2, CC, D, E, F0 = (0.0, 3.0), (3.0, 6.0), (6.0, 8.6), (8.6, 12.0), (12.0, 15.4), (15.4, 18.8), (18.8, 19.8)
TURN = (19.8, 20.55)
F = (20.55, 26.55)
end = (26.55, 29.55)
total = end[1]
wall_in = (20.6, 21.3)

clips = [C(*A, 159.1, 163.05), C(*B1, 150.63, 153.73), C(*B2, 155.45, 158.85), C(*CC, 163.05, 168.72),
         C(*D, 168.72, 172.4), C(*E, 174.57, 180.42), C(*F0, 180.42, 181.72), C(F[0], end[0] + 0.5, 182.82, 193.02, rot=0)]
taps = [(153.53, 1021, 710), (156.1, 359, 330), (157.37, 140, 330), (158.67, 1174, 934), (168.9, 561, 416),
        (174.75, 1311, 68), (177.8, 916, 316), (180.07, 931, 218)]
turn = dict(t0=TURN[0], t1=TURN[1], src_a=181.72, rot_a=90, src_b=182.82, rot_b=0, angle=-90,
            k_a=0.75, k_b=0.62, cx=800, cy=720)

REST = (688, 516, 800, 735, 0.83)
PORT = (516, 688)
cam = [
    (0.0, 560, 600, 800, 720, 1.20), (1.9, 600, 600, 800, 720, 1.10), (2.95, *REST),
    (3.0, *REST), (3.8, 900, 600, 800, 720, 1.08), (5.95, 900, 600, 800, 720, 1.08),
    (6.0, 688, 560, 800, 735, 0.92), (8.55, 688, 560, 800, 735, 0.92),
    (8.6, *REST), (11.95, 688, 470, 800, 720, 0.98),
    (12.05, 688, 470, 800, 720, 0.98), (13.0, 560, 600, 800, 720, 1.22), (15.3, 560, 600, 800, 720, 1.22),
    (15.45, *REST), (16.2, 800, 330, 800, 660, 1.22), (18.7, 800, 330, 800, 660, 1.22),
    (19.2, 688, 516, 800, 720, 0.75), (19.8, 688, 516, 800, 720, 0.75),
    (20.55, *PORT, 800, 720, 0.62), (21.3, *PORT, 800, 720, 0.62),
    (23.7, *PORT, 800, 585, 0.37), (26.55, *PORT, 800, 590, 0.40), (end[1], *PORT, 800, 590, 0.40),
]

captions = [
    (*A, "LIVE MAP", "Every bus to your stop, live.", YELLOW),
    (*B1, "NEARBY", "Your nearest stop, one tap away.", CYAN),
    (*B2, "UP TO THREE LINES", "Pick only the buses you take.", YELLOW),
    (*CC, "LIVE", "Watch them come to you.", RED),
    (*D, "TAP A BUS", "See exactly where it is.", YELLOW),
    (*E, "WALL MODE", "One switch makes it a bus board.", CYAN),
    (21.4, F[1], "MADE FOR THE WALL", "Give the old iPad in your drawer a job.", YELLOW, "dark"),
]
