# My Stops home + map search — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the one-scroll stop picker with a My Stops home and a full-screen map search (drawer, typing, confirm step).

**Architecture:** `SetupViewModel` stays the single model. A small value type, `StopSearchSession`, holds the search screen's own state (presented, drawer height, what BACK restores) and is unit-tested. The search screen is a new set of views under `BusBus/Setup/Search/`; the home replaces `StopPickerView`; `StopMapView` is folded into the new full map and deleted.

**Tech Stack:** SwiftUI, MapKit for SwiftUI, Swift Testing (`BusBusTests`), XCUITest (`BusBusScreenshots`), String Catalogs.

**Spec:** `docs/superpowers/specs/2026-10-18-my-stops-search-design.md` (read it first; the mockup link is in it).

## Global Constraints

- Workspace: `~/Developer/BusBus-search` (a jj workspace off `main`). Never touch `~/Developer/BusBus` — another session's work lives there.
- VCS is **jj** (colocated). Commit with `jj commit -m "<message>"` — never `git commit`. Message style: one sentence in the app's voice (see `jj log`), plus the attribution trailer lines from the system prompt.
- Platforms: iOS/iPadOS and macOS. tvOS never builds these screens (`#if !os(tvOS)` where a file would otherwise be compiled for tvOS — check the target's membership; files under `BusBus/Setup/` are in the app target, which builds for tvOS).
- Colours only from `Theme` (`@Environment(\.theme)`), sizes from `DesignTokens` (`Radius`, `Stroke`, `Spacing`), type only via `.busText(TypeStyles.…, scale:)`. No hex in views.
- Every new user-visible string goes in `BusBus/Localizable.xcstrings` with translations for **all 34 languages** already in the catalog (copy the language list from an existing key like `"SEARCH THIS AREA"`). Reuse existing keys where they exist: `"Search stop or line"`, `"SEARCH THIS AREA"`, `"ZOOM IN TO SEARCH"`, `"MY STOPS"`, `"EDIT"`, `"DONE"`, `"NEARBY"`, `"THIS AREA"`, `"RESULTS"`, `"Back to stops near you"`, `"WELCOME"`, `"Where do you catch the bus?"`.
- New keys (exact English): `"CANCEL"`, `"BACK"`, `"SELECT STOP"`, `"THIS STOP?"`, `"%lld MIN WALK"` (via `String(appLocalized: "\(minutes) MIN WALK")`), `"ADD A STOP"`, `"Find your first stop"`, `"Search by name, or look around you on the map"`, `"NO STOPS MATCH"`, `"Close search"`, `"Stop %lld"` (numbered pin a11y, if needed).
- Comments match the codebase: doc comments that say *why*, in plain English, no "This function…".
- Build/test commands (run from the workspace):
  - Mac unit: `xcodebuild test -project BusBus.xcodeproj -scheme BusBus -destination 'platform=macOS' -only-testing:BusBusTests/<Suite> 2>&1 | tail -30`
  - iOS unit: same with `-destination 'platform=iOS Simulator,id=27E169BE-81D8-4501-A285-C90B6F3EB8DE'`
  - Builds: `xcodebuild build -project BusBus.xcodeproj -scheme BusBus -destination '<dest>' 2>&1 | grep -E "error:|BUILD" | head` for macOS, the iOS simulator above, and `-scheme BusBusTopShelf -destination 'generic/platform=tvOS Simulator'` (tvOS must still build).

## Review Focus

1. **Location never allowed / denied / restricted** — search opens on the region with SEARCH THIS AREA showing and the permission/denied card at the top of the drawer; nothing crashes or spins forever. (Task 2's preview + Task 5 UI test with denied location is not feasible; reviewer checks by reading.)
2. **Tapping a stop while results are still loading or the list changes underneath** (area search returns while confirming) — the confirm panel keeps the stop it was opened for; BACK still restores. Pinned by `confirmSurvivesListRefresh` (Task 1).
3. **Search result with no distance (`distanceMeters < 0`) and no rider location** — confirm panel shows no distance/walk caption rather than "-1 M". Pinned by `walkCaptionIsNilWithoutDistance` (Task 1).
4. **Reopening search after CANCEL / SELECT STOP / board change-stop** — starts fresh (spec "Every opening starts fresh"). Pinned by `openingStartsFresh` (Task 1).
5. **Landscape iPhone and narrow iPad windows** — side panel only when wider than tall *and* ≥ 600pt. Pinned by `sidePanelRule` (Task 1).

---

### Task 1: Search session model

**Files:**
- Create: `BusBus/Setup/Search/StopSearchSession.swift`
- Modify: `BusBus/Setup/SetupViewModel.swift` (add `search` property and the methods below)
- Test: `BusBusTests/Setup/StopSearchTests.swift`

**Interfaces — Produces:**
```swift
nonisolated enum DrawerHeight: Hashable, Sendable { case small, medium, large }

/// The map's framing, kept to put it back after the confirm step.
nonisolated struct SavedCamera: Hashable, Sendable { var center: GeoPoint; var distance: Double }

/// What BACK puts back.
nonisolated struct SearchRestore: Hashable, Sendable {
    var drawer: DrawerHeight
    var scrolledToStopID: String?
    var camera: SavedCamera?
}

nonisolated struct StopSearchSession: Hashable, Sendable {
    var isPresented = false
    var drawer: DrawerHeight = .medium
    /// The keyboard comes up as the screen opens (the welcome's "search by name" only).
    var focusesFieldOnOpen = false
    private(set) var restore: SearchRestore?
    var isConfirming: Bool { restore != nil }
    mutating func open(focusingField: Bool)
    mutating func close()
    mutating func queryChanged(isEmpty: Bool)      // non-empty → .large, empty → .medium (not while confirming)
    mutating func beginConfirm(_ restore: SearchRestore)
    mutating func back() -> SearchRestore?          // clears restore, sets drawer back, returns it
    static func usesSidePanel(_ size: CGSize) -> Bool   // width > height && width >= 600
    static func walkCaption(meters: Double) -> String?  // nil when meters < 0; "90 M · 2 MIN WALK", minutes = max(1, ceil(m / 80))
}
```
`SetupViewModel` additions:
```swift
var search = StopSearchSession()
/// The stop the confirm panel is about, held apart from the list so a refresh cannot swap it out.
private(set) var confirmingStop: NearbyStop?
private(set) var confirmLines: [TransitLine] = []
private(set) var isLoadingConfirmLines = false
func openSearch(focusingField: Bool = false)   // query = "", focusedStopID = nil, confirmingStop = nil, search.open(...); if isAreaSearch → Task { await loadNearby(force: true) }
func closeSearch()                              // search.close(), confirmingStop = nil, focusedStopID = nil
func beginConfirm(_ entry: NearbyStop, restore: SearchRestore) async  // focusedStopID = entry.id, confirmingStop = entry, search.beginConfirm; lines = entry.lines if non-empty else load via the same cache.lines(atStop:) call `choose` uses (record "lines")
func backFromConfirm() -> SearchRestore?        // clears confirmingStop/focusedStopID/confirmLines, returns search.back()
```
`query`'s `didSet` also calls `search.queryChanged(isEmpty:)`. `loadStops` must **not** clear `confirmingStop` (it may keep clearing `focusedStopID` only when not confirming — keep the confirmed pin focused).

- [ ] **Step 1: Write the failing tests** in `BusBusTests/Setup/StopSearchTests.swift` (Swift Testing, `@testable import BusBus`, `@MainActor` where the model is used; build the model as `SetupViewModel(settings: SettingsStore(defaults: UserDefaults(suiteName: #function)!))` like other suites do — check `LineSelectionTests` for the pattern):
  - `typingRaisesTheDrawerAndClearingLowersIt`: session `.medium` → `queryChanged(isEmpty: false)` → `.large`; `queryChanged(isEmpty: true)` → `.medium`.
  - `backRestoresWhatWasThere`: drawer `.small`, `beginConfirm(SearchRestore(drawer: .small, scrolledToStopID: "B", camera: SavedCamera(center: GeoPoint(lat: 32.08, lon: 34.78), distance: 900)))`; `isConfirming`; `back()` returns that restore, `drawer == .small`, `!isConfirming`; a second `back()` returns nil.
  - `typingWhileConfirmingDoesNotMoveTheDrawer`: during confirm, `queryChanged(isEmpty: false)` leaves `drawer` unchanged.
  - `openingStartsFresh`: model with `query = "dizen"` and `search.drawer = .large` → `openSearch()` → `query == ""`, `search.drawer == .medium`, `search.isPresented`, `!search.focusesFieldOnOpen`, `confirmingStop == nil`; `openSearch(focusingField: true)` → `focusesFieldOnOpen`.
  - `closeEndsTheConfirm`: after `beginConfirm`, `closeSearch()` → `confirmingStop == nil`, `focusedStopID == nil`, `!search.isPresented`.
  - `confirmSurvivesListRefresh`: `await beginConfirm(entryA, restore: r)` (give `entryA` non-empty `lines` so no network call is made; `confirmLines == entryA.lines`), then set `model.focusedStopID = nil` (what a list refresh does) → `confirmingStop?.id == entryA.id` still; `backFromConfirm() == r`, then `confirmingStop == nil` and `confirmLines.isEmpty`.
  - `walkCaptionIsNilWithoutDistance`: `walkCaption(meters: -1) == nil`; `walkCaption(meters: 90)` contains `"90 M"` and `"2 MIN WALK"`; `walkCaption(meters: 40)` contains `"1 MIN WALK"`; `walkCaption(meters: 1200)` contains `"1.2 KM"` and `"15 MIN WALK"` (use `DistanceFormatter.text` for the distance part; join with `" · "`).
  - `sidePanelRule`: `usesSidePanel(CGSize(width: 1280, height: 800))`, `usesSidePanel(CGSize(width: 844, height: 390))`, `!usesSidePanel(CGSize(width: 390, height: 844))`, `!usesSidePanel(CGSize(width: 560, height: 500))`.
  Entries: build `NearbyStop(stop: TransitStop(...), distanceMeters: 90, lines: [])` — check `TransitStop`'s initializer in `BusBus/Transit/`.
- [ ] **Step 2: Run, expect compile failure** — Mac unit command with `-only-testing:BusBusTests/StopSearchTests`.
- [ ] **Step 3: Implement** the session type and the model additions as specified above. Add the new strings `"%lld MIN WALK"` to the catalog with 34 translations.
- [ ] **Step 4: Run, expect PASS** (Mac). Also run `-only-testing:BusBusTests/LineSelectionTests -only-testing:BusBusTests/NearbyPermissionTests` to confirm nothing else broke.
- [ ] **Step 5: Commit** — `jj commit -m "Hold the search screen's own state: drawer height, and what BACK puts back"`.

### Task 2: The search screen — map, drawer, typing

**Files:**
- Create: `BusBus/Setup/Search/StopSearchView.swift` (container: header, map, drawer or side panel; chooses layout with `StopSearchSession.usesSidePanel(proxy.size)`)
- Create: `BusBus/Setup/Search/SearchMapView.swift` (full map: today's `StopMapView` logic — `fit()`, `anchor`/`hasMoved`, SEARCH THIS AREA / ZOOM IN TO SEARCH, recenter — without the card overlay; pins numbered while `model.isShowingResults`)
- Create: `BusBus/Setup/Search/SearchDrawer.swift` (grabber + three heights with drag-to-snap; in side-panel mode the same content without grabber/heights)
- Create: `BusBus/Setup/Search/SearchListContent.swift` (what the drawer lists: chips, header + caption, permission/denied cards, skeletons, rows, numbered result rows, "NO STOPS MATCH", the moved `serviceFooter`)
- Modify: `BusBus/Setup/SetupComponents.swift` only if a row needs a `number:` leading badge (add an optional parameter to `RecentStopRow`; don't fork it)

**Interfaces:**
- Consumes: Task 1's `StopSearchSession`, `SetupViewModel.search`, `openSearch/closeSearch`, `beginConfirm`, `backFromConfirm`, `confirmingStop`.
- Produces: `struct StopSearchView: View { var model: SetupViewModel; var onSelect: (TransitStop) -> Void }` — closes itself via `model.closeSearch()`; calls `onSelect` from Task 3's SELECT STOP. Task 2 wires row/pin taps to a placeholder `startConfirm(entry)` function inside `StopSearchView` that Task 3 fills in (for this task it may call `onSelect(entry.stop)` directly so the screen is usable).
- Produces for Task 3: `SearchMapView` takes `@Binding var position: MapCameraPosition` (owned by `StopSearchView`) and reports the last settled camera via `onCameraSettled: (SavedCamera, MKMapRect) -> Void`; it exposes `centerOn(_ stop: GeoPoint, visibleInset: EdgeInsets)` behaviour through a `focusRequest: FocusRequest?` input (`struct FocusRequest: Equatable { var point: GeoPoint; var bottomInset: CGFloat; var leadingInset: CGFloat; var minDistance: Double }`) — when it changes, animate so the point sits in the middle of the area left uncovered.
- Accessibility identifiers (UI tests rely on them): search field `"search.field"`, CANCEL `"search.cancel"`, SEARCH THIS AREA `"search.here"`, recenter `"search.recenter"`. Rows keep their existing accessibility labels (`NearbyStopRow`: "… meters").

- [ ] **Step 1: Build the views** to the spec's §2 Layout/Drawer/Typing and the B · map + drawer / B · typing artboards. Header: real `TextField` (reuse `SearchField`'s look; `@FocusState` focused on appear when `model.search.focusesFieldOnOpen`) + CANCEL. Drawer heights: small ≈ 120pt, medium ≈ 45% of height, large = height − header − 150pt; snap to nearest on drag end with velocity; the list scrolls only at large (`.scrollDisabled(drawer != .large)`). Drag lives on the grabber/header strip so it never fights the map. Recenter button rides above the drawer's top edge (or at the map's bottom-trailing in side-panel mode). Not searching: header reads `NEARBY`/`THIS AREA` with `model.nearbyCaption`; searching: `RESULTS` and numbered rows/pins (numbers = index + 1 in `model.mapStops` order).
- [ ] **Step 2: Add `#Preview`s** for portrait and landscape using `SettingsStore` with `MockTransitProvider` the way other previews in `BusBus/Setup/` or `BusBus/Board/` do (check for an existing preview helper; if none, keep previews minimal).
- [ ] **Step 3: Build** for macOS, iOS simulator and tvOS (TopShelf scheme) — all `BUILD SUCCEEDED`, no new warnings in the new files.
- [ ] **Step 4: Commit** — `jj commit -m "Search on a full map, with the stops in view in a drawer beneath it"`.

### Task 3: The confirm step

**Files:**
- Create: `BusBus/Setup/Search/ConfirmStopPanel.swift`
- Modify: `BusBus/Setup/Search/StopSearchView.swift`, `SearchMapView.swift` (faded pins + halo), `SearchDrawer.swift` (swap content for the panel while `model.search.isConfirming`)

**Interfaces:**
- Consumes: Task 1 (`beginConfirm`, `backFromConfirm`, `confirmingStop`, `confirmLines`, `isLoadingConfirmLines`, `StopSearchSession.walkCaption`), Task 2 (`FocusRequest`, `onCameraSettled`, `startConfirm`).
- Produces: `struct ConfirmStopPanel: View { var entry: NearbyStop; var lines: [TransitLine]; var isLoadingLines: Bool; var colorIndex: (TransitLine) -> Int; var onBack: () -> Void; var onSelect: () -> Void }`. Accessibility identifiers: `"confirm.back"`, `"confirm.select"`; visible labels `"BACK"` / `"SELECT STOP"`.

- [ ] **Step 1: Implement** per spec §2 "The confirm step" and the B · confirm the stop artboard:
  - `startConfirm(entry)`: build `SearchRestore` (current drawer, the row id the list is scrolled to via `ScrollPosition`/`scrollPosition(id:)`, last settled `SavedCamera`), call `await model.beginConfirm(entry, restore:)`, issue a `FocusRequest` with the panel's height as `bottomInset` (or the side panel's width as `leadingInset`) and `minDistance` so the map only zooms in when the current view is wider than ≈ 1.5 km.
  - Pins: confirming pin uses `StopPin`'s focused look plus a soft halo; others `opacity(0.4)` and `.allowsHitTesting(false)`; a second tap on the focused pin does nothing.
  - Panel: "THIS STOP?" caption; trailing `walkCaption` only when the distance is known (compute from `model.location.current` for search results whose `distanceMeters < 0`; nil when no fix); name (large), address (`StopAddresses`); line badges (`LineBadgeView` or the row's badge component) — shimmer while `isLoadingConfirmLines`; BACK (outlined, leading chevron) and SELECT STOP (filled with `theme.primaryButtonFill`, trailing chevron), widths 1 : 2, height `Spacing.buttonHeightPhone`.
  - BACK — the button, a tap on the faded map, Escape on Mac (`.onExitCommand`/`.keyboardShortcut(.cancelAction)`): `backFromConfirm()`, set drawer, scroll back to the saved row, animate the camera back to the saved one.
  - SELECT STOP: `onSelect(entry.stop)`.
  - VoiceOver: on appear post `AccessibilityNotification.ScreenChanged` and move focus to the name (`@AccessibilityFocusState`).
  - Strings: `"THIS STOP?"`, `"BACK"`, `"SELECT STOP"` with 34 translations.
- [ ] **Step 2: Build** macOS + iOS simulator + tvOS — `BUILD SUCCEEDED`.
- [ ] **Step 3: Run** `StopSearchTests` on Mac — PASS.
- [ ] **Step 4: Commit** — `jj commit -m "Ask before choosing: a tapped stop is centred on the map, with BACK and SELECT STOP"`.

### Task 4: My Stops home and wiring

**Files:**
- Create: `BusBus/Setup/MyStopsView.swift` (replaces `StopPickerView`)
- Delete: `BusBus/Setup/StopPickerView.swift`, `BusBus/Setup/StopMapView.swift` (move `AttributedString(creditLine:)` and `StopPin` to where they're still used — `SearchListContent.swift` / `SearchMapView.swift`)
- Modify: `BusBus/ContentView.swift` (root view, presentation, welcome routing)
- Modify: `BusBus.xcodeproj/project.pbxproj` only if the target does not use synchronized folders (it does: 11 `PBXFileSystemSynchronizedRootGroup`s — new/deleted files need no project edit; verify the build).

**Interfaces:**
- Consumes: `StopSearchView(model:onSelect:)`, `SetupViewModel.openSearch(focusingField:)`, `closeSearch()`, `search.isPresented`.
- Produces: `struct MyStopsView: View { var model: SetupViewModel; var onOpenSettings: () -> Void; var onOpenFeedback: (() -> Void)?; var onResume: (SavedSetup) -> Void }` (no `onChoose` — choosing happens in search). Accessibility identifiers: search bar button `"home.search"`, Add a stop `"home.addStop"`, empty-state card `"home.findFirst"`.

- [ ] **Step 1: Implement `MyStopsView`** per spec §1 and the `Main` artboard: title MY STOPS (welcome copy when `isWelcome` as today), EDIT + feedback + DEBUG gear; search bar as a `Button` styled like `SearchField` with the placeholder text "Search stop or line"; all `model.history` rows (`HistorySetupRow` with ⓘ, swipe-to-remove, EDIT); dashed ADD A STOP row; empty state card ("Find your first stop" / "Search by name, or look around you on the map") instead of rows + Add when history is empty; footer region caption only. Wide layouts: one centred column, `maxWidth: 640`. Keep `.sheet(item: $inspectedStop)` for ⓘ, keep the `scenePhase`/`location.status` reload hooks only if the home still shows anything location-dependent (it doesn't — move them to `StopSearchView`).
- [ ] **Step 2: Wire `ContentView`**: root is `MyStopsView`. Present `StopSearchView` with `.fullScreenCover` on iOS and `.sheet` (frame `minWidth: 900, minHeight: 640`) on macOS, bound to `setup.search.isPresented` (setter calls `closeSearch()` on dismiss). `onSelect`: `setup.rememberSearchIfAny()`, `setup.closeSearch()`, `path.append(.lines)`, `Task { await setup.choose(stop) }`. Welcome: `.allowLocation` → after the fade `setup.openSearch()` then the existing `loadNearby(force: true, askingPermission: true)`; `.searchByName` → `setup.openSearch(focusingField: true)` (delete `requestsSearchFocus` and its uses); `.timedOut` → nothing. `replayWelcomeIfAsked` also calls `setup.closeSearch()`. Board's `onChangeStop` stays `path.removeAll()` (lands on home).
- [ ] **Step 3: Strings** `"ADD A STOP"`, `"Find your first stop"`, `"Search by name, or look around you on the map"`, `"CANCEL"`, `"Close search"`, `"NO STOPS MATCH"` — ensure all present with 34 translations; remove catalog keys that no code uses any more only if Xcode marks them stale (leave them otherwise).
- [ ] **Step 4: Build** macOS + iOS simulator + tvOS; run the whole `BusBusTests` on Mac — PASS.
- [ ] **Step 5: Commit** — `jj commit -m "Open on My Stops, with search a tap away on its own screen"`.

### Task 5: Screenshots and integration tests

**Files:**
- Modify: `BusBus/Screenshots/ScreenshotMode.swift` (add `case search` — "The search screen on the mock's nearby stops"), `ContentView.swift`'s `stageScreenshot` (`.search` → `setup.openSearch()`), `ScreenshotStage.swift` (`.search` like `.stops`: no configuration)
- Modify: `BusBusScreenshots/PreviewJourneyTests.swift`, `BusBusScreenshots/MacPreviewJourneyTests.swift` (the journey now: tap `home.search` → row → `confirm.select` → lines)
- Create: `BusBusScreenshots/SearchFlowTests.swift` (runs on iOS and macOS; not skipped)
- Modify: `scripts/screenshots.sh` only to keep `stops` working (add `search` to its list only if it iterates screens explicitly)

**Interfaces:** consumes the identifiers from Tasks 2–4.

- [ ] **Step 1: Write `SearchFlowTests`** (XCTest UI). Launch with `["-screenshot", "stops", "-screenshotAppearance", "dark", "-ApplePersistenceIgnoreState", "YES"]`, `launchEnvironment["TZ"] = "Asia/Jerusalem"`. Helpers use `tap()` on iOS and `click()` on macOS (`#if os(macOS)`). Tests:
  - `testSavedStopOpensWithoutConfirm`: the home lists a saved stop (`buttons` label BEGINSWITH "CANAL ST" or whichever `HistorySetupRow` label the staged history yields — read `HistorySetupRow.accessibilityLabel`); tap → the board appears (assert `confirm.select` never exists and a board element exists, e.g. the change-stop control's label — read `BoardView`).
  - `testSearchConfirmBackThenSelect`: tap `home.search` → `search.field` exists → first row with label CONTAINS "meters" exists within 10 s → tap → `confirm.select` and `confirm.back` exist → tap `confirm.back` → `confirm.select` disappears and the same row is hittable → tap the row again → tap `confirm.select` → the search screen is gone and the line picker's confirm button `"SHOW THE MAP"` exists.
  - `testCancelClosesAndReopensFresh`: tap `home.search`, type "har" into `search.field`, tap `search.cancel` → `home.search` exists → tap it → `search.field` value is empty (placeholder).
- [ ] **Step 2: Run on Mac**: `xcodebuild test -project BusBus.xcodeproj -scheme BusBusScreenshots -destination 'platform=macOS' -only-testing:BusBusScreenshots/SearchFlowTests 2>&1 | tail -40` → all pass.
- [ ] **Step 3: Run on iOS simulator**: same with `-destination 'platform=iOS Simulator,id=27E169BE-81D8-4501-A285-C90B6F3EB8DE'` → all pass.
- [ ] **Step 4: Update the two preview journeys** to the new flow and make sure they still compile (they skip without `PREVIEW_JOURNEY`).
- [ ] **Step 5: Commit** — `jj commit -m "Stage the search screen, and test the way to a stop end to end on Mac and iPhone"`.
