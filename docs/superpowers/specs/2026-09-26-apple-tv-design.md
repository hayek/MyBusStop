# BusBus on Apple TV — design

Date: 2026-09-26. Status: approved in conversation; the user asked for spec → implement → review →
fix → run in one go, so the implementation order below stands in for a separate plan document.

## Intent

**What the user said.** Add Apple TV support. The TV use is a **quick glance** (not an always-on
wall display): open the app, see your usual stop, go back to watching. Stops reach the TV **synced
over iCloud from the iPhone/Mac**, with a **simple fallback picker on the TV**. A **Top Shelf**
extension ships in the first version.

**Assumptions (not said, chosen here).**
- One universal purchase: the TV build is a destination of the existing `BusBus` app target, same
  bundle id `com.hayek.BusBus` (approach A, approved).
- Only the saved-stop history syncs. Appearance, language, palette and recent searches stay per
  device.
- The TV follows the iPhone's design tokens, fonts and board unchanged; the landscape artboard
  (1280×720) is exactly 16:9 and scales ×1.5 to 1920×1080.

**Success.** On an Apple TV: launch → the saved stops are there (synced) → one click opens a board
that refreshes like the phone's; the remote flips between stops and goes back; a stop can be added
on the TV alone; the Top Shelf shows the pinned/recent stops' next buses and opens a board. Every
existing scheme (iOS, Mac, watch, tests) still builds and passes.

## 1. Platform and targets

- `BusBus` app target: `SUPPORTED_PLATFORMS` gains `appletvos appletvsimulator`,
  `TARGETED_DEVICE_FAMILY` gains `3`. `TVOS_DEPLOYMENT_TARGET = 27.0` is already set project-wide.
- The iOS widget extension and the watch app stay iOS/macOS-only via `platformFilters` on their
  embed build files and target dependencies (the watch already has `ios`).
- `BusBusTests` stays iOS/macOS: it compiles the widget's WidgetKit views, which tvOS lacks. The
  TV logic is platform-free and tested on the Mac.
- New target **`BusBusTopShelf`** (`com.apple.product-type.tv-app-extension`, bundle id
  `com.hayek.BusBus.TopShelf`, tvOS only), embedded in the app with a `tvos` platform filter. It
  shares app sources by file membership like `BusBusWidget` and compiles with `BUSBUS_TOPSHELF`.
  It links no Firebase: App Check reaches the transit layer through `TransitProxy.attestation`,
  unset in the extension, exactly as in the widget.
- Packages: Firebase (Core, Analytics, Crashlytics, Remote Config, App Check) and LoveLetterCore
  build for tvOS. **HelpView** declares no tvOS and **LoveLetterUI** declares it but does not
  compile there (FoundationModels, `systemBackground`), so both are linked with `platformFilters =
  (ios, macos)`; HelpView's one use is fenced with `#if canImport(HelpView)` and the feedback sheet
  lives in the iOS/macOS root only. The TV settings show no help pages and offer no feedback.
  (Fixing both packages for tvOS is a follow-up in their repos.)
- Frameworks absent on tvOS are fenced by `#if canImport(…)` / `#if !os(tvOS)`: WidgetKit
  (`WidgetBridge`, `NextBusEntry`'s timeline bits), WatchConnectivity (`WatchSync`), anything
  touch-only (pull-to-refresh, drag/tap gestures, swipe-back), and `UIScreen.brightness` (the wall
  dimming).

## 2. The TV app

A separate root, `TVRootView` (`BusBus/TV/`), chosen in `ContentView` under `#if os(tvOS)`.
`RootView` stays the iOS/macOS root untouched.

- **Home — "Your stops".** A horizontal row of focusable cards, pinned first then most recent
  (`SavedSetups.sorted`). Each card: stop name, city, line badges, and the next arrival per line
  (from the stop's `WidgetSnapshot` when fresh). The last used stop starts focused. A final
  **"Find a stop"** card opens the picker. With nothing saved, the home is one big "Find a stop"
  card and a line saying stops saved on your iPhone appear here through iCloud. A settings
  button sits top-trailing.
- **Board.** `BoardView` in its landscape mode at full screen. Remote mapping:
  - **Menu/Back** — clears a selected bus first; otherwise back to the home.
  - **Left/Right** (`onMoveCommand`) — the neighbouring saved stop (same order as the home). The
    `BoardViewModel` is kept and told the configuration changed, as `RootView.showBoard` does.
  - **Select** (`onPlayPauseCommand` / a focusable board) — steps through the upcoming buses the
    way tapping a puck does (`model.tap(busID:)`), wrapping back to none.
  - No touch gestures, no settings gear on the board (settings live on the home).
- **Find a stop.** `TVStopFinderView`: a search field (tvOS keyboard / dictation) and the
  **Nearby** list from the TV's approximate location (`requestLocation`-style one-shot; no live
  updates on tvOS). Choosing a stop goes to a TV line picker (focusable line rows, up to 3, then
  "Show board"). Built on the existing `SetupViewModel`; only the views are TV-specific.
- **Settings.** A TV `Form` with appearance, language and "About / data credits". No help pages
  (HelpView), no feedback bubble (LoveLetterUI is linked but its sheet is not offered on TV), no
  wall-mode schedule, no debug menu.
- **Not on TV.** Welcome story (the home is self-explanatory; onboarding is marked done), wall
  mode (keep-awake, drift, dimming), watch sync, WidgetKit.

## 3. iCloud sync of saved stops

- `NSUbiquitousKeyValueStore`, key `history.v1`, value = JSON of `SyncedHistory { entries:
  [SavedSetup], tombstones: [String: Date] }`. Entitlement
  `com.apple.developer.ubiquity-kvstore-identifier = $(TeamIdentifierPrefix)com.hayek.BusBus` on
  the iOS, macOS and tvOS app (all three entitlements files).
- `SavedSetup` gains `modifiedAt: Date`, set when an entry is recorded, pinned, unpinned. Old data
  without it decodes with `modifiedAt = lastUsedAt` (custom `init(from:)`); the widget and watch
  decode it the same way since they share the file.
- **`HistorySync.merge(local:remote:now:)`** — pure, `nonisolated`, tested:
  1. Tombstones: union, keeping the later date per id; drop those older than 60 days.
  2. Entries: union by id; the copy with the later `modifiedAt` wins (ties: the local copy);
     `lastUsedAt` = max of both.
  3. An entry whose `modifiedAt` is not after its tombstone is dropped; otherwise the tombstone is
     cleared (the stop was used again after removal).
  4. `SavedSetups.capped` on the result (pins never aged out).
- Removing an entry locally writes a tombstone. `SettingsStore` keeps the local tombstones in its
  own defaults so a removal made offline still reaches iCloud later.
- **`CloudHistory`** (`@MainActor`, app only): on launch and on
  `didChangeExternallyNotification` it merges the cloud copy into `settings.savedSetups` (which
  already fans out to the App Group, widget and watch); after each local change it writes the
  merged result back. A merge that changes nothing writes nothing (no ping-pong between devices).
  Screenshot mode and tests never touch the cloud. With iCloud off the store is simply local.
- A synced stop whose provider is off (`providerIsAvailable` false) shows on the TV card as
  unavailable and is not opened; flipping between boards passes it over.

## 4. Top Shelf (`BusBusTopShelf`)

- `ContentProvider: TVTopShelfContentProvider`, `loadTopShelfContent()` returns a
  `TVTopShelfSectionedContent` with one section ("Your stops"), one item per saved stop (at most
  8, pinned first). Nothing saved → `TVTopShelfInsetContent` with one item, "Open BusBus to add
  a stop".
- Each item: title = stop name; `displayAction` and `playAction` =
  `WidgetDeepLink.url(for: setup)` (`busbus://setup?id=…`, already handled by the app's
  `onOpenURL`); image = the home row's own `TVStopCard` (16:9, 560×315) rendered with SwiftUI
  `ImageRenderer` at 2× with an "AT HH:MM" stamp, into the App Group's `Library/Caches/TopShelf/`
  under a new file name per draw (the system caches by URL), `imageShape = .hdtv`.
- Numbers come from the App Group snapshot (`WidgetSnapshotStore`); a snapshot over a minute old is
  refetched with `WidgetArrivalsFetcher` under the `WidgetProviderGate` rules. Because the image is
  a still, the card states the time it was drawn instead of a countdown.
- The app calls `TVTopShelfContentProvider.topShelfContentDidChange()` after a board refresh (at
  most every 3 minutes, like the widget reload) and when the history changes.
- The pure part — `StopGlances.build(history:snapshot:now:)` → `[StopGlance]` (setup, deep link,
  next two arrivals per line, whether there are numbers) and `StopGlances.needingFetch` — lives in
  `BusBus/TV/StopGlance.swift`, shared by the TV home and the extension, and tested.

## 5. Testing

- Unit (Swift Testing, `BusBusTests`, run on the Mac):
  `HistorySync` merge rules (newer wins, tombstone beats older, reuse after removal revives, pins
  survive the cap, tombstone expiry, no-change merge is identity, legacy decode);
  `SettingsStore` removal writes a tombstone; `CloudHistory` over an in-memory store (two devices
  round-trip a save and a removal, no re-write of what was just read, an unreadable cloud copy is
  left alone); `StopGlances` (order, stale and missing snapshots, refetch rule, deep link, card
  times); TV stop order / neighbour selection (`TVStopOrder`); board
  layout at 1920×1080 resolves to `.landscape` with scale 1.5.
- Builds: `BusBus` for iOS simulator, macOS, tvOS simulator; `BusBusWatch`; the full Mac test
  run.
- Run: the TV simulator — home, open a board, flip stops, back, find a stop; Top Shelf on the
  simulator home screen.

## Implementation order

1. Project: tvOS destination, platform filters, HelpView filter, entitlements; make the app
   compile for tvOS with fences (no new UI yet — the existing RootView just builds).
2. `SavedSetup.modifiedAt`, `HistorySync` + tests, tombstones in `SettingsStore`, `CloudHistory`.
3. `TVRootView`, home, board remote mapping, stop finder, line picker, settings (tvOS only).
4. `TopShelfCards` + tests; the `BusBusTopShelf` target and its provider; app pings it.
5. Build every scheme, run the Mac tests; code review; fix; run on the TV simulator.
