#!/usr/bin/env bash
# Captures App Store screenshots of every staged screen: light and dark, portrait and landscape,
# watching 1, 2 and 3 lines, on iPhone, iPad and Mac; and PNGs of the widget in every size, the
# watch's complications included.
#
#   scripts/screenshots.sh              # everything
#   scripts/screenshots.sh iphone mac   # only these (iphone, ipad, mac, widgets)
#   scripts/screenshots.sh widgets      # only the widgets
#   scripts/screenshots.sh store        # the App Store set's raw shots and clips, in every language
#   STORE_LANGUAGES="he ja" STORE_DEVICES=iphone scripts/screenshots.sh store   # only these
#   STORE_DEVICES=tv scripts/screenshots.sh store   # Apple TV's, straight to store/final/tv
#   STORE_DEVICES=watch scripts/screenshots.sh store   # Apple Watch's, straight to store/final/watch
#   WIDGET_DEVICES=iphone scripts/screenshots.sh widgets   # only the iPhone's widgets
#
# The app stages each screen itself when launched with `-screenshot <screen>` (see
# BusBus/Screenshots/ScreenshotMode.swift): mock data, a rider's history, and the clock frozen at
# 9:41. PNGs land at App Store sizes in
#   screenshots/iphone|ipad/<portrait|landscape>/<appearance>/<screen>[-<n>-lines].png
#   screenshots/mac/<appearance>/<screen>[-<n>-lines].png
# iPhone 1320 × 2868 (6.9"), iPad 2064 × 2752 (13"), Mac 2560 × 1600; landscape turned on its side.
#
# The widgets are drawn by an opt-in test (BusBusTests/Widget/WidgetScreenshotTests.swift) from
# the same staging, at the point sizes iOS 27 gives a 6.9" iPhone and a 13" iPad (@3x, @2x) and the
# Mac's (@2x), in their rounded container with transparent corners; and the watch's complications
# (@2x), drawn by the same accessory views on the iPhone simulator:
#   screenshots/widgets/<iphone|ipad|mac|watch>/<language>/<look>/<family>-<state>[-map|-later].png
# look       light, dark: full colour, in the appearance chosen in the app
#            light-tinted, dark-tinted (iPhone, iPad): the home screen's tinted icons
#            light-vibrant, dark-vibrant (Mac): the desktop's, with windows in front of it
#            lock (iPhone): the lock screen's vibrant white, on transparency for any wallpaper
#            standby, standby-night (iPhone, small): StandBy on a nightstand, the widget without
#            its background, scaled up to 400 pt on black; at night in its red, by luminance
#            vibrant, color (watch): a face's one-ink look and its full-colour one
# family     small, medium, large, extra-large (iPad, Mac), extra-large-portrait;
#            circular, rectangular, inline (lock); circular, rectangular (-42mm, -46mm, -49mm),
#            inline (-46mm), corner (watch: its glyph over the label the face curves along the bezel)
# state      live; stale (AS OF 9:27); no-live-data; no-history (choose a stop); removed-stop
# -map       large and both extra large with "Large widget shows" on Map (the default): the board's
#            rail map, its buses placed from the positions the board saved and moved on to 9:41
# -later     the same set to Later buses: the stop's next buses listed, as a stop with no routes
#            saved shows them too
# Tinted and vibrant are done by hand, since only a widget host renders them: the views draw in
# their monochrome theme, as on a device, and that is used as a mask for one ink over glass.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/screenshots"
DERIVED="${DERIVED:-$ROOT/build/screenshots/DerivedData}"
BUNDLE_ID="com.hayek.BusBus"
# The stop list and search are the same whatever the board watches, so they are taken once.
BOARD_SCREENS=(lines board tapped settings)
LINE_COUNTS=(1 2 3)
APPEARANCES=(light dark)
ORIENTATIONS=(portrait landscape)
# The widgets' languages, as AppLanguage codes; Hebrew for right to left.
WIDGET_LANGUAGES=(en he)
# The frozen 9:41 is read in this zone, which fixes where the mock's buses are.
SHOT_TZ="Asia/Jerusalem"
# ScreenshotMode.location, for MapKit's own blue dot.
LAT=32.0885 LON=34.7815

# name|device type
IPHONE="BusBus Shots iPhone|com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"
IPAD="BusBus Shots iPad|com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"
TV="BusBus Shots TV|com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-1080p"
WATCH="BusBus Shots Watch|com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-3-49mm"

targets=("$@")
[[ ${#targets[@]} -eq 0 ]] && targets=(iphone ipad mac widgets)

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }

# Every shot as "<screen> <line count> <file name>".
shots() {
  echo "stops 3 stops"
  echo "search 3 search"
  for screen in "${BOARD_SCREENS[@]}"; do
    for n in "${LINE_COUNTS[@]}"; do
      if [[ $n == 1 ]]; then echo "$screen $n $screen-1-line"; else echo "$screen $n $screen-$n-lines"; fi
    done
  done
}

# Captures with $1 (a command taking the output path) once two shots a second apart match, so a
# loading board — which shimmers — is never what gets kept. The search map's location dot pulses
# for ever, so it gets a fixed wait for its map tiles instead.
capture_settled() {
  local take="$1" out="$2" screen="$3"
  local previous="$out.previous"
  if [[ $screen == search ]]; then
    sleep 6
    $take "$out"
    return
  fi
  sleep 2
  $take "$previous"
  for _ in $(seq 1 15); do
    sleep 1
    $take "$out"
    if cmp -s "$out" "$previous"; then rm -f "$previous"; return; fi
    mv "$out" "$previous"
  done
  mv "$previous" "$out"
  echo "   $out never settled; kept the last shot" >&2
}

build() {
  log "Building for $1"
  shift
  xcodebuild -quiet -scheme BusBus -configuration Release -derivedDataPath "$DERIVED" "$@" build
}

# Finds the named simulator, or creates it on the newest runtime of $3 (iOS by default).
simulator() {
  local name="$1" type="$2" platform="${3:-iOS}" udid
  udid=$(xcrun simctl list devices -j | /usr/bin/python3 -c '
import json, sys
name = sys.argv[1]
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["name"] == name and d["isAvailable"]:
            print(d["udid"]); sys.exit()' "$name")
  if [[ -z "$udid" ]]; then
    local runtime
    runtime=$(xcrun simctl list runtimes -j | /usr/bin/python3 -c '
import json, sys
found = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == sys.argv[1] and r["isAvailable"]]
print(found[-1]["identifier"])' "$platform")
    udid=$(xcrun simctl create "$name" "$type" "$runtime")
  fi
  echo "$udid"
}

sim_shot() { xcrun simctl io "$SIM" screenshot --type=png "$1" >/dev/null 2>&1; }

shoot_ios() {
  local key="$1" spec="$2" name type udid app
  IFS='|' read -r name type <<<"$spec"
  # An iPad only lets the app turn itself to landscape when it runs full screen.
  build "$key" -destination "generic/platform=iOS Simulator" INFOPLIST_KEY_UIRequiresFullScreen=YES
  app="$DERIVED/Build/Products/Release-iphonesimulator/BusBus.app"

  udid=$(simulator "$name" "$type")
  log "Booting $name ($udid)"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active \
    --wifiBars 3 --cellularMode active --cellularBars 4 --operatorName "" \
    --batteryState charged --batteryLevel 100
  xcrun simctl location "$udid" set "$LAT,$LON"
  xcrun simctl install "$udid" "$app"
  xcrun simctl privacy "$udid" grant location "$BUNDLE_ID" 2>/dev/null || true

  for appearance in "${APPEARANCES[@]}"; do
    xcrun simctl ui "$udid" appearance "$appearance"
    for orientation in "${ORIENTATIONS[@]}"; do
      local dir="$OUT/$key/$orientation/$appearance"
      mkdir -p "$dir"
      while read -r screen n file; do
        xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
        SIMCTL_CHILD_TZ="$SHOT_TZ" xcrun simctl launch "$udid" "$BUNDLE_ID" \
          -screenshot "$screen" -screenshotLines "$n" -screenshotOrientation "$orientation" \
          -screenshotAppearance "$appearance" >/dev/null
        SIM="$udid" capture_settled sim_shot "$dir/$file.png" "$screen"
        # The simulator saves a landscape iPad in its portrait pixels, turned on its side.
        if [[ $orientation == landscape ]]; then
          local width height
          width=$(sips -g pixelWidth "$dir/$file.png" | awk '/pixelWidth/ {print $2}')
          height=$(sips -g pixelHeight "$dir/$file.png" | awk '/pixelHeight/ {print $2}')
          if (( width < height )); then sips -r 270 "$dir/$file.png" >/dev/null; fi
        fi
        echo "   $key/$orientation/$appearance/$file.png"
      done < <(shots)
    done
  done
  xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl status_bar "$udid" clear
  xcrun simctl shutdown "$udid"
}

# The Mac pass is a UI test (BusBusScreenshots): XCTest may read the app's window, where
# screencapture would need Screen Recording permission for the terminal. Its shots come back as
# attachments in the result bundle.
shoot_mac() {
  local derived="$ROOT/build/screenshots/MacDerivedData"
  log "Building for mac"
  xcodebuild build-for-testing -quiet -scheme BusBusScreenshots -destination "platform=macOS" \
    -derivedDataPath "$derived"
  for appearance in "${APPEARANCES[@]}"; do
    local result="$ROOT/build/screenshots/mac-$appearance.xcresult"
    rm -rf "$result"
    log "Mac · $appearance"
    TEST_RUNNER_SCREENSHOT_APPEARANCE="$appearance" xcodebuild test-without-building -quiet \
      -scheme BusBusScreenshots -destination "platform=macOS" -derivedDataPath "$derived" \
      -resultBundlePath "$result"
    export_attachments "$result" "$OUT/mac/$appearance"
  done
}

# Copies the PNG attachments of $1 (an .xcresult) to $2, named after the attachment. A "+" in a
# name is a folder: "en+dark+small-live.png" lands at <dest>/en/dark/small-live.png.
export_attachments() {
  local result="$1" dest="$2" raw="$1.attachments"
  rm -rf "$raw" && mkdir -p "$raw" "$dest"
  xcrun xcresulttool export attachments --path "$result" --output-path "$raw" >/dev/null
  /usr/bin/python3 - "$raw" "$dest" "$OUT" <<'PY'
import json, os, re, shutil, sys
raw, dest, out = sys.argv[1], sys.argv[2], sys.argv[3]
count = 0
for test in json.load(open(os.path.join(raw, "manifest.json"))):
    for a in test.get("attachments", []):
        # "board-2-lines_0_<UUID>.png" -> "board-2-lines.png"
        name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}(?=\.\w+$)", "", a["suggestedHumanReadableName"])
        path = os.path.join(dest, *name.split("+"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        shutil.copy(os.path.join(raw, a["exportedFileName"]), path)
        print("   " + os.path.relpath(path, out))
        count += 1
if count == 0:
    sys.exit("No screenshots in the result bundle")
PY
  rm -rf "$raw"
}

# The widgets are rendered by a test, not captured: WIDGET_SHOTS switches it on and says which
# device's sizes to draw. iPhone and iPad run on their simulators, the Mac natively; WIDGET_DEVICES
# picks some of them.
shoot_widgets() {
  local devices=" ${WIDGET_DEVICES:-iphone ipad mac watch} "
  local mac_derived="$ROOT/build/screenshots/MacDerivedData"
  local test_env=(TEST_RUNNER_TZ="$SHOT_TZ" TEST_RUNNER_WIDGET_SHOT_LANGUAGES="${WIDGET_LANGUAGES[*]}"
    TEST_RUNNER_WIDGET_SHOT_APPEARANCES="${APPEARANCES[*]}")
  local only=(-only-testing:BusBusTests/WidgetScreenshotTests)
  local key
  for key in $devices; do rm -rf "$OUT/widgets/$key"; done

  if [[ $devices == *" iphone "* || $devices == *" ipad "* || $devices == *" watch "* ]]; then
    log "Building widget shots for iOS"
    xcodebuild build-for-testing -quiet -scheme BusBus -destination "generic/platform=iOS Simulator" \
      -derivedDataPath "$DERIVED"
  fi
  # The watch's complications are drawn on the iPhone simulator: the views are the same code.
  for spec in "iphone|$IPHONE" "ipad|$IPAD" "watch|$IPHONE"; do
    local name type udid result
    IFS='|' read -r key name type <<<"$spec"
    [[ $devices == *" $key "* ]] || continue
    udid=$(simulator "$name" "$type")
    result="$ROOT/build/screenshots/widgets-$key.xcresult"
    rm -rf "$result"
    log "Widgets · $key"
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
    env "${test_env[@]}" TEST_RUNNER_WIDGET_SHOTS="$key" xcodebuild test-without-building -quiet -scheme BusBus \
      -destination "id=$udid" -derivedDataPath "$DERIVED" -resultBundlePath "$result" "${only[@]}"
    export_attachments "$result" "$OUT/widgets/$key"
    rm -rf "$result"
    xcrun simctl shutdown "$udid"
  done

  [[ $devices == *" mac "* ]] || return 0
  log "Building widget shots for mac"
  xcodebuild build-for-testing -quiet -scheme BusBus -destination "platform=macOS" -derivedDataPath "$mac_derived"
  local result="$ROOT/build/screenshots/widgets-mac.xcresult"
  rm -rf "$result"
  log "Widgets · mac"
  env "${test_env[@]}" TEST_RUNNER_WIDGET_SHOTS=mac xcodebuild test-without-building -quiet -scheme BusBus \
    -destination "platform=macOS" -derivedDataPath "$mac_derived" -resultBundlePath "$result" "${only[@]}"
  export_attachments "$result" "$OUT/widgets/mac"
  rm -rf "$result"
}

# The App Store's raw material, in every language the listing has: the app launched in each
# language as a rider whose device speaks it would see it, for scripts/store-art.py to set in the
# designed frames. Stills, and clips recorded with the staged clock running (AppClock.rate), so the
# buses move and the countdown runs down in the previews.
#   screenshots/store/raw/<iphone|ipad>/<language>/<name>.png|.mov
#   screenshots/store/raw/mac/<language>/<name>.png, <name>-clip/<ms>.png   (window shots; see
#                                                    MacScreenshotTests.testCaptureStoreSet)
# STORE_LANGUAGES and STORE_DEVICES pick some of them (AppLanguage codes; iphone, ipad, mac, tv, watch).
STORE_LANGUAGES=(${STORE_LANGUAGES:-en ar de es fi fr he hi it ja ko nb pa pl pt-BR pt-PT ru sv tr vi zh-Hans zh-Hant})
STORE_DEVICES=(${STORE_DEVICES:-iphone ipad mac})
# The previews' clock: 40 times real time from two minutes twenty before 9:41, set running as
# filming starts (ScreenshotMode.clockStartNotification), so the next bus counts down to NOW
# within the first scene. STORE_KINDS=clip retakes only the clips, keeping the stills.
CLIP_RATE=40 CLIP_OFFSET=-140 CLIP_SECONDS=9
STORE_KINDS=(${STORE_KINDS:-shot clip})

# Every capture as "<shot|clip> <screen> <line count> <orientation> <appearance> <name>". The
# screenshots show two lines, 41 and 18, sharing a corridor; three only for the routes shot.
store_captures() {
  case "$1" in
    iphone)
      echo "shot board 2 portrait dark board"
      echo "shot board 2 landscape dark wall"
      echo "shot tapped 2 portrait dark tapped"
      echo "shot lines 2 portrait light lines"
      echo "clip board 2 portrait dark board"
      echo "clip board 2 landscape dark wall"
      echo "clip stops 2 portrait dark stops"
      ;;
    ipad)
      echo "shot board 2 landscape dark board"
      echo "shot board 2 portrait dark wall"
      echo "shot tapped 2 landscape dark tapped"
      echo "shot board 3 landscape dark routes"
      echo "clip board 2 landscape dark board"
      echo "clip board 2 portrait dark wall"
      echo "clip tapped 2 landscape dark tapped"
      ;;
  esac
}

# The real city a language's shots are set in (BusBus/Screenshots/ScreenshotPlaces.json), as
# "<place> <lat> <lon>": where the rider stands, a short walk from its stop (ScreenshotMode.location).
PLACES="$ROOT/BusBus/Screenshots/ScreenshotPlaces.json"
place_of() {
  /usr/bin/python3 - "$PLACES" "$1" <<'PY'
import json, sys
file = json.load(open(sys.argv[1]))
key = file["languages"].get(sys.argv[2], file["languages"]["en"])
place = file["places"][key]
print(key, round(place["lat"] - 0.0015, 6), round(place["lon"] + 0.0015, 6))
PY
}

# Records $CLIP_SECONDS of the simulator's screen to $1, once the board has had time to load.
sim_clip() {
  sleep 4
  xcrun simctl io "$SIM" recordVideo --codec=h264 --force "$1" >/dev/null 2>&1 &
  local recorder=$!
  # The recorder takes a moment to start: the clock is set running once it has.
  sleep 1
  xcrun simctl spawn "$SIM" notifyutil -p com.hayek.BusBus.screenshotClock
  sleep "$CLIP_SECONDS"
  kill -INT "$recorder"
  wait "$recorder" 2>/dev/null || true
}

shoot_store() {
  local key="$1" spec="$2" name type udid app
  IFS='|' read -r name type <<<"$spec"
  build "$key" -destination "generic/platform=iOS Simulator" INFOPLIST_KEY_UIRequiresFullScreen=YES
  app="$DERIVED/Build/Products/Release-iphonesimulator/BusBus.app"

  udid=$(simulator "$name" "$type")
  log "Booting $name ($udid)"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active \
    --wifiBars 3 --cellularMode active --cellularBars 4 --operatorName "" \
    --batteryState charged --batteryLevel 100
  xcrun simctl location "$udid" set "$LAT,$LON"
  xcrun simctl install "$udid" "$app"
  xcrun simctl privacy "$udid" grant location "$BUNDLE_ID" 2>/dev/null || true

  for language in "${STORE_LANGUAGES[@]}"; do
    local dir="$OUT/store/raw/$key/$language" place plat plon
    read -r place plat plon < <(place_of "$language")
    xcrun simctl location "$udid" set "$plat,$plon"
    [[ ${#STORE_KINDS[@]} -eq 2 ]] && rm -rf "$dir"
    mkdir -p "$dir"
    while read -r kind screen n orientation appearance file; do
      [[ " ${STORE_KINDS[*]} " == *" $kind "* ]] || continue
      local clock=() wall=()
      [[ $kind == clip ]] && clock=(-screenshotClockRate "$CLIP_RATE" -screenshotClockOffset "$CLIP_OFFSET")
      # The wall shots show the board as a wall display draws it (ScreenshotMode.wall).
      [[ $file == wall ]] && wall=(-screenshotWall YES)
      xcrun simctl ui "$udid" appearance "$appearance"
      xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
      SIMCTL_CHILD_TZ="$SHOT_TZ" xcrun simctl launch "$udid" "$BUNDLE_ID" \
        -AppleLanguages "($language)" -AppleLocale "$language" -settings.language "$language" \
        -screenshotPlace "$place" \
        -screenshot "$screen" -screenshotLines "$n" -screenshotOrientation "$orientation" \
        -screenshotAppearance "$appearance" ${clock[@]+"${clock[@]}"} ${wall[@]+"${wall[@]}"} >/dev/null
      if [[ $kind == clip ]]; then
        # A landscape clip keeps the portrait pixels with a rotation tag, which ffmpeg applies.
        SIM="$udid" sim_clip "$dir/$file.mov"
        echo "   store/raw/$key/$language/$file.mov"
        continue
      fi
      SIM="$udid" capture_settled sim_shot "$dir/$file.png" "$screen"
      if [[ $orientation == landscape ]]; then
        local width height
        width=$(sips -g pixelWidth "$dir/$file.png" | awk '/pixelWidth/ {print $2}')
        height=$(sips -g pixelHeight "$dir/$file.png" | awk '/pixelHeight/ {print $2}')
        if (( width < height )); then sips -r 270 "$dir/$file.png" >/dev/null; fi
      fi
      echo "   store/raw/$key/$language/$file.png"
    done < <(store_captures "$key")
  done
  xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl status_bar "$udid" clear
  xcrun simctl shutdown "$udid"
}

# Apple TV's: the screen as it is, 1920 × 1080, which is what App Store Connect takes for a TV;
# no frames or captions, so they go straight to the final set store-upload.py sends.
#   screenshots/store/final/tv/<language>/01-home.png, 02-board.png, 03-tapped.png
shoot_store_tv() {
  local name type udid app
  IFS='|' read -r name type <<<"$TV"
  log "Building for tv"
  xcodebuild -quiet -scheme BusBus -configuration Release -derivedDataPath "$DERIVED" \
    -destination "generic/platform=tvOS Simulator" build
  app="$DERIVED/Build/Products/Release-appletvsimulator/BusBus.app"

  udid=$(simulator "$name" "$type" tvOS)
  log "Booting $name ($udid)"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl install "$udid" "$app"
  xcrun simctl privacy "$udid" grant location "$BUNDLE_ID" 2>/dev/null || true

  for language in "${STORE_LANGUAGES[@]}"; do
    local dir="$OUT/store/final/tv/$language" place plat plon
    read -r place plat plon < <(place_of "$language")
    xcrun simctl location "$udid" set "$plat,$plon"
    rm -rf "$dir" && mkdir -p "$dir"
    while read -r screen n file; do
      xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
      SIMCTL_CHILD_TZ="$SHOT_TZ" xcrun simctl launch "$udid" "$BUNDLE_ID" \
        -AppleLanguages "($language)" -AppleLocale "$language" -settings.language "$language" \
        -screenshotPlace "$place" -screenshot "$screen" -screenshotLines "$n" \
        -screenshotAppearance dark >/dev/null
      SIM="$udid" capture_settled sim_shot "$dir/$file.png" "$screen"
      echo "   store/final/tv/$language/$file.png"
    done <<'SHOTS'
stops 3 01-home
board 2 02-board
tapped 2 03-tapped
SHOTS
  done
  xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl shutdown "$udid"
}

# Apple Watch's: the Ultra's 422 × 514, which App Store Connect takes for every watch; staged by
# the watch app itself (BusBusWatch/WatchScreenshotStage.swift) and, like the TV's, sent as taken.
#   screenshots/store/final/watch/<language>/01-board.png, 02-stops.png, 03-board-1-line.png
shoot_store_watch() {
  local name type udid app bundle
  IFS='|' read -r name type <<<"$WATCH"
  log "Building for watch"
  xcodebuild -quiet -scheme BusBusWatch -configuration Release -derivedDataPath "$DERIVED" \
    -destination "generic/platform=watchOS Simulator" build
  app="$DERIVED/Build/Products/Release-watchsimulator/BusBusWatch.app"
  bundle=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$app/Info.plist")

  udid=$(simulator "$name" "$type" watchOS)
  log "Booting $name ($udid)"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl install "$udid" "$app"

  for language in "${STORE_LANGUAGES[@]}"; do
    local dir="$OUT/store/final/watch/$language" place plat plon
    read -r place plat plon < <(place_of "$language")
    rm -rf "$dir" && mkdir -p "$dir"
    while read -r screen n file; do
      xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
      # The iPhone's language, not the watch's (WatchEnvironment): the system's own chrome stays
      # in the simulator's English, as its clock does, so a right-to-left back button is not drawn
      # under the clock.
      SIMCTL_CHILD_TZ="$SHOT_TZ" xcrun simctl launch "$udid" "$bundle" \
        -AppleLocale "$language" -settings.language "$language" \
        -screenshotPlace "$place" -screenshot "$screen" -screenshotLines "$n" \
        -screenshotAppearance dark >/dev/null
      SIM="$udid" capture_settled sim_shot "$dir/$file.png" "$screen"
      watch_clock "$dir/$file.png"
      echo "   store/final/watch/$language/$file.png"
    done <<'SHOTS'
board 3 01-board
stops 3 02-stops
board 1 03-board-1-line
SHOTS
  done
  xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
  xcrun simctl shutdown "$udid"
}

# A watch simulator's status bar cannot be overridden, so its clock reads the Mac's time: that is
# painted over with 9:41, right-aligned where it was, in the face's SF Compact.
watch_clock() {
  python3 - "$1" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont
path = sys.argv[1]
image = Image.open(path).convert("RGB")
width = image.width
# The clock: the white text in the top right, clear of the back button on the left.
bright = [(x, y) for y in range(20, 95) for x in range(width // 2, width) if sum(image.getpixel((x, y))) > 600]
if not bright:
    sys.exit(f"{path}: no clock found")
left, right = min(x for x, _ in bright), max(x for x, _ in bright)
top, bottom = min(y for _, y in bright), max(y for _, y in bright)
draw = ImageDraw.Draw(image)
draw.rectangle((left - 3, top - 3, right + 3, bottom + 3), fill=image.getpixel((left - 6, top)))
font = ImageFont.truetype("/Library/Fonts/SF-Compact-Text-Medium.otf", round((bottom - top + 1) * 32 / 23))
box = draw.textbbox((0, 0), "9:41", font=font)
draw.text((right + 1 - box[2], top - box[1]), "9:41", font=font, fill=(255, 255, 255))
image.save(path)
PY
}

# The Mac's: its UI test launches the app in each language and keeps the window's shots.
shoot_store_mac() {
  local derived="$ROOT/build/screenshots/MacDerivedData" result="$ROOT/build/screenshots/store-mac.xcresult"
  log "Building for mac"
  xcodebuild build-for-testing -quiet -scheme BusBusScreenshots -destination "platform=macOS" \
    -derivedDataPath "$derived"
  rm -rf "$result"
  log "Mac · store set"
  local places=() language
  for language in "${STORE_LANGUAGES[@]}"; do places+=("$language=$(place_of "$language" | cut -d' ' -f1)"); done
  TEST_RUNNER_STORE_LANGUAGES="${places[*]}" xcodebuild test-without-building -quiet \
    -scheme BusBusScreenshots -destination "platform=macOS" -derivedDataPath "$derived" \
    -resultBundlePath "$result" -only-testing:BusBusScreenshots/MacScreenshotTests/testCaptureStoreSet
  for language in "${STORE_LANGUAGES[@]}"; do rm -rf "$OUT/store/raw/mac/$language"; done
  export_attachments "$result" "$OUT/store/raw/mac" | grep -v -- '-clip/' || true
  rm -rf "$result"
}

for target in "${targets[@]}"; do
  case "$target" in
    iphone) shoot_ios iphone "$IPHONE" ;;
    ipad) shoot_ios ipad "$IPAD" ;;
    mac) shoot_mac ;;
    widgets) shoot_widgets ;;
    store)
      for device in "${STORE_DEVICES[@]}"; do
        case "$device" in
          iphone) shoot_store iphone "$IPHONE" ;;
          ipad) shoot_store ipad "$IPAD" ;;
          mac) shoot_store_mac ;;
          tv) shoot_store_tv ;;
          watch) shoot_store_watch ;;
        esac
      done
      ;;
    *) echo "unknown target: $target (iphone, ipad, mac, widgets, store)" >&2; exit 64 ;;
  esac
done

log "Done: $OUT"
