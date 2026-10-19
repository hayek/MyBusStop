"""The iPhone preview: 886 x 1920, portrait, for the 6.9" slot. Times are seconds: a scene's
(t0, t1) in the preview, its (s0, s1) in the recording; taps as (recording time, x, y in points).
They are pinned to the recording in build/preview/iphone; a new take needs them pinned again."""
from engine import ROOT, YELLOW, RED, CYAN
import wall

BUILD = ROOT / "build/preview"

W, H = 886, 1920
frames = BUILD / "iphone/frames"
first_frame, last_frame = 0, len(list(frames.glob("*.jpg"))) - 1
src_px_per_pt = 2.5            # 1100 px frames of a 440 pt screen
radius_pt, bezel_pt = 62, 9.7
touch_ref_k = 1.364
icon = BUILD / "icon.png"
wall_image = BUILD / "wall-iphone.jpg"
wall_mount = wall.IPHONE
wall_screen = wall.screen(wall.IPHONE)
wall_radius = 36
glows = [((0.43, -0.22, 1.47, 0.27), (70, 52, 0)), ((-0.59, 0.65, 0.47, 1.17), (70, 14, 16)),
         ((-0.23, 0.26, 0.34, 0.52), (0, 36, 44))]
scrim_solid, scrim_end = 420, 540
kicker_size, title_size = 25, 76
cap_left, cap_top, cap_width, cap_center = 64, 150, 760, False
end_icon, end_icon_y, end_title, end_text_y = 300, 820, 84, 1060
end_lines = ["Every bus to", "your stop, live."]

def C(t0, t1, s0, s1, rot=0):
    return dict(t0=t0, t1=t1, s0=s0, s1=s1, rot=rot)

A, B1, B2, CC, D, E, F0 = (0.0, 3.0), (3.0, 6.3), (6.3, 8.8), (8.8, 12.3), (12.3, 15.8), (15.8, 19.0), (19.0, 19.9)
TURN = (19.9, 20.65)
F = (20.65, 26.55)
end = (26.55, 29.55)
total = end[1]
wall_in = (20.7, 21.4)

clips = [C(*A, 74.35, 77.62), C(*B1, 64.0, 68.58), C(*B2, 70.27, 73.58), C(*CC, 77.62, 82.84),
         C(*D, 82.84, 88.32), C(E[0], 18.2, 88.49, 91.74), C(18.2, E[1], 93.62, 94.45), C(*F0, 94.45, 94.75), C(F[0], end[0] + 0.5, 96.25, 105.85, rot=90)]
taps = [(68.33, 220, 645), (70.83, 220, 257), (72.23, 82, 257), (73.37, 275, 871), (83.0, 220, 355),
        (88.73, 398, 94), (90.77, 370, 202), (93.9, 383, 104)]
# the Settings sheet leaves in two recorded frames
extra_jumps = [94.02]
drags = [(64.5, 65.4, 220, 440, 220, 130)]
turn = dict(t0=TURN[0], t1=TURN[1], src_a=94.75, rot_a=0, src_b=96.25, rot_b=90, angle=90,
            k_a=1.25, k_b=0.90, cx=443, cy=1240)

REST = (220, 478, 443, 1235, 1.364)
LAND = (478, 220)
cam = [
    (0.0, 220, 560, 443, 1180, 1.95), (1.9, 220, 560, 443, 1210, 1.78), (2.95, *REST),
    (3.0, *REST), (4.0, *REST), (4.9, 220, 560, 443, 1150, 1.70), (6.25, 220, 560, 443, 1150, 1.70),
    (6.3, 220, 300, 443, 960, 1.78), (7.9, 220, 300, 443, 960, 1.78), (8.75, *REST),
    (8.8, *REST), (12.25, 220, 420, 443, 1180, 1.53),
    (12.4, 220, 420, 443, 1180, 1.53), (13.4, 200, 690, 443, 1270, 1.90), (15.6, 200, 690, 443, 1270, 1.90),
    (15.85, *REST), (16.6, 220, 200, 443, 880, 1.78), (18.9, 220, 200, 443, 880, 1.78),
    (19.45, 220, 478, 443, 1240, 1.25), (19.9, 220, 478, 443, 1240, 1.25),
    (20.65, *LAND, 443, 1240, 0.90), (21.4, *LAND, 443, 1240, 0.90),
    (24.05, *LAND, 443, 900, 0.40), (26.55, *LAND, 443, 900, 0.44), (end[1], *LAND, 443, 900, 0.44),
]

captions = [
    (*A, "LIVE MAP", "Every bus to your stop, live.", YELLOW),
    (*B1, "NEARBY", "Your nearest stop, one tap away.", CYAN),
    (*B2, "UP TO THREE LINES", "Pick only the buses you take.", YELLOW),
    (*CC, "LIVE", "Watch them come to you.", RED),
    (*D, "TAP A BUS", "See exactly where it is.", YELLOW),
    (*E, "WALL MODE", "One switch makes it a bus board.", CYAN),
    (21.45, F[1], "MADE FOR THE WALL", "Give the old iPhone in your drawer a job.", YELLOW, "dark"),
]
