#!/usr/bin/env bash
# Records the App Store previews' journey on each device, for scripts/preview-video/render.py to cut:
# the nearest stop picked, its lines chosen, the live map, a bus tapped, and wall mode turned on.
#
#   scripts/preview-video.sh record iphone     # the simulator filmed while PreviewJourneyTests drives it
#   scripts/preview-video.sh record ipad       # the same in landscape, its wall upright
#   scripts/preview-video.sh record mac        # MacPreviewJourneyTests films the window between clicks
#   scripts/preview-video.sh render [iphone ipad mac]
#
# A recording lands in build/preview/<device>: journey.mov (or the Mac's shots), marks.txt with each
# step and tap ("MARK <name> <epoch>", "TAP <name> <x> <y> <epoch or ms>"), and frames/ at 30 fps,
# numbered by their time in the recording. The cut files hold times pinned to one recording: after a
# new take, find each tap's moment in the frames (marks.txt is a second or so early on the simulator)
# and update the cut before rendering. The app stages itself on the mock with its clock frozen at
# 9:41 and set running as the board appears (ScreenshotMode), so takes come out alike.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/preview"
DERIVED="$BUILD/DerivedData"
BUNDLE_ID="com.hayek.BusBus"
# The same simulators scripts/screenshots.sh shoots on.
IPHONE="BusBus Shots iPhone"
IPAD="BusBus Shots iPad"
# Where the rider stands for the English listing: a short walk from 5 Av/W 42 St.
LAT=40.7516 LON=-73.9785

log() { printf '\n==> %s\n' "$*"; }

udid_of() {
  xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["name"] == sys.argv[1]:
            print(d["udid"]); sys.exit()
sys.exit("No simulator named " + sys.argv[1] + "; scripts/screenshots.sh creates it")' "$1"
}

# record_ios <device> <simulator> <orientation> <wall orientation>
record_ios() {
  local device="$1" udid out="$BUILD/$1" recorder
  udid=$(udid_of "$2")
  log "Booting $2"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100
  xcrun simctl location "$udid" set "$LAT,$LON"
  log "Building"
  xcodebuild -quiet -scheme BusBusScreenshots -configuration Release -derivedDataPath "$DERIVED" \
    -destination "platform=iOS Simulator,id=$udid" build-for-testing
  xcrun simctl privacy "$udid" grant location "$BUNDLE_ID" 2>/dev/null || true
  rm -rf "$out" && mkdir -p "$out/frames"
  log "Recording $device"
  # HEVC: the simulator's H.264 recordings carry timestamps ffmpeg cannot keep in order.
  xcrun simctl io "$udid" recordVideo --codec=hevc --force "$out/journey.mov" 2>/dev/null &
  recorder=$!
  sleep 1.5
  /usr/bin/python3 -c 'import time; print("RECSTART %.3f" % time.time())' >"$out/marks.txt"
  TEST_RUNNER_PREVIEW_JOURNEY=1 TEST_RUNNER_PREVIEW_ORIENTATION="$3" TEST_RUNNER_PREVIEW_WALL_ORIENTATION="$4" \
    xcodebuild -scheme BusBusScreenshots -configuration Release -derivedDataPath "$DERIVED" \
    -destination "platform=iOS Simulator,id=$udid" -only-testing:BusBusScreenshots/PreviewJourneyTests/testJourney \
    test-without-building >"$out/test.log" 2>&1 || { kill -INT "$recorder"; tail -20 "$out/test.log"; exit 1; }
  kill -INT "$recorder"
  wait "$recorder" 2>/dev/null || true
  grep -oE "(MARK|TAP) .*" "$out/test.log" >>"$out/marks.txt"
  xcrun simctl status_bar "$udid" clear
  # Every frame from the very start, so frame n is the recording's n/30 s (seeking into these files
  # lands elsewhere). The fps filter places each frame by its own time: the simulator writes one
  # only when the screen changes, and `-fps_mode cfr` filled a long still stretch from the wrong
  # end, so an iPad take came out a minute and a half behind. The iPhone's 440 pt at 2.5 px, the
  # iPad's 1032 pt at 1.5.
  local scale="1100:2390"
  [[ $device == ipad ]] && scale="1548:2064"
  ffmpeg -v error -y -i "$out/journey.mov" -vf "fps=30,scale=$scale:flags=lanczos" -q:v 3 \
    -start_number 0 "$out/frames/%05d.jpg"
  cat "$out/marks.txt"
}

record_mac() {
  local out="$BUILD/mac" shots
  log "Building for mac"
  xcodebuild -quiet build-for-testing -scheme BusBusScreenshots -destination "platform=macOS" \
    -derivedDataPath "$BUILD/MacDerivedData"
  rm -rf "$out" && mkdir -p "$out"
  log "Recording mac"
  TEST_RUNNER_PREVIEW_JOURNEY=1 xcodebuild test-without-building -scheme BusBusScreenshots \
    -destination "platform=macOS" -derivedDataPath "$BUILD/MacDerivedData" \
    -only-testing:BusBusScreenshots/MacPreviewJourneyTests/testJourney >"$out/test.log" 2>&1 \
    || { tail -20 "$out/test.log"; exit 1; }
  grep -oE "TAP .*" "$out/test.log" >"$out/marks.txt"
  # The runner is sandboxed: its shots are in its own temporary folder.
  shots=$(grep -oE "FRAMES .*" "$out/test.log" | head -1 | cut -d' ' -f2-)
  cp -R "$shots" "$out/shots"
  /usr/bin/env python3 "$ROOT/scripts/preview-video/mac_frames.py" "$out/shots" "$out/frames"
  cat "$out/marks.txt"
}

case "${1:-}" in
  record)
    case "${2:-}" in
      iphone) record_ios iphone "$IPHONE" portrait landscape ;;
      ipad) record_ios ipad "$IPAD" landscape portrait ;;
      mac) record_mac ;;
      *) echo "usage: $0 record iphone|ipad|mac" >&2; exit 2 ;;
    esac
    ;;
  render)
    shift
    /usr/bin/env python3 "$ROOT/scripts/preview-video/render.py" "$@"
    ;;
  *) sed -n '2,15p' "$0" >&2; exit 2 ;;
esac
