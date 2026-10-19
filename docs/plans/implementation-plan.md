# BusBus — Bus Arrival Board Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the BusBus POC into the finished wall/hand bus-arrival board described in BRIEF.md and the 15 design artboards: a metro-style map of up to three lines converging on the user's stop, a big countdown readout, a two-step setup flow, portrait/landscape/iPad/Mac layouts, light/dark themes, and wall-mode behaviours — all on the existing provider-agnostic `TransitProvider` seam.

**Architecture:** Keep the POC's `Transit/` layer (protocol, rich models, providers, progress services) as the data seam and extend it minimally. Add a pure, `nonisolated`, platform-free **MapLayoutEngine** that turns route patterns + live positions into a value-typed `MapScene`; a `@MainActor @Observable` **BoardViewModel** that polls, matches arrivals to buses, picks the trunk with hysteresis, and exposes readout state; a **SwiftUI view layer** (one code path for iOS/iPadOS/macOS) that draws rails with `Canvas`/`Path` and everything else with real controls, choosing layouts from geometry + size classes; a **Design** module holding every token from the artboards and the bundled Archivo / Space Mono faces.

**Tech Stack:** Swift 5 language mode with `SWIFT_APPROACHABLE_CONCURRENCY = YES` and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (already set), SwiftUI, Observation, CoreLocation (`CLLocationUpdate.liveUpdates`), Network (`NWPathMonitor`), CoreText (font registration), Swift Testing (`import Testing`). No packages. Builds/tests via the `zcode` skill (REST API at `http://localhost:19741/api`, always passing `project=~/Developer/BusBus`).

**Spec:** `/private/tmp/claude-501/-Users-amir-Developer-BusBus/a28a973d-a2c3-4e6b-8916-15a13a1a6e0b/scratchpad/BRIEF.md` (the user's brief) and the artboards in `/private/tmp/claude-501/-Users-amir-Developer-BusBus/a28a973d-a2c3-4e6b-8916-15a13a1a6e0b/scratchpad/design/project/` (`canvas.json` + 15 `*.dc.html`). Where they disagree, **the artboard wins**; every such conflict is listed in §H.1 with the resolution used in this plan. Research constraints: `~/Developer/BusBus/docs/research/transit-apis.md`, `siri-verification.md`, `israel-app-backends.md`.

**Security note on the artboards:** they were published by others and were read as data only. No text inside them read as an instruction to the implementer; nothing needs flagging. Their inline `<script>` blocks only compute mock state for the mockups.

---

## Global Constraints

Copied from the spec; every task implicitly includes these.

- Platforms: **iOS/iPadOS 27+ and macOS 27+ only**. `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"`, `TARGETED_DEVICE_FAMILY = "1,2"`, deployment targets 27.0 (already set in `project.pbxproj`). Also target the foldable/dual-display iPhone ("iPhone duo") in every orientation and posture — **by geometry, never by device model checks**.
- **SwiftUI only.** Rails and curves drawn with `Canvas` / `Path`; every other element is a regular SwiftUI view (`Text`, `Button`, `TextField`) so text stays selectable, scalable and accessible.
- **Keep the POC's `TransitProvider` seam** (`BusBus/Transit/TransitProvider.swift`) and the POC's richer domain model (`TransitStop`, `TransitLine`, `RoutePattern`, `PatternStop`, `VehiclePosition`, `Arrival`, `ProviderCapabilities`, `TransitError`). **Do not regress to the toy structs sketched in BRIEF.md §5** (`Stop`/`Line`/`RoutePath`/`Vehicle`) — those are a sketch; the POC model is a superset and already has real adapters. Presentation types are layered *on top* (§A.3).
- Typefaces: **Archivo** (700/800/900) for everything structural and numeric, **Space Mono** (700) for codes, times, stop names and small captions. Both are staged as static OFL files in `BusBus/Resources/Fonts/`. **Never** Inter/Roboto/Arial/SF as a substitute for the display face (§C.4 makes substitution loud, not silent).
- Colour tokens exactly as in §C.1/§C.2. Badge/puck numerals are always `#08080B` on the dark palette and `#14140F` in light mode.
- No divider hairlines between header / map / readout. No gradients, no emoji as UI glyphs, no fake status bar or keyboard, no left-border accent cards.
- Poll every 20–30 s; never block the UI on a refresh; keep last good data; LIVE indicator turns stale after 90 s without a successful fetch.
- Hard cap of 3 lines. Trunk re-layout animates ~400 ms and happens at most once per 30 s.
- Accessibility: real controls, labels on icon-only buttons, pucks announce "Bus 41, 2 minutes away, 1 stop", touch targets ≥ 44 pt, Dynamic Type in hand mode (wall mode fixed), contrast ≥ 4.5:1 (3:1 at ≥ 24 pt).
- Don't build: accounts, trip planning, multi-stop dashboards, notifications, crowding/capacity.
- Widgets were added later (`BusBusWidget`, a multiplatform WidgetKit extension; every size, lock screen included). Each shows one entry of the history picker, chosen by editing the widget. The app and the extension share the App Group `group.com.hayek.BusBus`: the history (`SharedHistoryStore`), copies of the palette/appearance/language, and per-stop arrival snapshots the board writes on every refresh (`WidgetBridge`). The widget counts down from a snapshot and fetches `arrivals(for:at:)` itself when the snapshot is over a minute old; MTA Bus Time and Metro Transit are snapshot-only, and a provider the remote switches turned off (mirrored into the group by `SettingsStore.mirrorProviderSwitches`; Transitous off until mirrored) is never called. Every timeline ends on an "open the app" picture, since WidgetKit may defer the next reload for hours. The history is still written to the app's own `board.savedSetups` too, as the fallback when the shared copy is missing, older or unreadable. It shares app sources by file membership (the `BusBus` folder's exception set) and compiles with `BUSBUS_WIDGET`. It links no Firebase: App Check reaches the transit layer through `TransitProxy.attestation`, which `Telemetry.start()` sets.
- Build order follows BRIEF.md §8 with one deliberate change: the **unit-test target is created first** (it does not exist yet; §I Task 1) and the **font registration/verification** is pulled forward to Task 3 because every screen depends on it.

### Verification mechanism (used by every task)

```bash
# Build only
curl -s -X POST http://localhost:19741/api/build -H "Content-Type: application/json" -d '{"project": "~/Developer/BusBus"}'
# Errors/warnings after a build
curl -s -G "http://localhost:19741/api/build-errors" --data-urlencode "project=~/Developer/BusBus"
# Run the unit tests (builds first)
curl -s -X POST http://localhost:19741/api/test -H "Content-Type: application/json" -d '{"project": "~/Developer/BusBus"}'
curl -s -G "http://localhost:19741/api/test-results" --data-urlencode "project=~/Developer/BusBus"
# Build and run the app on the selected destination
curl -s -X POST http://localhost:19741/api/run -H "Content-Type: application/json" -d '{"project": "~/Developer/BusBus"}'
# Choose a destination first if needed
curl -s -G "http://localhost:19741/api/destinations" --data-urlencode "project=~/Developer/BusBus"
```

Use the **My Mac** destination for the test loop (fastest; the app is a macOS app too). Use an iPhone simulator (portrait and landscape) and an iPad simulator for the layout checks called out in §I. If Zcode is not running, start the app first.

---

## A. Architecture

### A.1 Facts verified in `project.pbxproj`

- `objectVersion = 90`, `preferredProjectObjectVersion = 90`. The app target `BusBus` (`AA0000000000000000000040`) uses a `PBXFileSystemSynchronizedRootGroup` (`AA0000000000000000000031`, `path = BusBus`). **Every `.swift` file created anywhere under `BusBus/` is compiled into the app target with no pbxproj edit.** Non-source files under `BusBus/` (the `.ttf` files, `Assets.xcassets`) are copied as resources by the same mechanism — Task 3 verifies this explicitly rather than assuming it.
- There is **exactly one target**; no unit-test target exists. Task 1 adds `BusBusTests` by hand-editing the pbxproj (exact text in §I Task 1) and registers it in the shared scheme `BusBus.xcodeproj/xcshareddata/xcschemes/BusBus.xcscheme` (whose `<Testables>` is currently empty) so `zcode` `/api/test` runs it.
- `GENERATE_INFOPLIST_FILE = YES` with `INFOPLIST_KEY_*` build settings; there is no `INFOPLIST_KEY_` equivalent for `UIAppFonts`, and macOS would want `ATSApplicationFontsPath` instead. Therefore fonts are **registered at runtime with CoreText** (§C.4), not via Info.plist.
- `ENABLE_APP_SANDBOX = YES`, `ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES`, **`ENABLE_RESOURCE_ACCESS_LOCATION = NO`** → must become `YES` (Task 14) for macOS location; add `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription`.
- `SWIFT_VERSION = 5.0`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`, `ENABLE_TESTABILITY = YES` (Debug) → `@testable import BusBus` works from the test target.
- Supported orientations already include all iPhone orientations except upside-down and all iPad orientations. Leave as is (an old wall phone may be mounted either way; landscape left/right are both supported).

### A.2 File tree when done

`(keep)` = existing file untouched, `(modify)` = existing file edited, `(new)` = created, `(delete)` = removed.

```
BusBus/
  BusBusApp.swift                              (modify) registers fonts, injects SettingsStore/Theme, macOS window sizing
  ContentView.swift                            (modify) RootView: routes to SetupFlowView or BoardView from persisted config
  Home/HomeView.swift                          (delete) replaced by Board/BoardView.swift
  Settings/SettingsView.swift                  (modify) real settings: wall mode, tap behaviour, appearance, provider, change stop/lines, DEBUG → POC
  POC/POCViews.swift                           (keep)   DEBUG-only diagnostics, still reachable from Settings
  Transit/
    TransitProvider.swift                      (modify) + stopsNearby(_:radiusMeters:), + TransitProviders.provider(id:) unchanged
    Models/TransitModels.swift                 (modify) + NearbyStop, + ProviderCapabilities.nearbyStops, + Arrival.delay
    Networking/HTTPClient.swift                (keep)
    Providers/BusGovILProvider.swift           (modify) + stopsNearby via Stops/GetStopsCloseToLocation
    Providers/StrideProvider.swift             (modify) + stopsNearby → throws .unsupported; capability not declared
    Providers/MockTransitProvider.swift        (rewrite) seeded from MapFixtures, 3 lines, selectable merge scenario, moving buses
    Providers/IsraelRouteLongName.swift        (keep)
    Progress/RouteGeometry.swift               (keep)
    Progress/BusProgressService.swift          (modify) BusProgress gains `arrivals: [Arrival]` (all, soonest first)
    Progress/BusTracker.swift                  (keep)   still used by the POC screens only
    Cache/RoutePatternCache.swift              (new)    JSON cache of RoutePattern per provider+line id, 24 h TTL, Application Support
  MapEngine/                                   (all new, nonisolated, imports Foundation + CoreGraphics only — NO SwiftUI)
    MapEngineTypes.swift                       input types: MapAxis, MapSizePreset, MapStopInput, MapLineInput, MapVehicleInput, MapLayoutRequest
    MapScene.swift                             output scene graph: MapScene, RailNode, RailSegment, StopMark, TerminusMark, DashRun, StopLabel, PuckMark, ConvergenceMark
    MapMetrics.swift                           every geometry constant per preset (§B.4), scaled by `scale`
    RailPath.swift                             ordered [RailSegment] + across(atAlong:) evaluation
    JunctionDetector.swift                     junction detection (§B.2)
    RouteCompressor.swift                      per-line compression into drawn/dashed runs (§B.3)
    MapLayoutEngine.swift                      `MapLayoutEngine.layout(_ request:) -> MapScene` (§B.5)
    TrunkSelector.swift                        30 s hysteresis (§B.7)
    MapFixtures.swift                          fixture routes for Main + Merge A/B/C, used by tests and MockTransitProvider
  Design/
    DesignTokens.swift                         Theme (colours dark/light), Radii, Strokes, Spacing, EnvironmentValues.theme
    LinePalette.swift                          12-colour palette (dark/light rail/light text), stable assignment
    Typography.swift                           BusFont enum (typed font API over PostScript names), TypeStyle catalogue
    FontRegistrar.swift                        runtime CoreText registration + verification
  Board/
    BoardLayoutMode.swift                      geometry + size class → mode (.landscape/.landscapeSingle/.phone/.pad), scale, section heights
    BoardViewModel.swift                       @MainActor @Observable: polling, snapshot, arrivals↔buses matching, trunk, selection, readout models
    BoardModels.swift                          BoardBus, BoardArrival, BoardSnapshot, ReadoutPrimary, ReadoutSecondary, TappedBusDetail (nonisolated)
    BoardView.swift                            screen root: header / map / readout, picks layout, wall-mode wrappers, settings affordance
    HeaderView.swift                           title, stop caption, LIVE indicator, clock (+ line badge in single-line mode)
    MapView.swift                              GeometryReader → MapLayoutRequest → MapScene; layers: MapRailsCanvas, StopLabelsLayer, PucksLayer, node caption, hint
    MapRailsCanvas.swift                       Canvas drawing rails, dashes, termini, rings, capsules, stub, node from MapScene
    StopLabelsLayer.swift                      rotated/horizontal Text labels positioned from MapScene.labels
    BusPuckView.swift                          the 44×36 puck Button (halo, ring, scale, a11y label, ≥44 pt hit area)
    LineBadgeView.swift                        square badge (sizes: 104/84/76/60/56/48/44/40/38/30) with optional white ring
    ReadoutView.swift                          landscape readout band (primary + THEN card / tapped card)
    ReadoutPortraitView.swift                  phone + iPad portrait readouts
    ThenCardView.swift                         THEN card variants (landscape card, light outline, phone bare row, iPad bar)
    TappedBusCardView.swift                    BusDetail "beside" card
    LiveIndicatorView.swift                    dot + LIVE/STALE/CONNECTING
    ClockView.swift                            HH:mm Space Mono clock, ticks each minute
  Setup/
    SetupFlowView.swift                        NavigationStack: StopPickerView → LinePickerView → dismiss to board
    SetupViewModel.swift                       @MainActor @Observable: search, nearby, recents, chosen stop, selected lines
    StopPickerView.swift                       Step 1 (landscape two columns / portrait one column)
    NearbyStopRow.swift                        distance chip, name, ≤3 badges + "+N"
    RecentStopRow.swift                        recent row (landscape) / chip (portrait)
    LinePickerView.swift                       Step 2 grid (6-across / 3-across), footer
    LineChipView.swift                         selectable line chip (border/fill/check/muted)
    SearchField.swift                          labelled TextField with magnifier
    LocationService.swift                      @MainActor @Observable CoreLocation wrapper (liveUpdates), denied fallback
  Persistence/
    SettingsStore.swift                        @MainActor @Observable; BoardConfiguration + recents + palette assignments in UserDefaults; @AppStorage-style flags
  Wall/
    WallModeController.swift                   idle timer / sleep prevention, burn-in drift, ambient dimming (iOS), platform no-ops
    SettingsAffordanceOverlay.swift            tap-anywhere → gear button, fades after 4 s
  Resources/Fonts/                             (exists) Archivo-*.ttf, SpaceMono-*.ttf, OFL-*.txt
  Assets.xcassets                              (keep)

BusBusTests/                                   (new target, Swift Testing, @testable import BusBus)
  MapEngine/JunctionDetectorTests.swift
  MapEngine/RouteCompressorTests.swift
  MapEngine/MapLayoutEngineTests.swift
  MapEngine/RailPathTests.swift
  MapEngine/TrunkSelectorTests.swift
  Design/FontRegistrationTests.swift
  Design/LinePaletteTests.swift
  Board/BoardViewModelTests.swift
  Board/BoardLayoutModeTests.swift
  Setup/LineSelectionTests.swift
  Persistence/SettingsStoreTests.swift
```

### A.3 Layers and the seam

```
┌──────────────────────────────────────────────────────────────────────┐
│ SwiftUI views (Board/, Setup/, Wall/, Design/)                        │  knows: MapScene, Board* models, Theme
├──────────────────────────────────────────────────────────────────────┤
│ Presentation: BoardViewModel, SetupViewModel, SettingsStore,          │  knows: TransitProvider protocol + domain
│               MapLayoutEngine (pure), TrunkSelector (pure)           │  model; NOT which provider
├──────────────────────────────────────────────────────────────────────┤
│ Transit seam: protocol TransitProvider + domain model                 │  ← THE SEAM (unchanged shape, +1 method)
├──────────────────────────────────────────────────────────────────────┤
│ Adapters: BusGovILProvider, StrideProvider, MockTransitProvider       │  only place that knows URLs / wire formats
└──────────────────────────────────────────────────────────────────────┘
```

- Nothing above the seam imports or names `BusGovILProvider`. The only place a provider is instantiated is `TransitProviders.all`; the view model receives `any TransitProvider`.
- The MapEngine does not import the transit model at all. `BoardViewModel` adapts `RoutePattern`/`TrackedBus` into `MapLineInput`/`MapVehicleInput` (adapter function `MapInputAdapter.makeRequest(...)` in `BoardViewModel.swift`). This keeps the engine trivially testable with string fixtures.
- Provider capability gaps are handled in the view model, never in views: views render optionals as absent segments (§F.4).

### A.4 Concurrency model

- Project default isolation is `MainActor`. Anything that must be `Sendable` or run off-main is declared `nonisolated` exactly as the POC does (`nonisolated struct`, `nonisolated enum`, `nonisolated protocol`). Rules:
  - `MapEngine/*`: every type `nonisolated struct/enum ... : Hashable, Sendable`; every function `nonisolated static func`. Pure; no `Date()` inside (time is an input). `TrunkSelector` takes `now: Date` as a parameter.
  - `Board/BoardModels.swift`: `nonisolated` value types, `Sendable`.
  - `BoardViewModel`, `SetupViewModel`, `SettingsStore`, `LocationService`, `WallModeController`: `@MainActor @Observable final class`. Network work happens inside `Task { }` bodies that call `nonisolated` provider methods; results are assigned on the main actor.
  - Providers stay `nonisolated struct ...: TransitProvider` (Sendable). `RoutePatternCache` is an `actor` (file I/O off-main).
  - `HTTPClient` unchanged.
- Polling: one `Task` per `BoardViewModel` (cancelled on disappear); per refresh, lines are fetched concurrently with `withThrowingTaskGroup`. Countdown does not tick the view model: views use `TimelineView(.periodic(from: .now, by: 1))` and compute minutes from `expectedAt` (§F.2).
- Observation: views read `@Observable` state directly; no Combine.

---

## B. The layout engine (`BusBus/MapEngine/`)

A pure function from (route data, live positions, trunk, axis, canvas) to a value-typed scene graph. Everything here is `nonisolated`, `Sendable`, deterministic, and has no SwiftUI import. Coordinates are in **canvas points** of the map area (the view passes the map area's size; the header/readout are laid out by SwiftUI outside the engine).

Two internal axes are used throughout: **along** (the direction of travel: left→right in landscape, top→bottom in portrait) and **across** (perpendicular). The engine computes in (along, across) and converts to `CGPoint` at the end: horizontal axis → `CGPoint(x: along, y: across)`, vertical → `CGPoint(x: across, y: along)`.

### B.1 Types (`MapEngineTypes.swift`, `MapScene.swift`)

```swift
import Foundation
import CoreGraphics

nonisolated enum MapAxis: Hashable, Sendable { case horizontal, vertical }

/// Which artboard's numbers apply. Chosen by BoardLayoutMode (§D), not by the engine.
nonisolated enum MapSizePreset: Hashable, Sendable {
    case landscape        // Main / Merge / BusDetail / MainLight (1280×720, 2–3 lines)
    case landscapeSingle  // SingleLine (1280×720, 1 line)
    case phone            // PhoneOneLine / PhoneTwoLines / PhonePortrait (390×844)
    case pad              // PadPortrait (834×1194)
}

nonisolated struct MapStopInput: Hashable, Sendable {
    var code: String
    var name: String
}

nonisolated struct MapLineInput: Identifiable, Hashable, Sendable {
    var id: String                 // TransitLine.id
    var number: String             // TransitLine.shortName
    var colorIndex: Int            // 0...11 into LinePalette
    /// Terminus first ... user's stop LAST (inclusive). The adapter trims anything after the user's stop.
    var stops: [MapStopInput]
}

nonisolated struct MapVehicleInput: Identifiable, Hashable, Sendable {
    var id: String
    var lineID: String
    var lastStopIndex: Int          // index into MapLineInput.stops; 0 = at/after terminus
    var progressToNext: Double      // 0...1 towards stops[lastStopIndex + 1]
    var isSelected: Bool            // carries the white ring
}

nonisolated struct MapLayoutRequest: Hashable, Sendable {
    var lines: [MapLineInput]       // in the user's selection order, count 1...3
    var trunkLineID: String         // must be one of lines[].id
    var userStopCode: String
    var vehicles: [MapVehicleInput]
    var axis: MapAxis
    var preset: MapSizePreset
    var canvasSize: CGSize          // the map area in points
    var scale: CGFloat              // from BoardLayoutMode (1.0 at the reference size)
    /// Lines whose stops get names. nil = all. Phone portrait with 3 lines passes [trunkLineID] (distance spines).
    var namedLineIDs: Set<String>?
    /// BusDetail "beside" mode: every line except this one is drawn at 45 % opacity. nil = nothing dimmed.
    var highlightedLineID: String?
}
```

```swift
nonisolated enum RailSegment: Hashable, Sendable {
    case line(from: CGPoint, to: CGPoint)
    case cubic(from: CGPoint, c1: CGPoint, c2: CGPoint, to: CGPoint)
    case dashed(from: CGPoint, to: CGPoint, on: CGFloat, off: CGFloat)
}

nonisolated struct RailNode: Identifiable, Hashable, Sendable {
    var id: String { lineID }
    var lineID: String
    var colorIndex: Int
    var width: CGFloat              // stroke width in points (already scaled)
    var segments: [RailSegment]     // in along order, terminus → convergence end
    var isTrunk: Bool
    var dimmed: Bool
}

nonisolated enum StopMarkKind: Hashable, Sendable {
    case ring(colorIndex: Int)               // single line at this stop
    case capsule                             // shared by ≥2 drawn lines; white/ink
}

nonisolated struct StopMark: Identifiable, Hashable, Sendable {
    var id: String                           // "\(lineID)#\(stopIndex)" or "shared#\(code)"
    var stopCode: String
    var kind: StopMarkKind
    var center: CGPoint                      // ring centre, or capsule centre
    var ringRadius: CGFloat                  // ring only (centre-line radius)
    var strokeWidth: CGFloat
    var capsuleRect: CGRect                  // capsule only (path rect; stroke centred on it)
    var capsuleCornerRadius: CGFloat
    var lineIDs: [String]                    // lines served here (1 for ring)
    var dimmed: Bool
}

nonisolated enum TerminusStyle: Hashable, Sendable {
    case bar                                 // landscape: 10×40 rounded bar
    case badge(number: String)               // portrait: rounded square with the line number
}

nonisolated struct TerminusMark: Identifiable, Hashable, Sendable {
    var id: String { lineID }
    var lineID: String
    var colorIndex: Int
    var rect: CGRect
    var cornerRadius: CGFloat
    var style: TerminusStyle
    var fontSize: CGFloat                    // badge only
    var dimmed: Bool
}

nonisolated struct DashRun: Identifiable, Hashable, Sendable {
    var id: String                           // "\(lineID)#dash\(n)"
    var lineID: String
    var from: CGPoint
    var to: CGPoint
    var swallowedCount: Int                  // the N in "+N STOPS"
    var labelCenter: CGPoint                 // centre of the "+N STOPS" caption
    var showLabel: Bool                      // false on a bundle dash for all rails but the trunk
}

nonisolated enum StopLabelRole: Hashable, Sendable {
    case terminus(colorIndex: Int)           // line colour (light mode: line text colour)
    case stop                                // stopName token
    case junction                            // primary text (white / ink)
}

nonisolated enum LabelAlignment: Hashable, Sendable { case leading, trailing }

nonisolated struct StopLabel: Identifiable, Hashable, Sendable {
    var id: String
    var text: String                         // already uppercased
    var anchor: CGPoint                      // landscape: bottom-left of the text box; portrait: vertical centre of the leading (or trailing) edge
    var rotationDegrees: Double              // -35 in landscape, 0 in portrait
    var alignment: LabelAlignment
    var role: StopLabelRole
    var fontSize: CGFloat
    var dimmed: Bool
}

nonisolated struct PuckMark: Identifiable, Hashable, Sendable {
    var id: String                           // vehicle id
    var vehicleID: String
    var lineID: String
    var lineNumber: String
    var colorIndex: Int
    var center: CGPoint
    var size: CGSize                         // 44×36 scaled
    var cornerRadius: CGFloat
    var fontSize: CGFloat
    var isSelected: Bool
    var dimmed: Bool
}

nonisolated struct ConvergenceMark: Hashable, Sendable {
    var stubFrom: CGPoint
    var stubTo: CGPoint
    var stubWidth: CGFloat
    var nodeCenter: CGPoint
    var nodeRadius: CGFloat                  // centre-line radius (26 scaled)
    var nodeStrokeWidth: CGFloat             // 12 scaled
    var captionAnchor: CGPoint               // "YOUR STOP"
    var captionAlignment: LabelAlignment     // landscape: centred below (use .leading with anchor = centre-top and let the view centre it); portrait: .leading, vertically centred
    var captionIsBelow: Bool                 // true in landscape
    var captionFontSize: CGFloat
}

nonisolated struct MapScene: Hashable, Sendable {
    var axis: MapAxis
    var preset: MapSizePreset
    var scale: CGFloat
    var trunkLineID: String
    var rails: [RailNode]                    // draw order: non-trunk first, trunk last
    var termini: [TerminusMark]
    var dashes: [DashRun]
    var stops: [StopMark]                    // draw after rails; capsules after rings
    var labels: [StopLabel]
    var pucks: [PuckMark]                    // draw last; selected puck last of all
    var convergence: ConvergenceMark
    var hintAnchor: CGPoint?                 // "TAP A BUS TO INSPECT IT" (landscape only)
    /// Per line: along-coordinate of every stop index (incl. swallowed and the user's stop = node). Used by tests and by puck placement.
    var stopAlong: [String: [CGFloat]]
}
```

`RailPath.swift`:

```swift
nonisolated struct RailPath: Hashable, Sendable {
    var axis: MapAxis
    var segments: [RailSegment]

    /// The across-coordinate of the rail at a given along-coordinate. Straight and dashed segments are linear;
    /// cubic segments are evaluated at u = (along - from.along) / (to.along - from.along) — an approximation that is
    /// exact at both ends and within 2 pt in the middle for the curve shapes used here (control points never fold back).
    func across(atAlong along: CGFloat) -> CGFloat
    /// Convenience: the CGPoint on the rail at `along`.
    func point(atAlong along: CGFloat) -> CGPoint
}
```

### B.2 Junction detection (`JunctionDetector.swift`)

```swift
nonisolated struct JunctionResult: Hashable, Sendable {
    /// Index into the joining line's `stops` of the first shared stop, or nil (independent rail all the way).
    var lineJunctionIndex: Int?
    /// Index into the trunk's `stops` of the same stop.
    var trunkJunctionIndex: Int?
    /// true when the entire line (terminus included) lies on the trunk.
    var lineIsSubsetOfTrunk: Bool
}

nonisolated enum JunctionDetector {
    /// Walks both sequences backwards from the user's stop, comparing stop CODES index by index.
    static func junction(of line: MapLineInput, onto trunk: MapLineInput, userStopCode: String) -> JunctionResult
}
```

Algorithm (exact):

1. `iUser = trunk.stops.lastIndex { $0.code == userStopCode }`, `jUser = line.stops.lastIndex { $0.code == userStopCode }`. Because the adapter trims each `stops` array to end at the user's stop, both are `count - 1`; using `lastIndex` makes the engine robust if a caller passes an untrimmed pattern that reaches the user's stop twice (a loop route) — the *last* pass is the one the rider boards after the bus has done the loop, and it is the one whose stop sequence precedes the arrival. If either is nil → return `JunctionResult(nil, nil, false)`.
2. `i = iUser, j = jUser`. While `i > 0 && j > 0 && trunk.stops[i-1].code == line.stops[j-1].code`: `i -= 1; j -= 1`.
3. Cases:
   - `j == jUser` (no shared stop before the user's stop): **no junction** → `(nil, nil, false)`. Drawn as an independent rail that converges only at the node (Main artboard, and Merge A's line 7).
   - `j == 0` (walked all the way to the line's terminus): the whole line is on the trunk → `(0, i, lineIsSubsetOfTrunk: true)`. Drawn as: terminus bar/badge placed on the parallel (±18) rail at the trunk's along-coordinate of stop `i`; no own segment; no junction curve; capsules from `i` onwards.
   - `i == 0` and `j > 0` (walked to the **trunk's** terminus while the line still has its own stops before): the trunk's terminus is at the far left and there is no room for the line's own segment to the left of it → treat as **no junction** `(nil, nil, false)`; the line is drawn independently and the shared stops appear as rings on both rails. Documented limitation (§H.2).
   - otherwise: `(lineJunctionIndex: j, trunkJunctionIndex: i, false)`.
4. Comparisons are by `code` only (never by name).

Degenerate inputs handled by `MapLayoutEngine.layout` before/after detection:
- Only one line → trunk only, no junctions.
- Trunk id not in `lines` → the engine uses `lines[0]` as trunk (defensive; `precondition` in DEBUG).
- A line whose `stops` does not contain `userStopCode`, or has fewer than 2 stops → that line is dropped from the scene (logged by the caller; the engine returns a scene without it).
- Duplicate codes inside one pattern (route passes the same street twice): the walk is index-based, so a code appearing earlier in the sequence never short-circuits it; `stopAlong` has one entry per *index*. (`RouteGeometry.project` can still snap a vehicle to the wrong pass; that lives in `Transit/Progress` and is outside this engine — §H.2.)
- Two lines merging at different junctions, or three at one: each non-trunk line is detected independently against the trunk (never against each other). Two non-trunk lines that share stops with each other but not with the trunk are drawn as independent rails with rings (no capsule) — capsules are only computed on the trunk bundle.

### B.3 Compression (`RouteCompressor.swift`)

Per line, independently. Vocabulary: for a line with stops `s[0...n]` (`s[0]` terminus, `s[n]` user's stop):

- **Shared segment** `S` = stop indices `[lineJunctionIndex, n)` — from the junction stop (inclusive) to the user's stop (exclusive). For the trunk, `S_trunk = [minTrunkJunction, n)` where `minTrunkJunction` = the smallest `trunkJunctionIndex` over all joined lines; if nothing joins, `S_trunk = []` (empty). For a line with no junction, `S = []`.
- **Own segment** `O` = stop indices `(0, start(S))` exclusive of the terminus and exclusive of the junction; if `S` is empty, `O = (0, n)`.
- Parameters per preset: `headCount` (1; **2** for `.landscapeSingle`), `tailBudget` (**5** landscape, **4** phone/pad).
- **Minimum dash**: a dash is only drawn when it would swallow **≥ 2** stops. (This subsumes the brief's "≤ 9 stops total → draw them all": with head 1 + tail 5, a 9-stop line would swallow exactly 1 → drawn in full; a 10-stop line swallows 2 → dashed.)

```swift
nonisolated enum DrawnRunKind: Hashable, Sendable { case stop(index: Int); case dash(swallowed: Range<Int>) }

nonisolated struct CompressedLine: Hashable, Sendable {
    var lineID: String
    /// Terminus is index 0 and is always drawn; user's stop is `n` and is the node. This lists indices 1..<n in order,
    /// with swallowed ranges collapsed into `.dash`.
    var runs: [DrawnRunKind]
    var ownTailCount: Int
    var sharedDashed: Range<Int>?          // bundle compression (see rule 3)
}

nonisolated enum RouteCompressor {
    static func compress(line: MapLineInput, shared: Range<Int>, headCount: Int, tailBudget: Int) -> CompressedLine
}
```

Rules, applied in order:

1. **Bundle compression** (shared segment too long). Let `sharedCount = S.count`. If `sharedCount - tailBudget >= 2`: draw the junction stop `S.first`, then a dash swallowing `S[1 ..< (sharedCount - (tailBudget - 1))]`, then the last `tailBudget - 1` shared stops. Record it in `sharedDashed`. The trunk and every joined line that contains those stops get the same swallowed range (they are the same stops), so their dashes align — this is the one place alignment is expected. Only the trunk's `DashRun` has `showLabel = true`. `drawnShared = tailBudget` in this case, else `drawnShared = sharedCount`.
2. **Own tail**: `ownTail = max(1, tailBudget - drawnShared)`. (Merge B: trunk `S` = 6 → rule 1 does not fire because 6 − 5 = 1 < 2 → `drawnShared = 6` → `ownTail = 1` → LOWER QUAY alone before BELL TOWER, exactly as the Merge2 artboard.)
3. **Own segment**: `ownCount = O.count`. If `ownCount - headCount - ownTail >= 2`: runs = first `headCount` of `O`, one `.dash` swallowing the middle, last `ownTail` of `O`. Else: all of `O` as `.stop`.
4. A line with `lineIsSubsetOfTrunk` has `O = []`; its runs are only the shared part.
5. Lines with `n <= 1` (terminus == user's stop) produce `runs = []` — a rail from terminus straight to the node.

### B.4 Metrics (`MapMetrics.swift`)

All numbers are at the reference size and are multiplied by `request.scale` inside `MapMetrics(preset:scale:)`. Sources: Main (flex rows + convergence SVG), Merge1–3 (SVG), SingleLine, PhoneOneLine/TwoLines/Portrait, PadPortrait. Where two artboards disagree the choice is noted.

| Metric | `.landscape` | `.landscapeSingle` | `.phone` | `.pad` |
|---|---|---|---|---|
| reference canvas (map area) | 1280 × 380 | 1280 × 380 | 390 × 470 | 834 × 720 |
| across of rows/columns | trunk at `H/2` (=190); other rows at `H/2 ∓ 120` (70, 310) | trunk at `H/2` | trunk at `W/2` (195); 2 lines: other at `W/2 − 85` (110); 3 lines: `W/2 − 136`, `W/2 − 68` (59, 127) — non-trunks always LEFT | trunk `W/2` (417); others at `W/2 ∓ 250` (167, 667) |
| rail width (trunk / other) | 12 / 12 | 14 | 14 (1 line) · 12 (2–3 lines) | 14 |
| terminus | bar 10 × 40, r5, `along` 40…50 (centre 45) | bar 10 × 60, r5 | badge 30 × 26, r8, font 16, centre along 21 (column top 8 + 13) | badge 44 × 38, r11, font 22, centre along 39 |
| first stop along | 110 | 150 | 72 | 109 |
| stop pitch (drawn) | 100 | 100 | 64 (1 line) · 60 (2–3) | 86 |
| ring radius / stroke | 13 / 6 | 17 / 8 | 12 / 6 (1 line) · 11 / 5 (2–3) | 15 / 7 |
| capsule width / corner / stroke / margin | 20 / 10 / 4 / 18 | 20 / 10 / 4 / 18 | 20 / 10 / 4 / 18 | 20 / 10 / 4 / 18 |
| parallel offset for joined rails | ±18 | — | ±18 | ±18 |
| dash on / off | 20 / 18 | 22 / 20 | 18 / 16 (1 line) · 16 / 14 (2–3) | 20 / 18 |
| dash label font / letter-spacing / offset | 11 pt, 0.12 em, centre at (mid, across + 16) | 13 pt, 0.14 em, (mid, across + 20) | 11–12 pt, 0.10 em, at the label anchor column (across + 32), vertically centred on the dash | 12 pt, 0.10 em, same |
| stop-name font / letter-spacing | 12 pt, 0.03 em | 14 pt, 0.03 em | 12 pt (1 line) · 11 pt, 0.04 em | 12 pt, 0.04 em |
| stop-name anchor | bottom-left at (stop.along, across − 20), rotated −35° (rising right) | same, across − 24 | leading edge at (across + 32, stop.along) horizontal; trailing edge at (across − 32) for a column left of the trunk | leading at (across + 32, stop.along) |
| terminus-name anchor | (terminus centre along = 45, across − 20), −35°, line colour | (45, across − 24) | leading at (across + 31, 21), line colour | leading at (across + 34, 39), line colour |
| node centre | along `N = W − 90` (1190), across `H/2` | same | along `H − 22` (448), across `W/2` | along `H − 44` (676), across `W/2` |
| node radius / stroke | 26 / 12 | 26 / 12 | 17 / 9 | 28 / 12 |
| white stub (from…to, width) | `N − 72 … N − 28`, 16 | same | `node − 40 … node − 20`, 14 | `node − 54 … node − 26`, 18 |
| coloured rails end (all rails) | `N − 70` | `N − 70` | trunk: `node − 38` (410); joined: same | trunk `node − 50` (626) |
| last tail stop along | `N − 280` (910) | `N − 280` | `node − 96` (352) | `node − 147` (529) |
| convergence curve, unjoined line | horizontal to `N − 170`; cubic to `(N − 70, H/2)` with c1 `(N − 124, rowAcross)`, c2 `(N − 116, H/2)` | — | column ends at `node − 60` (388); cubic from `(colAcross, 388)` to `(W/2, 410)` with c1 `(colAcross, 404)`, c2 `(W/2, 392)` | column ends at `node − 96` (580); cubic to `(W/2, 626)` with c1 `(colAcross, 606)`, c2 `(W/2, 590)` |
| convergence curve, joined (±18) rail | parallel to `N − 134`; cubic to `(N − 70, H/2)` with c1 `(N − 100, H/2 ± 18)`, c2 `(N − 94, H/2)` | — | parallel to `node − 60`; cubic to `(W/2, 410)` with c1 `(W/2 ± 18, 404)`, c2 `(W/2, 392)` | parallel to `node − 96`; cubic to `(W/2, 626)` c1 `(W/2 ± 18, 606)`, c2 `(W/2, 590)` |
| junction curve (row → ±18 rail) | from `(J − 80, rowAcross)` to `(J, H/2 ± 18)`, c1 `(J − 40, rowAcross)`, c2 `(J − 40, H/2 ± 18)` where `J` = junction stop along | — | same shape along the vertical axis: from `(colAcross, J − 60)` to `(W/2 ± 18, J)`, c1 `(colAcross, J − 30)`, c2 `(W/2 ± 18, J − 30)` | from `(colAcross, J − 80)`, c1/c2 at `J − 40` |
| puck size / corner / font | 44 × 36 / 10 / 20 | 56 × 40 / 10 / 22 (selected 64 × 48 / 12 / 26) | 46 × 36 / 11 / 20 | 52 × 40 / 12 / 22 |
| puck halo / selected ring | 5 / 5 (selected also scale 1.14) | 6 / 5 | 5 / 5 | 6 / 5 |
| "YOUR STOP" caption | 11 pt, 0.20 em, centred at `(N, H/2 + 46)` (text top) | same | 10 pt, 0.18 em, leading at `(W/2 + 33, node)` vertically centred | 11 pt, 0.20 em, leading at `(W/2 + 53, node)` |
| hint "TAP A BUS TO INSPECT IT" | 11 pt, 0.14 em, at `(40, 348)` top-left | none | none | none |
| minimum dash length | 60 | 60 | 40 | 60 |

Notes on the choices:
- Ring geometry follows the SVG artboards (Merge1–3: `r=13 stroke-width=6`, outer edge 16) and the brief, not the CSS rows of Main (26 px box with a 6 px border = outer 13). SingleLine/phone/pad rings are the CSS boxes converted the same way (CSS box `d` with border `b` → centre radius `d/2 − b/2`, stroke `b`).
- Row pitch 120 (70/190/310) is what every landscape artboard draws; the designer note "110 px row pitch" is stale. Node at `W − 90` follows Main's convergence SVG (node at 1190); Merge1–3 draw it at 1196 and the brief says "~1196" — 6 px, Main wins because its curve geometry is the one reproduced here.
- Terminus bar 10 × 40 follows Merge (SVG) and the brief; Main's CSS uses 8 × 44.
- Stop-name anchor `across − 20` unifies Main's CSS (bottom of the text 4 px above a 13-outer ring) and Merge's SVG (20 px above a 16-outer ring): with the SVG ring outer edge at 16, `−20` leaves 4 px of clear space, matching Main's intent.
- Phone 2-line column spacing is **85** (artboard PhoneTwoLines: columns at 110 and 195), not the brief's 68; 68 is the 3-line spacing (59/127/195). Artboard wins.
- Phone portrait puts every non-trunk column to the LEFT of the trunk so the trunk's names always have the right-hand ~160 pt of the screen (PhoneTwoLines, PhonePortrait). iPad has room for one on each side (PadPortrait).

### B.5 Layout algorithm (`MapLayoutEngine.layout`)

```swift
nonisolated enum MapLayoutEngine {
    static func layout(_ request: MapLayoutRequest) -> MapScene
}
```

Steps, in order:

1. **Validate & order.** Drop lines missing `userStopCode` or with `< 2` stops. Trunk = `lines.first { $0.id == trunkLineID } ?? lines[0]`. `others` = the remaining lines in selection order. Display order / across assignment:
   - `.landscape`: 3 lines → `[others[0]: top, trunk: middle, others[1]: bottom]`. 2 lines → trunk middle; the other goes **top** if it precedes the trunk in selection order, else **bottom**. 1 line → use `.landscapeSingle` metrics if the request says so (the view picks the preset).
   - `.phone`: trunk at `W/2`; `others` to the left in selection order, nearest the trunk first (`others[0]` at `W/2 − 85` for 2 lines; for 3 lines `others[0]` at `W/2 − 68`, `others[1]` at `W/2 − 136`).
   - `.pad`: trunk centre; `others[0]` left, `others[1]` right.
2. **Junctions.** For each other line: `JunctionDetector.junction(of:onto:userStopCode:)`. Parallel side for a joined line = the side of its row/column relative to the trunk (top row → `−18`; bottom row → `+18`; phone: the left column → `−18` i.e. `W/2 − 18`; pad: left → `−18`, right → `+18`). If two joined lines would get the same side (phone 3-line, both are on the left), the one whose junction is **earlier** (smaller trunk index) takes `−18` and the other takes `+18` (the bundle at any across position never has two rails at the same offset).
3. **Compress** each line with `RouteCompressor.compress` (trunk's `shared` = `[minTrunkJunction, n)` or empty).
4. **Along positions for the trunk.** Let `drawnAfterTerminus` = the trunk's `runs`. Walk backwards from the node: `stopAlong[n] = node`, the last drawn stop at `lastTailAlong`, each previous drawn stop at `−pitch`. The head stop(s) are placed from the front at `firstStopAlong + k·pitch`. The dash occupies `[lastHeadAlong + ringOuter + 4, firstTailAlong − ringOuter − 4]`. **Fit rule:** if that dash would be shorter than `minimumDashLength`, reduce `pitch` for the tail stops uniformly: `pitch = (firstTailAlongTarget − lastHeadAlong − minimumDashLength) / tailCount` — i.e. tail stops compress towards the node until the dash fits; if pitch would drop below `0.6·pitch`, additionally shrink the head to 0 head stops (the dash starts right after the terminus). Swallowed stops get virtual along-coordinates evenly spaced inside the dash (`stopAlong[i]` for every `i`, so pucks inside the dash move smoothly). No-dash lines: stops evenly spaced between `firstStopAlong` and `lastTailAlong` (pitch = min(pitch, available / count)).
5. **Along positions for joined lines.** Shared stops take the **trunk's** along for the same code (`stopAlong[line][j] = stopAlong[trunk][i]` walking both indices from the junction). The own segment is laid out exactly like a trunk (step 4) but with the "node" replaced by the junction: the last own drawn stop is at `J − pitch` (one pitch before the junction), and the junction curve occupies `[J − 80, J]` (landscape; `J − 60`/`J − 80` portrait). Own head stops from the front; the dash absorbs the remainder with the same fit rule.
6. **Unjoined lines:** identical to the trunk (step 4) — their last tail stop is at `lastTailAlong` too, so columns of stops line up across rows as in Main.
7. **Rails (`RailNode.segments`).** Per line, in along order:
   - terminus → first drawn thing: `.line`;
   - each `.dash` run: `.dashed(on:off:)` (bundle dashes are emitted on every rail of the bundle at that stretch, colour per rail);
   - own segment end → junction: `.cubic` per §B.4 "junction curve";
   - then `.line` along the ±18 parallel until the convergence start, `.cubic` into `(railsEnd, centre)`;
   - unjoined: `.line` to convergence start then the unjoined `.cubic`;
   - trunk: `.line`/`.dashed` all the way to `railsEnd`.
   Stroke widths from the metrics; `dimmed = (highlightedLineID != nil && lineID != highlightedLineID)`.
8. **Stop marks.** For each trunk stop index `i` in the drawn runs: if any joined line whose parallel rail is active at that along shares the stop (`i >= trunkJunctionIndex` for that line) → one `.capsule` spanning across from `minRailAcross − 18` to `maxRailAcross + 18` where the rail set = trunk + every joined line active at `i`: `capsuleRect = (along − 10, minAcross − 18, 20, extent + 36)` in (along, across) terms, `cornerRadius 10`, `strokeWidth 4`. Otherwise a `.ring`. Joined lines emit rings only for their own segment; unjoined lines emit rings for every drawn stop. Rings of a bundle stop are never emitted (the capsule replaces them). The user's stop is the node (never a mark).
9. **Labels.** For each drawn stop of a line in `namedLineIDs` (or all): a `StopLabel` with the anchor/rotation from §B.4. Roles: terminus → `.terminus(colorIndex)`; a capsule stop that is some line's junction → `.junction`; else `.stop`. A capsule stop is labelled **once** (from the trunk's row). Distance spines (`namedLineIDs` excludes the line) get no labels at all, including the terminus name.
10. **Dash labels**: `labelCenter` per §B.4; `showLabel = true` except for non-trunk rails of a bundle dash.
11. **Pucks.** For each vehicle whose `lineID` is in the scene: `along = stopAlong[i] + progressToNext · (stopAlong[i+1] − stopAlong[i])` with `i = clamp(lastStopIndex, 0, n−1)`; `across = RailPath(line).across(atAlong: along)`. Size/corner/font from metrics; `isSelected` copies the input; `dimmed` as rails. Sort: unselected first, selected last.
12. **Convergence**: `ConvergenceMark` from §B.4. `hintAnchor` = `(40, 348)·scale` for `.landscape` only.
13. Convert every (along, across) pair to `CGPoint` for `request.axis`; fill `stopAlong` (still in along units). Return.

Visual invariants the tests check (§B.8): rails never cross except at a junction curve; the trunk is one straight line at exactly `H/2` (or `W/2`) from terminus to `railsEnd`; every stop of the trunk after the earliest junction is a capsule when a joined rail is active there; termini of all lines share the same along-coordinate.

### B.6 Rail assignment summary

- Trunk: centre, straight, never bends, drawn last (on top of the other rails, under the white stub).
- Joined lines: their own row/column until the junction curve, then parallel at ±18 keeping their colour. Never blend/stripe.
- Unjoined lines: own row/column, one convergence curve into the stub.
- Two joined lines: one above (−18) and one below (+18) — Merge B/C. Three-rail bundle capsule height = 36 + 36 = 72 (Merge2 `y=154 h=72`), two-rail = 18 + 36 = 54 (`h=54`). Both match the artboards exactly.

### B.7 Trunk change rule (`TrunkSelector.swift`)

```swift
nonisolated struct TrunkSelector: Hashable, Sendable {
    static let minimumInterval: TimeInterval = 30
    var currentTrunkID: String?
    var lastChangeAt: Date?
    /// Manual promotion (portrait 3-line tap). Wins over the automatic candidate until cleared.
    var manualTrunkID: String?

    /// `candidateID` = line of the soonest arrival (nil when nothing is arriving). Returns the trunk to draw and updates state.
    mutating func select(candidateID: String?, now: Date) -> String?
}
```

Rules: if `currentTrunkID == nil` → adopt `manualTrunkID ?? candidateID` immediately and set `lastChangeAt = now`. Otherwise the desired trunk is `manualTrunkID ?? candidateID ?? currentTrunkID`; if it differs from `currentTrunkID` and `now − lastChangeAt ≥ 30 s` → switch and set `lastChangeAt = now`; else keep the current one. A manual promotion is applied through the same gate (a tap right after an automatic change still waits — the 30 s rule is about layout thrash, not intent; the tap is remembered in `manualTrunkID` and applied at the next `select`). The view animates any change of `MapScene.trunkLineID` over **0.4 s** (§E.3 crossfade); puck positions animate independently over 0.6 s.

### B.8 Unit tests (write BEFORE the engine — TDD)

Fixtures live in `BusBus/MapEngine/MapFixtures.swift` (app target, so the mock provider reuses them):

```swift
nonisolated enum MapFixtures {
    static func stop(_ name: String) -> MapStopInput { .init(code: name.uppercased().replacingOccurrences(of: " ", with: "-"), name: name.uppercased()) }
    static func filler(_ prefix: String, _ n: Int) -> [MapStopInput] { (1...n).map { stop("\(prefix) \($0)") } }
    static let user = "HARBOR GATE"

    // Main (no merges): 41 = 12 stops, 18 = 14 stops, 7 = 17 stops
    static let line41Main = MapLineInput(id: "41", number: "41", colorIndex: 1, stops:
        [stop("VISTA PARK"), stop("AIRPORT LOOP")] + filler("V", 4) + [stop("LOWER QUAY"), stop("BELL TOWER"), stop("CANAL ST"), stop("FISH MARKET"), stop("DOCK GATE"), stop(user)])
    static let line18Main = MapLineInput(id: "18", number: "18", colorIndex: 0, stops:
        [stop("NORTHGATE"), stop("FOUNDRY RD")] + filler("N", 6) + [stop("CIVIC CTR"), stop("WEST MARKET"), stop("OAK & 5TH"), stop("PIER FOUR"), stop("GRANITE ROW"), stop(user)])
    static let line7Main = MapLineInput(id: "7", number: "7", colorIndex: 2, stops:
        [stop("HILLCREST"), stop("QUARRY RD")] + filler("H", 9) + [stop("OLD MILL"), stop("COLLEGE RD"), stop("RIVER BEND"), stop("SOUTH PIER"), stop("CUSTOM HOUSE"), stop(user)])

    // Merge A — 18 joins 41 at MILL JUNCTION and shares 4 stops; 7 independent
    static let line41A = MapLineInput(id: "41", number: "41", colorIndex: 1, stops:
        [stop("VISTA PARK"), stop("AIRPORT LOOP")] + filler("V", 5) + [stop("LOWER QUAY"), stop("BELL TOWER"), stop("MILL JUNCTION"), stop("CANAL ST"), stop("FISH MARKET"), stop("DOCK GATE"), stop(user)])
    static let line18A = MapLineInput(id: "18", number: "18", colorIndex: 0, stops:
        [stop("NORTHGATE"), stop("FOUNDRY RD")] + filler("N", 7) + [stop("CIVIC CTR"), stop("WEST MARKET"), stop("MILL JUNCTION"), stop("CANAL ST"), stop("FISH MARKET"), stop("DOCK GATE"), stop(user)])
    static let line7A = line7Main

    // Merge B — 18 joins at BELL TOWER, 7 joins later at PIER FOUR
    static let line41B = MapLineInput(id: "41", number: "41", colorIndex: 1, stops:
        [stop("VISTA PARK"), stop("AIRPORT LOOP")] + filler("V", 4) + [stop("LOWER QUAY"), stop("BELL TOWER"), stop("CANAL ST"), stop("FISH MARKET"), stop("PIER FOUR"), stop("GRANITE ROW"), stop("DOCK GATE"), stop(user)])
    static let line18B = MapLineInput(id: "18", number: "18", colorIndex: 0, stops:
        [stop("NORTHGATE"), stop("FOUNDRY RD")] + filler("N", 6) + [stop("CIVIC CTR"), stop("BELL TOWER"), stop("CANAL ST"), stop("FISH MARKET"), stop("PIER FOUR"), stop("GRANITE ROW"), stop("DOCK GATE"), stop(user)])
    static let line7B = MapLineInput(id: "7", number: "7", colorIndex: 2, stops:
        [stop("HILLCREST"), stop("QUARRY RD")] + filler("H", 8) + [stop("OLD MILL"), stop("COLLEGE RD"), stop("PIER FOUR"), stop("GRANITE ROW"), stop("DOCK GATE"), stop(user)])

    // Merge C — all three share from WEST MARKET
    static let line41C = MapLineInput(id: "41", number: "41", colorIndex: 1, stops:
        [stop("VISTA PARK"), stop("AIRPORT LOOP")] + filler("V", 6) + [stop("LOWER QUAY"), stop("WEST MARKET"), stop("CANAL ST"), stop("PIER FOUR"), stop("DOCK GATE"), stop(user)])
    static let line18C = MapLineInput(id: "18", number: "18", colorIndex: 0, stops:
        [stop("NORTHGATE"), stop("FOUNDRY RD")] + filler("N", 5) + [stop("CIVIC CTR"), stop("WEST MARKET"), stop("CANAL ST"), stop("PIER FOUR"), stop("DOCK GATE"), stop(user)])
    static let line7C = MapLineInput(id: "7", number: "7", colorIndex: 2, stops:
        [stop("HILLCREST"), stop("QUARRY RD")] + filler("H", 8) + [stop("OLD MILL"), stop("WEST MARKET"), stop("CANAL ST"), stop("PIER FOUR"), stop("DOCK GATE"), stop(user)])

    static func request(_ lines: [MapLineInput], trunk: String = "41", axis: MapAxis = .horizontal, preset: MapSizePreset = .landscape,
                        canvas: CGSize = CGSize(width: 1280, height: 380), scale: CGFloat = 1, vehicles: [MapVehicleInput] = [],
                        named: Set<String>? = nil) -> MapLayoutRequest
}
```

Test files and cases (Swift Testing; each `@Test` name is the function name; assertions are the `#expect`s). Tolerance for point comparisons: `±0.5`.

`JunctionDetectorTests.swift`
- `mergeA_18JoinsAtMillJunction`: junction(18A onto 41A) → `lineJunctionIndex == 11`, `trunkJunctionIndex == 9`, `lineIsSubsetOfTrunk == false`.
- `mergeA_7HasNoJunction`: junction(7A onto 41A) → `lineJunctionIndex == nil`.
- `mergeB_twoDifferentJunctions`: 18B → junction stop code `"BELL-TOWER"` (trunk index 7); 7B → `"PIER-FOUR"` (trunk index 10).
- `mergeC_allJoinAtWestMarket`: 18C and 7C both → trunk index 9 (`"WEST-MARKET"`).
- `noMerge_mainLinesShareOnlyTheUserStop`: 18Main onto 41Main → nil; 7Main → nil.
- `mergeAtUserStopOnly_isNoJunction`: a line whose last two stops are `[X, HARBOR GATE]` where X ≠ trunk's DOCK GATE → nil.
- `lineEntirelyOnTrunk_isSubset`: line = `Array(line41A.stops.suffix(5))` → `lineIsSubsetOfTrunk == true`, `lineJunctionIndex == 0`, `trunkJunctionIndex == 9`.
- `trunkTerminusInsideLine_isTreatedAsIndependent`: line = `[stop("FAR"), stop("FARTHER")] + line41A.stops` → nil (documented degenerate).
- `duplicateCodesOnLine_walkIsIndexBased`: line 18A with `stop("CANAL ST")` also inserted at index 3 → still junction at `"MILL-JUNCTION"` (index 12 after the insertion) and trunk index 9.
- `missingUserStop_returnsNoJunction`: line without HARBOR GATE → all nil.

`RouteCompressorTests.swift`
- `main41_headOneDashFourTailFive`: compress(41Main, shared: empty, head 1, tail 5) → runs == `[.stop(1), .dash(2..<6), .stop(6), .stop(7), .stop(8), .stop(9), .stop(10)]`, swallowed 4.
- `main18_dashSix` → swallowed 6; `main7_dashNine` → swallowed 9 (matches the "+6 STOPS"/"+9 STOPS" captions in Main).
- `pad41_tailFour_dashFive`: head 1, tail 4 → swallowed 5 (PadPortrait "+5 STOPS"); `pad18` → 7; `pad7` → 10.
- `nineStopLine_drawnInFull`: 9-stop line → no `.dash`. `tenStopLine_getsDash` → one `.dash` swallowing 2.
- `single_headTwo`: `.landscapeSingle` (head 2, tail 5) on 41Main → runs start `[.stop(1), .stop(2), .dash(3..<6), …]`, swallowed 3.
- `mergeA_trunkOwnTailIsOne`: 41A with shared `9..<13` (4 stops) → `ownTailCount == 1`; runs end `[.dash, .stop(8), .stop(9), .stop(10), .stop(11), .stop(12)]` (BELL TOWER, then the 4 shared).
- `mergeB_trunkSharedSixNotBundleDashed`: 41B shared `7..<13` (6) → `sharedDashed == nil`, `ownTailCount == 1`.
- `bundleOfNine_isCompressed`: a trunk with a 9-stop shared segment, tail 5 → `sharedDashed == 1..<5` relative (i.e. junction, dash swallowing 4, last 4 shared), `ownTailCount == 1`.
- `subsetLine_hasNoOwnRuns`: `lineIsSubsetOfTrunk` line → runs contain no `.dash` and only shared indices.
- `twoStopLine_noRuns`: `[terminus, user]` → `runs == []`.

`MapLayoutEngineTests.swift` (landscape, canvas 1280×380, scale 1 unless stated)
- `trunkIsStraightAtCentre`: every trunk segment has `from.y == to.y == 190` and no `.cubic`.
- `terminiAlignAtLeft`: all `termini[].rect.midX == 45`.
- `rowsAt70_190_310`: for `[18Main, 41Main, 7Main]` trunk 41 → rails of 18 at y 70, 7 at y 310 (first segment).
- `twoLines_otherRowFollowsSelectionOrder`: `[41Main, 7Main]` → 7 at 310; `[7Main, 41Main]` → 7 at 70.
- `noMerge_lastTailStopAt910_pitch100`: trunk drawn stops along == `[110, 510, 610, 710, 810, 910]` and `stopAlong["41"][11] == 1190`.
- `noMerge_dashSpansBetweenHeadAndTail`: 41's `DashRun.from.x == 110 + 16 + 4`, `to.x == 510 − 20`, `swallowedCount == 4`, `labelCenter == ((from.x+to.x)/2, 206)`.
- `noMerge_swallowedStopsGetVirtualAlong`: `stopAlong["41"][2..<6]` strictly increasing, all inside the dash range.
- `noMerge_noCapsules`: `stops.allSatisfy { if case .ring = $0.kind { true } else { false } }`.
- `convergence_unjoinedCurvesMatchMain`: 18's last two segments == `.line((1020,70)→…)` then `.cubic(from (1020,70), c1 (1066,70), c2 (1074,190), to (1120,190))`; stub `(1118,190)→(1162,190)` width 16; node `(1190,190)` r 26 stroke 12; caption anchor `(1190, 236)`.
- `mergeA_capsulesSpanTrunkAndUpperRail`: scene for `[18A, 41A, 7A]` → capsules at codes MILL-JUNCTION, CANAL-ST, FISH-MARKET, DOCK-GATE with `capsuleRect.minY == 154`, `height == 54`, `width == 20`, `lineIDs == ["41","18"]`.
- `mergeA_18RunsParallelAbove`: after its junction, 18's straight segment has `y == 172`; its junction cubic ends at `(stopAlong["41"][9], 172)` and starts 80 pt before.
- `mergeA_18OwnSegmentEndsOnePitchBeforeJunction`: 18's last own drawn stop (WEST MARKET) along == `stopAlong["41"][9] − 100`.
- `mergeA_7IsIndependent`: 7's rail has exactly one `.cubic` (the convergence curve) and only rings.
- `mergeA_junctionLabelIsPrimary`: label for MILL-JUNCTION has `role == .junction`; CANAL-ST has `.stop`; labelled once each.
- `mergeA_joinedRailConvergesFromParallel`: 18's final cubic == `from (1056,172), c1 (1090,172), c2 (1096,190), to (1120,190)`.
- `mergeB_threeRailBundleAfterPierFour`: `[18B, 41B, 7B]` → capsules at BELL-TOWER, CANAL-ST, FISH-MARKET have height 54 (`minY 154`); PIER-FOUR, GRANITE-ROW, DOCK-GATE have height **72** (`minY 154, maxY 226`); 7's parallel is at `y == 208`.
- `mergeB_junctionsAtDifferentAlong`: `stopAlong["41"][7] < stopAlong["41"][10]`; 18's junction cubic ends at the former, 7's at the latter.
- `mergeC_allThreeMeetAtWestMarket`: `[18C, 41C, 7C]` → four capsules (WEST-MARKET, CANAL-ST, PIER-FOUR, DOCK-GATE) all height 72; both joined lines' junction cubics end at `stopAlong["41"][9]`, 18 at 172, 7 at 208.
- `mergeC_ownTailsAreOne`: 18C and 41C and 7C each have exactly one drawn own stop between their dash and the junction.
- `phone3Lines_columnsAt59_127_195_trunkRight`: axis vertical, preset phone, canvas 390×470 → 7 at x 59, 18 at x 127, 41 at x 195; trunk segments all `x == 195`.
- `phone2Lines_otherColumnAt110`: `[18Main, 41Main]` → 18 at x 110.
- `phone_distanceSpines_haveNoLabels`: `named: ["41"]` → no label with a lineID other than 41 (labels carry the line id in `id` prefix); their termini are `.badge`.
- `phone_convergenceMatchesArtboard`: 18 (2-line) final cubic == `from (110,388), c1 (110,404), c2 (195,392), to (195,410)`; stub `(195,408)→(195,428)`; node `(195,448)` r 17 stroke 9; caption anchor `(228,448)`.
- `phone_labelsHorizontalOutside`: trunk labels `rotationDegrees == 0`, `alignment == .leading`, `anchor.x == 227`; left column labels `.trailing`, `anchor.x == 78` (110 − 32).
- `pad_columnsAt167_417_667`: `[18Main, 41Main, 7Main]` pad 834×720 → 18 at 167, 41 at 417, 7 at 667; stops pitch 86; last tail at 529; node (417, 676) r 28.
- `scale_appliesUniformly`: same request at `scale 0.5`, canvas 640×190 → every point halves (compare against the scale-1 scene point-by-point), fonts and widths halve.
- `wideCanvas_extraWidthGoesToDash`: canvas 1600×380, scale 1 → node at 1510, tail stops shift right by 320, head stop still at 110, dash longer by 320.
- `longSharedBundle_getsCompressedOnAllRails`: trunk with 9 shared stops (custom fixture) → both rails have a `.dashed` segment covering the same along range; only the trunk's `DashRun.showLabel == true`.
- `tooManyTailStops_shrinkPitchNotBelowMinDash`: a trunk with `S` of 6 and own tail 1 plus head 1 in a 1280 canvas fits (dash ≥ 60); the same at canvas 900 wide → dash length ≥ 60 and tail pitch < 100.
- `pucks_sitOnRailBetweenStops`: vehicle on 41Main `lastStopIndex 9, progress 0.5` → puck centre `(860, 190)`; vehicle on 18Main `lastStopIndex 2, progress 0` → x == `stopAlong["18"][2]`, y == 70 (inside the dash).
- `puck_onJunctionCurveFollowsCubic`: 18A vehicle placed at the along midpoint of the junction curve → `y` strictly between 70 and 172.
- `selectedPuck_isDrawnLast`: `pucks.last?.isSelected == true` when one vehicle is selected.
- `highlightedLine_dimsTheOthers`: `highlightedLineID: "7"` → rails/stops/labels/pucks of 41 and 18 have `dimmed == true`, 7's false.
- `singleLine_usesLargeMetrics`: `.landscapeSingle` → rail width 14, ring radius 17 stroke 8, terminus rect 10×60, head 2.
- `dropsLineWithoutUserStop`: a line lacking HARBOR GATE is absent from `rails`.
- `hintAnchor_onlyInLandscape`: landscape → `(40, 348)`; phone → nil.

`RailPathTests.swift`
- `straightRail_acrossConstant`, `dashedSegment_isLinear`, `cubic_endpointsExact` (across at `from.along` == from.across, at `to.along` == to.across), `cubic_midpointWithinTolerance` (Main curve: at along 1070 across is within 2 pt of the true bezier at the parameter whose x is 1070 — compute the reference by bisection in the test).

`TrunkSelectorTests.swift`
- `firstCandidateAdoptedImmediately`, `changeWithin30sIsIgnored`, `changeAfter30sApplied`, `nilCandidateKeepsCurrent`, `manualPromotionWinsOverCandidate`, `manualPromotionRespectsInterval`.

---

## C. Design tokens (`BusBus/Design/`)

### C.1 Colours — dark theme (default)

Every value below appears in an artboard; the token names are what the Swift code uses.

| Token | Value | Artboard use |
|---|---|---|
| `background` | `#08080B` | page, map, dot/ring fills, puck halo, numerals on colour, node fill, capsule fill |
| `readoutBand` | `#0B0B0F` | readout background (landscape, phone, pad); badge halo inside the readout |
| `card` | `#15151B` | THEN card, nearby/recent rows, search field, back button, iPad THEN bar |
| `outlinedCard` | `#101018` | tapped-bus card fill |
| `chipUnselected` | `#101016` | unselected line chip fill |
| `searchBorder` | `#24242E` | search field 2 pt border |
| `clearButtonBorder` | `#2A2A34` | CLEAR button 2 pt border |
| `closeButton` | `#1E1E26` | 34 pt round X button |
| `primaryText` | `#FFFFFF` | titles, minutes, clock, junction stop names, "YOUR STOP", trunk stub, node ring, capsule stroke, selected ring, primary button fill |
| `secondaryText` | `#A0A0AE` | kickers, LIVE, arrives/destination lines, THEN, MIN (secondary), CLEAR text, stop names in SingleLine |
| `stopName` | `#8C8C9A` | stop names, header caption, step captions, section headers, "+N" overflow, chip destinations |
| `dashCaption` | `#5E5E6C` | "+N STOPS", nearby count caption, search placeholder |
| `hint` | `#4A4A56` | "TAP A BUS TO INSPECT IT", the 5 pt separator dots in the readout |
| `liveDot` | `#3DDC84` | LIVE dot (also palette index 3) |
| `numeralOnColor` | `#08080B` | every number drawn on a line-coloured badge/puck/chip |
| `primaryButtonFill` / `primaryButtonText` | `#FFFFFF` / `#08080B` | SHOW THE MAP |
| `late` | `#FF3B3F` | "RUNNING 2 MIN LATE" |
| `stale` | `#5E5E6C` | LIVE dot when stale (judgement: reuse `dashCaption`) |

### C.2 Colours — light theme (MainLight)

One continuous cream ground; no white panels; stop dots filled with the ground; every numeral is ink.

| Token | Value | Note |
|---|---|---|
| `background` | `#F4F2EC` | page, map, readout (no band), dot/capsule/node fills, puck halo |
| `readoutBand` | `#F4F2EC` | same as background (the band disappears) |
| `card` | `#F4F2EC` + 2 pt outline `#DBD7CD` | THEN card is an outline, not a fill |
| `cardOutline` | `#DBD7CD` | |
| `outlinedCard` | `#F4F2EC` | tapped card fill (border stays line colour) |
| `chipUnselected` | `#F4F2EC` | judgement (no light picker artboard) |
| `searchBorder` / `clearButtonBorder` | `#DBD7CD` | judgement |
| `closeButton` | `#E6E2D8` | judgement |
| `primaryText` | `#14140F` | titles, minutes, clock, trunk stub, node ring, capsule stroke, selected ring, numerals |
| `secondaryText` | `#55555F` | kickers, LIVE, arrives/destination, THEN, **and the "MIN" unit** (light mode never uses the line colour for text) |
| `stopName` | `#55555F` | stop names |
| `headerCaption` | `#6B6862` | "STOP 4412 · BAY B" (dark mode uses `stopName`) |
| `dashCaption` | `#8A8790` | "+N STOPS" |
| `hint` | `#B6B2A8` | separator dots (`#B6B2A8` in MainLight); hint text uses `dashCaption` |
| `liveDot` | `#1A7F4B` | |
| `numeralOnColor` | `#14140F` | |
| `primaryButtonFill` / `primaryButtonText` | `#14140F` / `#F4F2EC` | judgement (inverse of dark) |
| `late` | `#D32029` | palette light red |
| `stale` | `#8A8790` | |

### C.3 Line palette (`LinePalette.swift`)

Dark rails/badges (index 0–11, exactly the brief's order, which is also the order of the 12 chips in LinePicker):

```
0 #FF3B3F   1 #FFC300   2 #22D3EE   3 #3DDC84   4 #A78BFA   5 #FF7A1A
6 #4D8CFF   7 #FF5CA8   8 #7BE0C2   9 #E8D44D  10 #C3F53C  11 #FFA9A9
```

Light rails (used for rails, badges, pucks, chip borders/fills in light mode). Indices 0/1/2 are from MainLight; the other nine are **judgement values** darkened to hold ≥ 3:1 against `#F4F2EC` (verify with a contrast check when implementing; adjust lightness only):

```
0 #D32029   1 #EFA400   2 #0E7C86   3 #1A7F4B   4 #6D4FD6   5 #C2520A
6 #2461D9   7 #C8207A   8 #1E8A6E   9 #9A8A00  10 #5E8A00  11 #C04A4A
```

Light **text** variants (MainLight sets terminus names in a darker ink of the line colour: red `#B01A22`, amber `#8A6000`, teal `#0B636B`). Used only for terminus labels and the "TAPPED BUS" kicker in light mode. Indices 3–11 are judgement values (≥ 4.5:1 on cream):

```
0 #B01A22   1 #8A6000   2 #0B636B   3 #12603A   4 #4E37A6   5 #8F3C05
6 #1A47A8   7 #961558   8 #146650   9 #6F6400  10 #446600  11 #8F3434
```

```swift
nonisolated struct LinePalette: Sendable {
    static let darkRail: [Color]   // 12
    static let lightRail: [Color]  // 12
    static let lightText: [Color]  // 12
    static func rail(_ index: Int, scheme: ColorScheme) -> Color
    static func labelText(_ index: Int, scheme: ColorScheme) -> Color   // dark: rail colour; light: lightText
}

/// Stable assignment by line id.
nonisolated enum LineColorAssigner {
    /// FNV-1a 64 over the UTF-8 of `lineID`, mod 12.
    static func hashedIndex(for lineID: String) -> Int
    /// Given the persisted assignments and the currently selected line ids (in selection order),
    /// returns assignments where every selected line has a DISTINCT index: keep persisted indices; for a new line use
    /// hashedIndex unless taken by another selected line, then the next free index (mod 12).
    static func resolve(persisted: [String: Int], selected: [String]) -> [String: Int]
}
```

`SettingsStore.paletteAssignments: [String: Int]` persists the result forever, so a line keeps its colour across sessions. Unselected lines in the picker/nearby badges use `persisted[id] ?? hashedIndex(id)`; the moment a line is selected its index is fixed by `resolve` and persisted (so what the user saw in the grid is what appears on the map unless a collision forced a shift — collisions only shift lines that were not yet persisted).

Unit tests (`LinePaletteTests.swift`): `hashIsStable` (same id → same index in two calls), `hashInRange`, `resolveKeepsPersisted`, `resolveAvoidsCollisionAmongSelected` (three ids that hash to the same index get three different indices), `resolveNeverChangesAnAlreadyPersistedSelectedLine`.

### C.4 Typography and font registration (`Typography.swift`, `FontRegistrar.swift`)

The six static OFL files are staged in `BusBus/Resources/Fonts/`. **Verified name tables** (from the files themselves):

| File | Family | Style | PostScript name |
|---|---|---|---|
| `Archivo-Medium.ttf` | Archivo Medium | Regular | `Archivo-Medium` |
| `Archivo-Bold.ttf` | Archivo | Bold | `Archivo-Bold` |
| `Archivo-ExtraBold.ttf` | Archivo ExtraBold | Regular | `Archivo-ExtraBold` |
| `Archivo-Black.ttf` | Archivo Black | Regular | `Archivo-Black` |
| `SpaceMono-Regular.ttf` | Space Mono | Regular | `SpaceMono-Regular` |
| `SpaceMono-Bold.ttf` | Space Mono | Bold | `SpaceMono-Bold` |

**The trap:** Medium, ExtraBold and Black register as their **own families**, not as weights of "Archivo". `Font.custom("Archivo", size:).weight(.black)` therefore silently resolves to Bold-or-system and the design loses its display face. **Every face is addressed by its exact PostScript name; nothing in the codebase calls `Font.custom` with a family name or uses `.weight()` on a custom font.** The only place a font-name string exists is the `BusFace` enum.

```swift
import SwiftUI
import CoreText

nonisolated enum BusFace: String, CaseIterable, Sendable {
    case archivoMedium    = "Archivo-Medium"      // 500 — reserved; no artboard uses it
    case archivoBold      = "Archivo-Bold"        // 700
    case archivoExtraBold = "Archivo-ExtraBold"   // 800
    case archivoBlack     = "Archivo-Black"       // 900 — the minutes numeral, titles, numerals on badges
    case spaceMonoRegular = "SpaceMono-Regular"   // 400 — reserved
    case spaceMonoBold    = "SpaceMono-Bold"      // 700 — codes, times, stop names, captions
    var fileName: String { rawValue + ".ttf" }
}

nonisolated struct TypeStyle: Hashable, Sendable {
    var face: BusFace
    var size: CGFloat
    /// Tracking in em (CSS letter-spacing). Converted to points as `size * trackingEm` at use time (after scaling).
    var trackingEm: CGFloat = 0
    /// CSS line-height multiple where the artboard sets one (numerals); nil = natural.
    var lineHeightMultiple: CGFloat? = nil
    var uppercase: Bool = true
    var relativeTo: Font.TextStyle? = nil   // set only for hand-mode Dynamic Type participation
}

extension Font {
    /// The ONLY constructor for app fonts. Never call Font.custom elsewhere.
    static func bus(_ face: BusFace, size: CGFloat, relativeTo: Font.TextStyle? = nil) -> Font {
        if let relativeTo { return .custom(face.rawValue, size: size, relativeTo: relativeTo) }
        return .custom(face.rawValue, fixedSize: size)
    }
}

extension View {
    /// Applies font, tracking (points), uppercase and line height for a TypeStyle at a given scale.
    func busText(_ style: TypeStyle, scale: CGFloat = 1) -> some View
}
```

`FontRegistrar`:

```swift
@MainActor enum FontRegistrar {
    /// Registers every BusFace file from Bundle.main (subdirectory "Fonts", falling back to the bundle root — the synchronized
    /// group may flatten the folder) with CTFontManagerRegisterFontsForURL(url, .process, &error). Idempotent: a second call
    /// (previews, tests) ignores kCTFontManagerErrorAlreadyRegistered.
    static func registerBundledFonts()
    /// For each face: CTFontCreateWithName(face.rawValue, 12, nil) and read CTFontCopyPostScriptName; returns the faces whose
    /// PostScript name does NOT round-trip (i.e. CoreText substituted something).
    static func unresolvedFaces() -> [BusFace]
}
```

Behaviour: `BusBusApp.init` calls `registerBundledFonts()`; then `unresolvedFaces()`. If non-empty: `os_log(.fault)` listing them and, in DEBUG builds, `BoardView` shows a 24 pt red banner "MISSING FACES: Archivo-Black, …" at the top. There is no silent fallback: production builds also show a one-line banner (it is a wall display; a wrong face must be noticed). Test `FontRegistrationTests.allSixFacesResolve` calls both and `#expect(FontRegistrar.unresolvedFaces().isEmpty)`; `FontRegistrationTests.fontFilesAreInBundle` asserts `Bundle.main.url(forResource: face.rawValue, withExtension: "ttf", subdirectory: "Fonts") ?? Bundle.main.url(forResource: face.rawValue, withExtension: "ttf")` is non-nil for all six (this is the explicit check that the synchronized group copied the `.ttf` files as resources — Task 3).

### C.5 Type styles (reference sizes; multiplied by the layout scale)

`TypeStyles` is a `nonisolated enum` of static `TypeStyle` constants. Values from the artboards:

| Name | Face | Size | Tracking | Other | Where |
|---|---|---|---|---|---|
| `titleLandscape` | Black | 34 | −0.5 pt (−0.015 em) | | Main header |
| `titlePad` / `titlePhone` | Black | 30 / 22 | −0.4 / −0.3 pt | | Pad/Phone header |
| `setupTitle` / `setupTitlePhone` | Black | 40 / 30 | −0.8 / −0.5 pt | | CHOOSE YOUR STOP |
| `setupTitleLinePhone` | Black | 26 | −0.4 pt | | LinePickerPhone |
| `headerCaption` | Mono Bold | 13 (pad 12) | 0.14 em | colour `stopName`/`headerCaption` | STOP 4412 · BAY B |
| `liveLabel` | Mono Bold | 12 (pad 11) | 0.22 em | | LIVE |
| `clock` | Mono Bold | 26 / 22 / 15 | 0 | | landscape / pad / phone |
| `stopName` | Mono Bold | 12 | 0.03 em | | landscape names |
| `stopNameSingle` | Mono Bold | 14 | 0.03 em | | SingleLine |
| `stopNamePortrait` | Mono Bold | 12 (1 line, pad) / 11 (2–3) | 0.04 em | | phone/pad names |
| `dashCaption` | Mono Bold | 11 (single 13, portrait 11/12) | 0.12 em (single 0.14, portrait 0.10) | | +N STOPS |
| `yourStop` | Mono Bold | 11 (phone 10) | 0.20 em (phone 0.18) | | |
| `hint` | Mono Bold | 11 | 0.14 em | colour `hint` | TAP A BUS… |
| `kicker` | Mono Bold | 13 (phone/BusDetail 12) | 0.20 em | | NEXT ARRIVAL / SELECTED BUS |
| `minutesPrimary` | Black | 124 (pad 140, phone 92, beside 92) | −5 pt (−6 / −4 / −4) | line-height 0.84 (0.80 / 0.82 / 0.84) | big number |
| `unitPrimary` | Black | 34 (pad 36, phone 24, beside 28) | 0.02 em | colour: line (dark) / `secondaryText` (light) | MIN |
| `subStopsAway` | ExtraBold | 17 | 0.02 em | | 1 STOP AWAY |
| `subArrives` | Mono Bold | 17 (pad 16) | 0 | `secondaryText` | ARRIVES 14:33 |
| `subDestination` | Mono Bold | 15 | 0.10 em (pad 0.08) | | TO VISTA PARK |
| `subPhone` | Mono Bold | 13 (beside 14) | 0.04 em | | 1 STOP AWAY · ARRIVES 14:33 |
| `thenLabel` | Mono Bold | 12 | 0.22 em | | THEN |
| `minutesSecondary` | Black | 56 (pad 52, phone 40) | −2 pt (−2 / −1.5) | line-height 0.9 | |
| `unitSecondary` | Black | 20 (phone 16) | 0 | `secondaryText` | |
| `thenSub` | Mono Bold | 14 (phone 12) | 0.06 em | | 3 STOPS · 14:37 · TO NORTHGATE |
| `tappedKicker` | Mono Bold | 12 | 0.22 em | line colour | TAPPED BUS |
| `tappedMinutes` | Black | 62 | −2 pt | line-height 0.86 | |
| `tappedUnit` | Black | 22 | 0 | line colour | |
| `tappedStops` | ExtraBold | 20 | 0 | | 6 STOPS AWAY |
| `tappedDetail` | Mono Bold | 13 | 0.06 em | | LEFT OLD MILL 1 MIN AGO / RUNNING 2 MIN LATE |
| `badgeNumeral` | Black | per badge: 104→58, 84→46, 76→40, 60→30, 56→30, 48→24, 44→24 (header) / 22 (pad terminus), 40→22, 38→18, 30→16 (phone terminus) / 15 (phone nearby) | −0 | `numeralOnColor` | |
| `puckNumeral` | Black | 20 (single 22/26, pad 22) | 0 | `numeralOnColor` | |
| `stepCaption` | Mono Bold | 13 (phone 11) | 0.22 em | | STEP 1 OF 2 |
| `searchInput` | Bold | 22 (phone 18) | 0 | | |
| `sectionHeader` | Mono Bold | 12 (phone 11) | 0.22 em | | NEARBY / RECENT |
| `countCaption` | Mono Bold | 12 (phone 11) | 0.10 em | `dashCaption` | 12 STOPS WITHIN 500 M |
| `distanceChip` | Mono Bold | 15 (phone 13) | 0 | palette index 1 (`#FFC300`) | 80 M |
| `nearbyName` | Black | 28 (phone 20) | −0.3 / −0.2 pt | | |
| `overflowCount` | Mono Bold | 14 (phone 12) | 0 | `stopName` | +5 |
| `recentName` | ExtraBold | 24 (phone chip 15) | 0 | | |
| `pickerSubtitle` | Mono Bold | 13 (phone 10) | 0.18 em (phone 0.16) | | PICK UP TO 3 LINES TO WATCH |
| `chipNumber` | Black | 54 (phone 34) | −1.5 / −1 pt | line-height 1 | |
| `chipDestination` | Mono Bold | 12 (phone 9) | 0.08 em (0.06) | line-height 1.4 (1.3) | |
| `footerCount` | Black | 22 (phone 20) | −0.2 pt | | 2 OF 3 SELECTED |
| `footerHint` | Mono Bold | 13 (phone 11) | 0.12 em | | |
| `clearButton` | ExtraBold | 18 (phone 16) | 0.02 em | `secondaryText` | CLEAR |
| `primaryButton` | Black | 22 (phone 19) | 0 | | SHOW THE MAP |

All text is uppercased (`.textCase(.uppercase)`); Hebrew is unaffected. Space Mono has no Hebrew glyphs — the system cascades to a Hebrew font automatically; accept (§H.2).

### C.6 Radii, strokes, spacing

`DesignTokens.swift` also holds: `Radius` (24 readout cards/THEN/tapped/iPad THEN bar; 20 search/nearby rows/chips; 18 buttons/phone rows/76-badge; 16 phone chips/back/phone buttons/recent chips; 14 56-badge/phone back; 12 48-badge/44-header-badge/pad pucks; 11 phone pucks/pad terminus; 10 pucks/40-badge/38-badge/capsule; 8 30-badges/phone terminus; 5 terminus bar), `Stroke` (rail 12/14, ring 6, capsule 4, node 12, stub 16, chip border 3, tapped card border 3, search border 2, THEN outline 2, close X 2.4, chevron/arrow 2.8, check 2.6), `Spacing` (side inset 40 landscape / 36 pad / 20 phone; header→title gap 16; readout padding 26/40/30; readout gap 28 (24 beside); primary badge→text gap 32 (24 beside, 28 pad, 18 phone); column gap 8 (6 beside, 14 pad, 12 phone); THEN card padding 20/24, inner gaps 12/18; tapped card padding 18/22, gaps 14; setup grid gap 24 (phone 12); nearby row gap 14 (phone 10); nearby row height 96 (phone 84); recent row height 96 (phone chip 56); search height 76 (phone 60); chip height 168 (phone 104); buttons height 64 (phone 58)).

### C.7 How tokens reach views

```swift
nonisolated struct Theme: Hashable, Sendable { /* every colour token above as `Color` */ 
    static let dark: Theme; static let light: Theme
    static func resolve(_ scheme: ColorScheme) -> Theme
    func rail(_ index: Int) -> Color          // LinePalette by scheme
    func lineText(_ index: Int) -> Color
    var isLight: Bool
}
extension EnvironmentValues { @Entry var theme: Theme = .dark }
```

`BoardView`/`SetupFlowView` set `.environment(\.theme, Theme.resolve(colorScheme))` from `@Environment(\.colorScheme)`. The appearance setting (`system` / `dark` / `light`, default **dark**) is applied at the root with `.preferredColorScheme(...)`, so the theme follows it. Views never hardcode a hex.

---

## D. Responsive layout strategy (`Board/BoardLayoutMode.swift`)

### D.1 Mode resolution — geometry + size classes, never device model

```swift
nonisolated enum BoardLayoutMode: Hashable, Sendable { case landscape, landscapeSingle, phone, pad }

nonisolated struct BoardLayout: Hashable, Sendable {
    var mode: BoardLayoutMode
    var scale: CGFloat
    var headerHeight: CGFloat
    var readoutHeight: CGFloat
    var mapSize: CGSize            // remainder of the height × full width
    var sideInset: CGFloat
    var preset: MapSizePreset      // for MapLayoutRequest
    var axis: MapAxis
    var namesAllLines: Bool        // false only for phone with 3 lines (distance spines)

    static func resolve(size: CGSize, lineCount: Int,
                        horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) -> BoardLayout
}
```

Rules (exact):

1. `isLandscape = size.width > size.height && (size.width >= 900 || size.height <= 500 || vertical == .compact)`.
   - `width >= 900` is the Mac/iPad breakpoint from the brief.
   - `height <= 500 || vertical == .compact` keeps an old wall iPhone in landscape (667×375, 812×375, 844×390) on the landscape layout — those are the primary wall devices and are all narrower than 900.
   - Everything else is portrait: iPad Split View 1/3 (≈ 375 wide), Slide Over, Stage Manager windows taller than wide, Mac windows narrower than 900, folded foldable, unfolded foldable in portrait.
2. Landscape: `scale = min(width / 1280, height / 720)`; `mode = lineCount == 1 ? .landscapeSingle : .landscape`; `headerHeight = 72·scale`; `readoutHeight = 268·scale`; `mapSize = (width, height − header − readout)` (≥ 380·scale by construction); `sideInset = 40·scale`; `preset = .landscape/.landscapeSingle`; `axis = .horizontal`.
3. Portrait, `width >= 600` → `.pad`: `scale = min(width / 834, height / 1194)`; header `88·scale`; readout `386·scale`; map = remainder (≥ 720·scale); inset `36·scale`; `namesAllLines = true`.
4. Portrait, `width < 600` → `.phone`: `scale = min(width / 390, height / 844)`; header `64·scale`; readout `310·scale`; map = remainder; inset `20·scale`; `namesAllLines = lineCount < 3`.
5. Header and readout are fixed multiples of `scale`; **the map takes the remainder**, so extra height lengthens the dash runs (portrait) or adds air around the rows (landscape) — the same behaviour as the artboards' `flex: 1 1 auto` regions. Extra width in landscape goes into the dash (§B.5 step 4); extra width in portrait keeps the column pitch and centres the trunk at `W/2`.
6. `scale` never exceeds 1.6 (a 4K Mac window would otherwise produce a 200 pt numeral); never below 0.32 (below 0.5 the readout is unreadable and the view shows the map alone; see §E.10).

Tests (`BoardLayoutModeTests.swift`): `iPhone8Landscape_isLandscape` (667×375), `iPhone15Portrait_isPhone` (393×852), `iPadPortrait_isPad` (834×1194), `iPadLandscape_isLandscape` (1194×834), `macSmallWindow_isPortraitRules` (880×700 → `.pad`), `mac1280x720_scaleOne`, `splitViewThird_isPhone` (375×1024), `foldedCover_isPhone` (e.g. 380×800), `unfoldedSquarish_isPad` (900×1000 → portrait rules → `.pad`), `unfoldedWide_isLandscape` (1200×1000 → landscape), `phoneThreeLines_namesOnlyTrunk`, `scaleClampedTo1_6`.

### D.2 The one shared view layer

`BoardView` is the only screen root. Structure:

```swift
struct BoardView: View {
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.colorScheme) private var scheme
    @Bindable var model: BoardViewModel
    var body: some View {
        GeometryReader { proxy in                       // the ONLY GeometryReader in the board; size = safe-area size
            let layout = BoardLayout.resolve(size: proxy.size, lineCount: model.lines.count, horizontal: hSize, vertical: vSize)
            VStack(spacing: 0) {
                HeaderView(layout: layout, model: model).frame(height: layout.headerHeight)
                MapView(layout: layout, model: model).frame(height: layout.mapSize.height)
                Group {
                    switch layout.mode {
                    case .landscape, .landscapeSingle: ReadoutView(layout: layout, model: model)
                    case .phone, .pad: ReadoutPortraitView(layout: layout, model: model)
                    }
                }.frame(height: layout.readoutHeight)
            }
            .environment(\.theme, Theme.resolve(scheme))
        }
        .background(theme.background.ignoresSafeArea())   // only the background ignores safe areas
        .modifier(WallModeModifier(...))                  // §G
        .overlay(SettingsAffordanceOverlay(...))
    }
}
```

- Orientation changes, iPad Split View / Slide Over / Stage Manager resizes, macOS window resizing, foldable fold/unfold: all arrive as a new `proxy.size` → new `BoardLayout` → the same views re-lay out. No `UIDevice.orientation`, no `UIScreen.main.bounds`, no model checks.
- `.containerRelativeFrame(.horizontal)` is used in `ReadoutPortraitView` (pad) for the full-width THEN bar and in `StopPickerView` (landscape) to give the NEARBY column the remaining width beside the fixed 360·scale RECENT column; `.safeAreaInset` is not used (the settings affordance is an overlay); `.scenePadding()` is applied to the setup screens' outer container in addition to the artboard's inset so Mac/iPad windows keep Apple's scene margins.
- Dynamic Type: hand mode uses `Font.bus(_:size:relativeTo:)` with `relativeTo: .body` for readout and setup text (not for map labels — those are geometry), so text scales with the user's size; wall mode pins `.dynamicTypeSize(.large)` on the root (fixed by design).
- macOS: `WindowGroup { RootView() }.defaultSize(width: 1280, height: 720).windowResizability(.contentMinSize)` with `.frame(minWidth: 480, minHeight: 600)` on `RootView`. Below 900 wide the portrait rules apply (rule 1). The macOS window's title bar is hidden with `.windowStyle(.hiddenTitleBar)` (no navigation chrome).

### D.3 Foldable / dual-display iPhone

- The exact scene/hinge API surface for the iPhone duo at iOS 27 is **not known to this plan** and no API names are invented. The approach is entirely geometry-driven: the app supports every orientation; `BoardView` re-resolves its layout from the safe-area size on every change; the folded cover display resolves to `.phone`, an unfolded portrait display ≥ 600 pt wide resolves to `.pad`, an unfolded landscape display ≥ 900 pt resolves to `.landscape`. Half-opened/tent posture: the app makes no attempt to place content relative to a hinge; the board keeps its normal composition in whatever size the system gives the scene. If Apple exposes a posture/hinge API, the only integration point is `BoardLayout.resolve` (add a parameter; nothing else changes) — note this in a code comment.
- No `UIRequiresFullScreen`; `INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES` is already set, so multiple scenes/windows work on iPad/Mac.

---

## E. Screen-by-screen build spec

Every measurement is at the reference size; multiply by `layout.scale`. "Real control" = `Button`/`TextField`/`Link` with an accessibility label. Colours are `Theme` tokens; type styles are §C.5 names.

### E.1 Main — wall view, 3 lines, landscape (1280×720; also the Merge1–3 artboards' shell)

Hierarchy: `BoardView` → `VStack(spacing 0)` { `HeaderView` (72) / `MapView` (380) / `ReadoutView` (268, `readoutBand`) }. No dividers.

**HeaderView (72 high, horizontal padding 40):**
- Leading `HStack(alignment: .lastTextBaseline, spacing 16)`: `Text(stop.name)` `titleLandscape` `primaryText`; `Text("STOP \(stop.code)" + (city.map { " · \($0)" } ?? ""))` `headerCaption`. In `.landscapeSingle` a 44×44 r12 `LineBadgeView` (numeral 24) precedes the title with spacing 16 and `HStack(alignment: .center)` (SingleLine artboard).
- Trailing `HStack(spacing 22)`: `LiveIndicatorView` (`HStack(spacing 10)`: 10×10 circle `liveDot` / `stale`; `Text("LIVE"|"STALE"|"CONNECTING")` `liveLabel`) with `.accessibilityLabel("Live data" / "Data is stale, last update N seconds ago")`; `ClockView` `clock` (`TimelineView(.everyMinute)`, `Date.FormatStyle` `HH:mm` in the user's locale, 24-hour when the locale is).
- Not a control. The whole header is `.accessibilityElement(children: .combine)`.

**MapView (380 high):** `ZStack(alignment: .topLeading)` sized by the map area:
1. `MapRailsCanvas(scene)` — a `Canvas` with `.accessibilityHidden(true)`. Draw order: for each rail in `scene.rails` (non-trunk first): `.line`/`.cubic` as one continuous `Path` stroked `StrokeStyle(lineWidth: rail.width, lineCap: .round)` in `theme.rail(colorIndex)`; `.dashed` runs stroked separately with `StrokeStyle(lineWidth: rail.width, lineCap: .butt, dash: [on, off])`; dimmed rails at `.opacity(0.45)`. Then termini: `.bar` → `RoundedRectangle(cornerRadius 5)` filled line colour; `.badge` is NOT drawn in the canvas (it is a `LineBadgeView` in the labels layer so the numeral is real text). Then stops: rings → `Circle` path of `ringRadius` filled `theme.background` and stroked `strokeWidth` line colour; capsules → `RoundedRectangle(cornerRadius 10)` at `capsuleRect` filled `background`, stroked 4 `primaryText`. Then the stub (`stubFrom→stubTo`, width 16, round caps, `primaryText`) and the node (`Circle` r 26 filled `background`, stroked 12 `primaryText`).
2. `StopLabelsLayer(scene)` — `ForEach(scene.labels)`: `Text(label.text)` with `stopName` style, colour by role (`terminus` → `theme.lineText(i)`, `stop` → `stopName`, `junction` → `primaryText`), `.fixedSize()`, `.rotationEffect(.degrees(-35), anchor: .bottomLeading)`, positioned so its bottom-left corner sits at `label.anchor` (use `.alignmentGuide`-free approach: `.position` of the text centre = anchor + rotated half-size; implement a helper `RotatedLabel(text:anchor:degrees:)` that measures with `GeometryReader` inside an `overlay` — or simply place an `HStack` with `Spacer` — the helper is the cleanest and is reused in every mode). Dimmed → `.opacity(0.45)`. Labels are `Text` so they are selectable on macOS (`.textSelection(.enabled)` in hand mode) and read by VoiceOver as part of the map group.
3. Dash captions: `ForEach(scene.dashes where showLabel)`: `Text("+\(n) STOPS")` `dashCaption`, `.position(labelCenter)`.
4. Terminus badges (portrait only) — `LineBadgeView` positioned at `terminus.rect`.
5. `PucksLayer`: `ForEach(scene.pucks)` `BusPuckView(puck:)` `.position(puck.center)` `.animation(.easeInOut(duration: 0.6), value: puck.center)`.
6. "YOUR STOP": `Text` `yourStop` `primaryText`, centred at `(captionAnchor.x, captionAnchor.y + 6)` (top of text at +46 from the node centre, width 160). `.accessibilityLabel("Your stop, \(stop.name)")`.
7. Hint: `Text("TAP A BUS TO INSPECT IT")` `hint` at `hintAnchor` (top-leading). Hidden once any bus has been tapped in this session.
8. Trunk-change crossfade: layers 1–4 are wrapped in a container with `.id(scene.trunkLineID)` and `.transition(.opacity)`, inside `.animation(.easeInOut(duration: 0.4), value: scene.trunkLineID)`. Pucks (layer 5) are outside the crossfade so they slide.

The scene is built in `MapView.body` from `model.mapInputs` + `layout` via `MapLayoutEngine.layout` (pure; cheap; recomputed on every render — sizes are small). Cache with `@State` keyed by (inputs, layout) only if profiling shows >2 ms.

**BusPuckView:** a `Button` whose label is `ZStack` { `RoundedRectangle(r 10)` fill line colour, 44×36; `Text(number)` `puckNumeral` `numeralOnColor` }. Halo: `.background(RoundedRectangle(r 10+5).fill(theme.background).padding(-5))`. Selected: additional `RoundedRectangle(r 10+10).stroke(theme.primaryText, lineWidth: 5).padding(-7.5)` and `.scaleEffect(1.14)`. `.frame(minWidth: 44, minHeight: 44)` + `.contentShape(Rectangle())` for the hit area. `.buttonStyle(.plain)`. Accessibility label: `"Bus \(number), \(minutes) minutes away, \(stops) stop(s)"`, add ", selected" when selected. Dimmed (beside mode) → `.opacity(0.55)` (BusDetail artboard uses 0.55 for pucks, 0.45 for rails).

**ReadoutView (landscape; padding top 26, sides 40, bottom 30; `HStack(spacing 28)`):**
- Primary block (`HStack(alignment: .center, spacing 32)`): `LineBadgeView(size 104, radius 24, numeral 58, ring: true)` — ring = halo 6 of `readoutBand` then 5 of `primaryText` (this ring is the only thing tying the map to the numbers; the same ring is on the selected puck). Then `VStack(alignment: .leading, spacing 8)`: kicker `Text("NEXT ARRIVAL" | "SELECTED BUS")` `kicker`; `HStack(alignment: .lastTextBaseline, spacing 14)` { `Text(minutes)` `minutesPrimary` `primaryText` (`.contentTransition(.numericText())`); `Text("MIN")` `unitPrimary` line colour (light: `secondaryText`) }; sub-line `HStack(spacing 14)` { `Text("1 STOP AWAY")` `subStopsAway`; 5 pt dot `hint`; `Text("ARRIVES 14:33")` `subArrives`; dot; `Text("TO VISTA PARK")` `subDestination` } — each segment optional (§F.4).
- `ThenCardView` (`.frame(width: 380)`): `card` fill, r 24, padding 20/24, `VStack(alignment: .leading, spacing 12)` { `Text("THEN")` `thenLabel`; `HStack(spacing 18)` { badge 56 r14 numeral 30; `HStack(alignment: .lastTextBaseline, spacing 8)` { minutes `minutesSecondary`; "MIN" `unitSecondary` } }; `Text("3 STOPS · 14:37 · TO NORTHGATE")` `thenSub` }. Hidden when there is no second arrival (Main's `sc-if hasSecond`). Light: no fill, 2 pt `cardOutline` stroke, padding 18/22.
- Minutes count down locally each second (§F.2).

### E.2 SingleLine — 1 line landscape

Same shell. Header gains the 44 badge and (judgement) keeps "STOP {code}" as the caption rather than the artboard's placeholder "ONE LINE". Map uses `.landscapeSingle` metrics (§B.4): one row at centre, larger marks, head 2. Stop names use `secondaryText` (SingleLine draws `#A0A0AE`). Pucks 56×40 r10 numeral 22 halo 6; selected 64×48 r12 numeral 26 with 5 ring. Readout identical to E.1; the THEN card shows the same line's next bus.

### E.3 BusDetail — tapped bus, "beside" mode (landscape)

Map: `highlightedLineID = tapped.lineID` → other rails 0.45, other pucks 0.55; the tapped puck gets the white ring + 1.14 scale (the ring moves from the next-arrival puck to the tapped one; the primary badge in the readout loses its ring). The last stop the bus passed is labelled `primaryText` (BusDetail paints "OLD MILL" white) — add `StopLabelRole.passed` handling in `StopLabelsLayer` by checking `model.tappedDetail?.lastStopCode`.

Readout (`HStack(spacing 24)`): primary shrinks: badge 84 r20 numeral 46 **no ring**, `VStack(spacing 6)`, kicker 12, minutes 92 (−4, lh 0.84), unit 28, sub-line as one `subPhone`-style `Text("1 STOP · 14:33 · TO VISTA PARK")` (14 pt, 0.04 em). Then `TappedBusCardView` `.frame(width: 540)`: `outlinedCard` fill, 3 pt stroke line colour, r 24, padding 18/22, `VStack(alignment: .leading, spacing 14)`:
1. `HStack(spacing 14)` { badge 40 r10 numeral 22; `Text("TAPPED BUS")` `tappedKicker` line colour; `Spacer`; close `Button` 34×34 circle `closeButton` with an X drawn as a `Path` (14×14, stroke 2.4 `primaryText`), `.accessibilityLabel("Close bus details")` }.
2. `HStack(alignment: .lastTextBaseline, spacing 12)` { minutes `tappedMinutes`; "MIN" `tappedUnit` line colour; dot; `Text("6 STOPS AWAY")` `tappedStops` }.
3. `HStack(spacing 16)` { `Text("LEFT OLD MILL 1 MIN AGO")` `tappedDetail` `secondaryText`; dot; `Text("RUNNING 2 MIN LATE")` `tappedDetail` `late` } — each optional (§F.4); "RUNNING ON TIME" when |delay| < 60 s and the delay is known; "RUNNING 2 MIN EARLY" for negative.
Dismiss: the X, tapping the tapped puck again, tapping the node, or Escape on Mac (`.keyboardShortcut(.cancelAction)` on the close button).

### E.4 MainLight

No new views: `Theme.light` (§C.2) + `LinePalette.lightRail/lightText`. Check-list of what changes: readout band = background; THEN card outline; MIN unit `secondaryText`; separator dots `#B6B2A8`; terminus names use `lineText`; halos/ring/stub/node/capsules use light tokens; live dot `#1A7F4B`; puck numerals `#14140F`.

### E.5 StationPicker — Setup 1, landscape (1280×720, padding 40)

`StopPickerView`, `VStack(alignment: .leading, spacing 0)`:
- Title row `HStack(alignment: .lastTextBaseline)` { `Text("CHOOSE YOUR STOP")` `setupTitle`; `Spacer`; `Text("STEP 1 OF 2")` `stepCaption` }.
- `SearchField` (top margin 22): `TextField("Search a stop, street or line number", text:)` `searchInput`, height 76, `card` fill, 2 pt `searchBorder`, r 20, leading padding 64 with a 24 pt magnifier drawn as `Path` (circle r 7.5 + stroke 2.6, colour `stopName`) at x 26; `.textFieldStyle(.plain)`, `.submitLabel(.search)`, `.accessibilityLabel("Search stops or lines")`, `.autocorrectionDisabled()`. Numeric query → code lookup; otherwise name search (existing provider behaviour). Results replace the NEARBY list under a "RESULTS" header while the query is non-empty.
- Columns (top margin 28, `HStack(alignment: .top, spacing 40)`): NEARBY column (`containerRelativeFrame` remainder) and RECENT column (`.frame(width: 360)`).
  - NEARBY header row: `Text("NEARBY")` `sectionHeader`; `Spacer`; caption `countCaption`: `"\(n) STOPS WITHIN 500 M"` / `"LOCATION OFF · SEARCH ABOVE"` when denied / `"FINDING STOPS NEAR YOU…"` while locating.
  - `NearbyStopRow` × up to 4 (landscape) — a `Button` (`.buttonStyle(.plain)`): height 96, `card` fill, r 20, padding 0/24, `HStack(spacing 22)` { `Text("80 M")` `distanceChip` `.frame(width: 76, alignment: .leading)`; `Text(name)` `nearbyName`; `Spacer`; up to 3 `LineBadgeView(size 38, r 10, numeral 18)`; `Text("+\(rest)")` `overflowCount` when more }. Keyboard focus/hover: 3 pt `primaryText` border (`.focusable()`, `@FocusState`). Accessibility: "Harbor Gate, 80 metres, lines 18, 41, 7 and 5 more".
  - RECENT: header + `RecentStopRow` (`Button`, height 96, `card`, r 20, padding 0/24, `Text(name)` `recentName`), up to 3.
- Distance formatting: `Measurement<UnitLength>` in metres, rounded to 10 m, `"80 M"` (`MeasurementFormatter` with `.providedUnit`, uppercase); ≥ 1000 m → `"1.2 KM"`.
- Nearby list rows: 4 landscape, 6 portrait; sorted by distance; radius 500 m (fixed caption text; if fewer than 4 within 500 m, extend the query to 1000 m and caption "N STOPS WITHIN 1 KM").

### E.6 LinePicker — Setup 2, landscape

`LinePickerView`, padding 40:
- Header `HStack(alignment: .top)` { `HStack(spacing 20)` { back `Button` 52×52 r16 `card` with chevron `Path` (20 pt, stroke 2.8), `.accessibilityLabel("Back to stop selection")`; `VStack(alignment: .leading, spacing 6)` { `Text(stop.name)` `setupTitle`; `Text("PICK UP TO 3 LINES TO WATCH")` `pickerSubtitle` } }; `Spacer`; `Text("STEP 2 OF 2")` `stepCaption` }.
- Grid (top margin 34): `LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 24), count: 6), spacing: 24)` of `LineChipView` (`Button`, `.buttonStyle(.plain)`): height 168, r 20, padding 18, `VStack(alignment: .leading)` { `HStack(alignment: .top)` { `Text(number)` `chipNumber` (line colour / `numeralOnColor` when selected); `Spacer`; when selected a 30 pt circle `background` with a 15×12 check `Path` stroke 2.6 `primaryText` }; `Spacer`; `Text(destination)` `chipDestination` (`stopName` / `numeralOnColor`) `.lineLimit(2)` }. Fill `chipUnselected` / line colour; 3 pt border line colour. When 3 are selected, unselected chips → `.opacity(0.3)` and `.disabled(true)`; never an error. `.accessibilityLabel("Line \(n) to \(dest)")`, `.accessibilityAddTraits(selected ? .isSelected : [])`.
- Footer (`Spacer` then `HStack`): `VStack(alignment: .leading, spacing 8)` { `Text("\(k) OF 3 SELECTED")` `footerCount`; `Text(hint)` `footerHint` — `"ADD UP TO \(3−k) MORE"` or `"TAP A SELECTED LINE TO SWAP IT OUT"` at 3 }; `Spacer`; `HStack(spacing 16)` { CLEAR `Button` (height 64, padding 0/28, r 18, `background` fill, 2 pt `clearButtonBorder`, `clearButton` style); SHOW THE MAP `Button` (height 64, padding 0/36, r 18, `primaryButtonFill`, `primaryButton` style, arrow `Path` 22×16 stroke 2.8, `.disabled(k == 0)`, `.keyboardShortcut(.defaultAction)`) }.
- Lines come from `provider.lines(atStop:)`; chip destination = `line.destination ?? line.headsign ?? ""`; sorted by `shortName.localizedStandardCompare`.

### E.7 PhoneOneLine / PhoneTwoLines / PhonePortrait — iPhone portrait (390×844)

Shell: header 64 (padding 0/20): `Text(name)` `titlePhone`; trailing `HStack(spacing 10)` { 8×8 live dot (no "LIVE" label on phone); `ClockView` 15 }. Map 470 with `.phone` preset (§B.4): termini are `LineBadgeView(30×26, r 8, numeral 16)` placed at `TerminusMark.rect`; names horizontal via `StopLabelsLayer` (`rotationDegrees 0`, `.leading` at `anchor` → `.position(x: anchor.x + width/2, y: anchor.y)`; `.trailing` mirrored). Distance spines (3 lines): no labels at all on the two left columns; tapping a spine's terminus badge (a `Button`, "Promote line 18 to the centre") or any of its pucks sets `model.promoteTrunk(lineID)` (§B.7 manual). Pucks 46×36 r11.

Readout 310 (`readoutBand`, padding 24/20/26, `VStack` with `Spacer` between): primary `VStack(alignment: .leading, spacing 12)` { kicker 12; `HStack(spacing 18)` { badge 76 r18 numeral 40, ring halo 5 + white 4; `HStack(alignment: .lastTextBaseline, spacing 10)` { minutes 92 (−4, lh 0.82); "MIN" 24 } }; `Text("1 STOP AWAY · ARRIVES 14:33")` `subPhone` }. THEN row (no card): `HStack(spacing 16)` { badge 48 r12 numeral 24; `HStack(alignment: .lastTextBaseline, spacing 8)` { minutes 40 (−1.5, lh 0.9); "MIN" 16 }; `Spacer`; `VStack(alignment: .trailing)` { `Text("3 STOPS")`, `Text("14:37")` } `thenSub` 12 }. Tapped-bus "beside" on phone (not designed): show the `TappedBusCardView` as a `.sheet` with `.presentationDetents([.medium])` in hand mode; in wall mode use swap. (Judgement, §H.3.)

### E.8 PadPortrait — iPad portrait (834×1194)

Header 88 (padding 0/36): title 30, caption `"STOP \(code)"` 12, live dot 9 + "LIVE" 11, clock 22. Map 720 with `.pad` preset: three named columns at 167/417/667 (all named), terminus badges 44×38 r11 numeral 22, rings r15/7, pitch 86, pucks 52×40 r12 numeral 22 halo 6 ring 5. Readout 386 (padding 28/36/32): primary `VStack(spacing 14)` { kicker 13; `HStack(spacing 28)` { badge 110 r26 numeral 60 with ring (6 + 5); minutes 140 (−6, lh 0.8); "MIN" 36 }; sub-line as landscape (17 / 16 / 15 with dots) }. THEN bar: `containerRelativeFrame(.horizontal)`, height 108, `card`, r 24, padding 0/26, `HStack(spacing 22)` { "THEN" 12; badge 60 r15 numeral 30; minutes 52 (−2) + "MIN" 20; `Spacer`; `Text("3 STOPS · 14:37 · TO NORTHGATE")` 14 }.

### E.9 StationPickerPhone / LinePickerPhone — setup, portrait (390×844, padding 22/20/24)

Stop picker: `VStack(spacing 6)` { "STEP 1 OF 2" 11; "CHOOSE YOUR STOP" 30 }; search (top 18, height 60, r 16, leading padding 50, icon 20 at (20,20), placeholder "Search stop or line", 18 pt); NEARBY header (top 24) with count 11; rows (top 10, spacing 10): height 84, r 18, padding 0/16, `HStack(spacing 12)` { distance 13 width 52; name 20 (flex); badges 30 r8 numeral 15 ×≤3; "+N" 12 }; 6 rows; RECENT header (top 22); `HStack(spacing 10)` of ≤ 2 chips (height 56, r 16, `card`, `recentName` 15 centred). The whole screen is a `ScrollView` (setup is allowed to scroll; the board never is).

Line picker: "STEP 2 OF 2" 11; `HStack(spacing 14)` { back 46×46 r14; `VStack(spacing 4)` { name 26; subtitle 10 } } (top 10); grid 3 columns spacing 12 (top 22): chips height 104, r 16, padding 12, number 34 (−1), check 24 pt (13×10 glyph), destination 9 pt; footer `VStack(spacing 16)` { count 20 + hint 11; `HStack(spacing 12)` { CLEAR `.frame(width: 104)` height 58 r16 16 pt; SHOW THE MAP flex height 58 r16 19 pt arrow 20×14 } }. Grid area scrolls if > 12 lines.

Landscape vs portrait selection for setup uses the same `BoardLayout.resolve` rule (landscape → two columns / 6-across; otherwise one column / 3-across; `.pad` uses the landscape setup layout with 4-across at `scale`).

### E.10 Very small windows

If `scale < 0.5` (Mac window shrunk below ~640×360, Slide Over at 320 wide): show header + map only, readout replaced by a single line `Text("41 · 2 MIN")` `kicker`; nothing else changes.

### E.11 Settings (`SettingsView`, reachable from the affordance)

`Form` in a `NavigationStack`, sheet on iOS / `Settings` scene on macOS (`Settings { SettingsView() }` in the App). Sections: **Display** — `Toggle("Wall mode")`, `Picker("Appearance")` system/dark/light, `Picker("Tap a bus")` "Swap the readout" / "Show beside" (default follows wall mode until the user picks); **Stop & lines** — current stop name + lines, `Button("Change stop…")` → SetupFlow; **Data** — `Picker("Provider")` from `TransitProviders.all`, last update time, `Button("Refresh now")`; **Debug** (DEBUG only) — mock scenario picker (Main / Merge A / Merge B / Merge C), `NavigationLink("Transit POC")`. Standard system styling (this screen is chrome, not the design).

---

## F. Data + state

### F.1 Seam changes (`Transit/`)

1. `TransitModels.swift`:
   ```swift
   nonisolated struct NearbyStop: Hashable, Sendable { var stop: TransitStop; var distanceMeters: Double; var lines: [TransitLine] }
   // ProviderCapabilities: add
   static let nearbyStops = ProviderCapabilities(rawValue: 1 << 7)
   // Arrival: add
   var delay: TimeInterval? { scheduledAt.map { expectedAt.timeIntervalSince($0) } }
   ```
2. `TransitProvider.swift`: add `func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop]` (sorted by distance). Default implementation in a protocol extension throws `TransitError.unsupported("nearby stops")`.
3. `BusGovILProvider`: implement via `GET {scheduler}/Stops/GetStopsCloseToLocation?lat=&lng=&radius=` (research §3.1.4-addendum: returns stops each with `routesInStop[]`); map with the existing `DTO.RouteInStop.line`; distance via `RouteGeometry.meters`. Add `.nearbyStops` to `capabilities`. Also uppercase nothing here — presentation does that.
4. `StrideProvider`: no capability; default throws.
5. `MockTransitProvider` (rewrite): backed by `MapFixtures` + a `MockScenario` (`.main`, `.mergeA`, `.mergeB`, `.mergeC`) read from `UserDefaults.standard.string(forKey: "mock.scenario")` at call time. Synthetic coordinates: stop `k` of a line at `lat = 32.80 + 0.004·k`, `lon = 34.95 + 0.006·row` (rows never overlap; shared stops get the trunk's coordinates by code so snapping works). Vehicles: per line, buses depart every `headway` (5, 7, 9 min for 41/18/7) with `tripDuration = 2 min × (stops − 1)`; positions interpolated between stops; `arrivals` derived from remaining distance at constant speed with `scheduledAt = expectedAt − 90 s` for line 7 (so lateness shows) and `isRealtime = true`. Nearby stops: every fixture stop within radius of a fake location (`32.83, 34.97` = HARBOR GATE), distances 80/210/340/610/780/920 m for the first six. Stop search: substring on name or exact code. `suggestedRefreshInterval = 5 s`.
6. `BusProgressService`: `BusProgress` gains `var arrivals: [Arrival]` (all, soonest first, filtered `expectedAt > now − 60 s`); `nextArrival` remains `arrivals.first`.
7. `RoutePatternCache` (`actor`): `func pattern(for line: TransitLine, providerID: String, fetch: () async throws -> RoutePattern) async throws -> RoutePattern` — JSON file `<Application Support>/BusBus/patterns/<providerID>/<lineID>.json`, TTL 24 h, stale-while-error (returns the cached copy if the fetch fails).

### F.2 Board models (`Board/BoardModels.swift`)

```swift
nonisolated struct BoardBus: Identifiable, Hashable, Sendable {
    var id: String; var lineID: String; var lastStopIndex: Int; var progressToNext: Double
    var stopsAway: Int; var lastStopCode: String?; var lastStopPassedAt: Date?   // passedAt only when observed this session
}
nonisolated struct BoardArrival: Identifiable, Hashable, Sendable {
    var id: String            // "\(lineID)#\(tripId ?? expectedAt.timeIntervalSince1970)"
    var lineID: String; var expectedAt: Date; var isRealtime: Bool; var delay: TimeInterval?
    var bus: BoardBus?        // matched vehicle, if any
    func minutes(at now: Date) -> Int { max(0, Int((expectedAt.timeIntervalSince(now) / 60).rounded(.up))) }
}
nonisolated struct BoardSnapshot: Hashable, Sendable {
    var fetchedAt: Date; var arrivals: [BoardArrival]  // all lines, soonest first
    var buses: [BoardBus]; var patterns: [String: RoutePattern]  // by lineID, trimmed to end at the user's stop
}
nonisolated struct ReadoutPrimary: Hashable, Sendable { var arrival: BoardArrival; var line: TransitLine; var colorIndex: Int; var kicker: String /* NEXT ARRIVAL | SELECTED BUS */ }
nonisolated struct ReadoutSecondary: Hashable, Sendable { var arrival: BoardArrival; var line: TransitLine; var colorIndex: Int }
nonisolated struct TappedBusDetail: Hashable, Sendable { var bus: BoardBus; var arrival: BoardArrival?; var line: TransitLine; var colorIndex: Int; var lastStopName: String?; var lastStopCode: String? }
```

Countdown: views wrap the minutes text in `TimelineView(.periodic(from: .now, by: 1))` and call `arrival.minutes(at: context.date)`. `< 45 s` → the numeral shows `"NOW"` (same style). Arrivals whose `expectedAt < now − 60 s` are dropped at the next poll; between polls a passed arrival shows "NOW".

### F.3 `BoardViewModel` (`@MainActor @Observable final class`)

State: `configuration: BoardConfiguration` (stop, lines, providerID), `snapshot: BoardSnapshot?` (last good), `lastSuccessAt: Date?`, `lastError: String?`, `isRefreshing`, `trunk: TrunkSelector`, `trunkLineID: String?`, `selectedBusID: String?`, `tapBehaviour: TapBehaviour` (from settings), `hasTappedOnce`. Derived (computed, cheap): `lines: [TransitLine]`, `primary: ReadoutPrimary?`, `secondary: ReadoutSecondary?`, `tappedDetail: TappedBusDetail?`, `isStale(now:)` = `lastSuccessAt.map { now − $0 > 90 } ?? true`, `mapInputs: (lines: [MapLineInput], vehicles: [MapVehicleInput])`.

Refresh (`func refresh() async`), one pass:
1. For each line concurrently: pattern via `RoutePatternCache` (→ `RouteGeometry`), then `BusProgressService.progress(provider:geometry:line:stop:)` (vehicles + arrivals). A failing line keeps its previous data; `lastError` records the message; `lastSuccessAt` updates only if **at least one** line succeeded.
2. Trim each pattern to `stops[0...userIndex]` (`firstIndex` of the stop code, as the POC) and drop buses with `distanceAlongRoute > targetDistance + 40 m` (passed). `BoardBus.lastStopIndex = geometry.lastStopIndex(atDistance:)`, `progressToNext = (d − stopDistances[i]) / (stopDistances[i+1] − stopDistances[i])`, `stopsAway = userIndex − lastStopIndex`. Bus ids: `plateNumber ?? tripId ?? "\(lineID)-rank\(k)"` where `k` counts from the stop backwards (rank id is stable between polls unless buses overtake — bus.gov.il case).
3. **Arrival↔bus matching per line:** buses sorted by distance descending (closest to the stop first); arrivals soonest first; pair index-wise. Extra arrivals (scheduled trips not yet departed, or positions missing) have `bus == nil`; extra buses have no arrival and are drawn on the map but excluded from the readout.
4. `lastStopPassedAt`: keep a dictionary `busID → (lastStopIndex, changedAt)`; when `lastStopIndex` increases, set `changedAt = now`. If the bus was first seen at this index, `lastStopPassedAt = nil`.
5. `trunkLineID = trunk.select(candidateID: arrivals.first?.lineID, now: .now)`.
6. If `selectedBusID` no longer exists in `buses`, clear it.

Polling loop: `start()` creates a `Task` that loops `refresh()` then `sleep(interval)`, `interval = clamp(provider.suggestedRefreshInterval, 20 s, 30 s)` (mock: 5 s), exponential back-off on total failure (5, 10, 20, 40, 60 s cap) reset on success. `NWPathMonitor` (`Network`) on a background queue → on `.satisfied` after `.unsatisfied`, trigger an immediate `refresh()`. `scenePhase == .active` → immediate refresh. `stop()` cancels.

Readout derivation:
- `primary`: swap mode with a selection → the arrival whose `bus?.id == selectedBusID` (kicker "SELECTED BUS"); else `arrivals.first` ("NEXT ARRIVAL").
- `secondary`: the first arrival after `primary` in time order (any line).
- `tappedDetail` (beside mode with a selection): bus + its arrival + `lastStopName = pattern.stops[lastStopIndex].stop.name`.
- The white ring: on the primary's bus puck (swap) or on the tapped puck (beside) — `MapVehicleInput.isSelected` accordingly.

Tap handling: `func tap(busID:)` — swap: toggles `selectedBusID` (same id → nil); beside: sets `selectedBusID`; both set `hasTappedOnce = true`. `func promoteTrunk(_ lineID:)` sets `trunk.manualTrunkID` and calls `select`. `func dismissTapped()`.

Tests (`BoardViewModelTests.swift`, using a `StubProvider: TransitProvider` built inside the test file from `MapFixtures` with injectable arrivals/vehicles and a `Clock`-style `now` closure):
- `matchesArrivalsToBusesByRank`, `unmatchedArrivalHasNoBus`, `primaryIsSoonestArrival`, `secondaryIsNextAfterPrimaryAcrossLines`, `swapTapMovesPrimaryAndKicker`, `swapTapOnSameBusDeselects`, `besideTapProducesDetailWithLastStop`, `staleAfter90Seconds`, `lastGoodSnapshotKeptOnError`, `lastSuccessUpdatesIfAnyLineSucceeds`, `passedBusesDropped`, `delayFromScheduledVsExpected`, `lastStopPassedAtSetWhenIndexAdvances`, `trunkFollowsSoonestWithHysteresis` (advance `now` by 31 s), `minutesRoundUp` (`90 s → 2`, `44 s → NOW`).

### F.4 Graceful degradation — what the shipping provider cannot supply

`BusGovILProvider.vehicles(for:)` returns **bare lat/lng**: no trip id, plate, timestamp, bearing, speed or delay (research §3.1.4). Consequences and the rule for each design element:

| Design element | Needs | bus.gov.il | Rule |
|---|---|---|---|
| Puck position | position along route | yes (snapped by `RouteGeometry`) | always drawn |
| "1 STOP AWAY" / "6 STOPS AWAY" | stops away | derived from snapped position | shown when a bus is matched; omitted otherwise |
| "ARRIVES 14:33" / minutes | ETA | `Calendar…minutesToArrival` + `isRealTime` | shown; when `isRealtime == false` the sub-line adds "SCHEDULED" in `dashCaption` after the time |
| "TO VISTA PARK" | destination | `line.destination ?? headsign` | shown if non-nil |
| "RUNNING 2 MIN LATE" | delay | `staticArrivalTime` vs `arrivalTime` on the **arrival** (not the vehicle) | shown only when the tapped bus is matched to an arrival with `scheduledAt`; otherwise the segment (and its dot) is omitted |
| "LEFT OLD MILL 1 MIN AGO" | last stop + time | last stop derivable; time only from our own poll history | "LEFT OLD MILL" + " N MIN AGO" only when `lastStopPassedAt != nil`; before that just "LEFT OLD MILL"; if the bus is at the terminus: "AT NORTHGATE" |
| Puck identity across polls | vehicle id | none | rank-based ids; a puck may "jump" if buses overtake — accepted |
| Accessibility "Bus 41, 2 minutes away, 1 stop" | ETA + stops | as above | omit the missing clause |
| Crowding/capacity | — | never | never shown (brief) |
| LIVE indicator | fetch success | yes | LIVE / STALE / CONNECTING |
| Nearby stops with line badges | `stopsNearby` | `GetStopsCloseToLocation` | Stride/others without `.nearbyStops` → NEARBY section hidden, caption "NEARBY NOT AVAILABLE · SEARCH ABOVE" |

`MockTransitProvider` supplies everything so every design state can be exercised; `StrideProvider` shows positions up to 20 min old — its `VehiclePosition.recordedAt` is present, so when `recordedAt` is older than 120 s the puck is drawn at 0.55 opacity and its accessibility label appends "position N minutes old" (judgement; keeps the honest "as of" the research demands).

### F.5 Persistence (`SettingsStore`)

`@MainActor @Observable final class SettingsStore` backed by `UserDefaults.standard` (App Group not needed):
- `configuration: BoardConfiguration?` — `nonisolated struct BoardConfiguration: Codable, Hashable, Sendable { var providerID: String; var stop: TransitStop; var lines: [TransitLine] /* selection order, ≤3 */ }`, JSON under key `board.configuration`. `TransitStop`/`TransitLine` are already `Codable`.
- `recentStops: [TransitStop]` (≤ 6, most recent first, de-duplicated by code), key `board.recentStops`.
- `paletteAssignments: [String: Int]`, key `palette.assignments`.
- Flags via `@AppStorage`-style stored properties on the store (the store reads/writes UserDefaults directly so views observe one object): `wallMode: Bool` (`settings.wallMode`, default false), `appearance: Appearance` (`settings.appearance`, default `.dark`), `tapBehaviourOverride: TapBehaviour?` (`settings.tapBehaviour`; effective = `override ?? (wallMode ? .beside : .swap)`), `providerID` (`settings.providerId`, default `"bus.gov.il"`), `mockScenario` (`mock.scenario`, DEBUG).
- Relaunch rule: `RootView` shows `BoardView` when `configuration != nil`, else `SetupFlowView`. Never setup once a stop is chosen.

Tests (`SettingsStoreTests.swift`, using `UserDefaults(suiteName: "test-\(UUID())")`): `roundTripsConfiguration`, `recentsCappedAtSixAndDeduplicated`, `effectiveTapBehaviourFollowsWallModeUntilOverridden`, `paletteAssignmentsPersist`.

### F.6 Location (`LocationService`)

`@MainActor @Observable final class LocationService`: `status: CLAuthorizationStatus`, `current: GeoPoint?`, `isLocating`. `func locateOnce() async` — `CLLocationManager().requestWhenInUseAuthorization()` on first use (status `.notDetermined`), then `for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) { if let l = update.location { current = …; break } }` with a 15 s timeout (`withThrowingTaskGroup` race against `Task.sleep`). Denied/restricted → `status` reflects it; the picker shows the denied caption and search only; no "Use my location" button anywhere (brief). Build settings: `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription = "Finds bus stops near you for the setup screen."`, `ENABLE_RESOURCE_ACCESS_LOCATION = YES`. The first-launch permission prompt appears when `StopPickerView` appears (the setup screen is the first launch screen).

### F.7 Setup flow state (`SetupViewModel`)

`query`, `results: [TransitStop]`, `nearby: [NearbyStop]`, `nearbyState: .locating | .ready(count) | .denied | .unavailable`, `chosenStop`, `linesAtStop: [TransitLine]`, `selected: [TransitLine]` (≤ 3, order preserved; selecting a 4th is ignored — the chips are disabled anyway). Debounced search (300 ms, `Task` cancellation). `confirm()` → `LineColorAssigner.resolve` → `SettingsStore.configuration = …`, prepend the stop to recents, dismiss to the board. Tests (`LineSelectionTests.swift`): `capAtThree`, `deselectReopensSlot`, `orderPreserved`, `hintTextAtThree`, `showMapDisabledAtZero`.

---

## G. Wall mode (`Wall/`)

`WallModeController` (`@MainActor @Observable`), active only when `settings.wallMode == true`:

| Behaviour | iOS / iPadOS | macOS |
|---|---|---|
| Keep screen awake | `UIApplication.shared.isIdleTimerDisabled = true` on activate, `false` on deactivate/`onDisappear` (`#if canImport(UIKit)`) | `ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Wall display")`; `endActivity` on deactivate |
| Burn-in drift | `TimelineView(.periodic(from: .now, by: 180))` in `BoardView` → `driftOffset(for: context.date)` cycles through 8 positions `[(0,0),(2,0),(2,2),(0,2),(-2,2),(-2,0),(-2,-2),(0,-2)]` every 3 min; applied as `.offset(x:y:)` on the whole `VStack` with `.animation(.easeInOut(duration: 2), value: offset)` | same |
| Ambient dimming | iOS has no public ambient-light API. Proxy: `UIScreen.main.brightness` (auto-brightness lowers it at night); sampled every 60 s via the same `TimelineView`; if `< 0.25` overlay `Color.black.opacity(0.45)` (`.allowsHitTesting(false)`) with 2 s animation. Plus time-of-day fallback: between 23:00 and 06:00 local, overlay 0.3 regardless. Never switches to the light theme. | no brightness API → time-of-day fallback only |
| Self-recovery | polling back-off + `NWPathMonitor` + `scenePhase` refresh (§F.3); `configuration` persisted → relaunch lands on the board; `UIApplication` background: keep the poll task alive only while active (`scenePhase != .active` → pause) | same minus scenePhase nuance |
| No chrome, no scroll | `BoardView` has no `NavigationStack`; `.statusBarHidden(true)` (iOS); `.persistentSystemOverlays(.hidden)`; macOS `.windowStyle(.hiddenTitleBar)` | |
| Fixed type size | `.dynamicTypeSize(.large)` on the root when wall mode | same |
| Settings affordance | `SettingsAffordanceOverlay`: a transparent full-board `.contentShape(Rectangle())` with `.onTapGesture` (simultaneous with puck buttons via `.simultaneousGesture`) → shows a 44×44 gear `Button` (`card` fill, r 12, SF Symbol `gearshape` is acceptable here — it is a control glyph, not UI decoration) at top-trailing inside the header inset; `.transition(.opacity)`; auto-hides after 4 s (`Task.sleep`, reset on each tap); tap → `SettingsView` sheet. In hand mode the gear is always visible. | same; also `Cmd+,` opens Settings |

Tap-to-swap default vs beside: effective tap behaviour is `.beside` in wall mode and `.swap` in hand mode unless overridden (§F.5).

---

## H. Risks, conflicts and judgement calls

### H.1 Brief vs artboard conflicts (artboard wins) — and artboard vs artboard

| # | Topic | Brief says | Artboard says | Resolution in this plan |
|---|---|---|---|---|
| 1 | Phone 2-line rail spacing | 68 pt apart | PhoneTwoLines: columns at 110 and 195 = **85** | 85 for 2 lines; 68 only for 3 lines (59/127/195) |
| 2 | Landscape row pitch | (designer note s1) "110 px row pitch" | every landscape artboard: 70/190/310 = **120** | 120 |
| 3 | Node x | "~1196" | Main SVG 1190; Merge1–3 1196 | 1190 (`W − 90`) — Main's convergence curve is the reproduced geometry |
| 4 | Terminus bar | 10 × 40 | Main CSS 8 × 44; Merge SVG 10 × 40 | 10 × 40 r5 (SVG + brief) |
| 5 | Ring geometry | r 13, 6 pt stroke | Main CSS 26 px box / 6 px border (outer 13); Merge SVG r 13 / 6 (outer 16) | r 13 / 6 (SVG + brief) |
| 6 | Compression tail | "last 4–5 stops"; "≤ 9 stops → draw all" | Main: 1 + dash + 5; SingleLine: 2 + dash + 5; portrait: 1 + dash + 4; Merge: own tails of 1–2 before a fully drawn shared segment | Rule §B.3: head 1 (single: 2), tail budget 5 (portrait 4) shared with the bundle, own tail ≥ 1, dash only if it swallows ≥ 2. Merge artboards are hand-placed illustrations of topology; tests assert the rule, not their counts |
| 7 | Unit "MIN" colour | line colour | MainLight: `#55555F` | line colour in dark, `secondaryText` in light |
| 8 | Light-mode terminus names | not specified | darker ink per line (`#B01A22`, `#8A6000`, `#0B636B`) | `LinePalette.lightText` |
| 9 | Tapped-bus kicker | not specified | "TAPPED BUS" | "TAPPED BUS" |
| 10 | BusDetail puck dimming | "other lines dim to 45 %" | rails 0.45, pucks 0.55, primary badge loses its ring | as artboard |
| 11 | Phone header | (unspecified) | no "LIVE" label, dot only | as artboard |
| 12 | Single-line caption | — | "ONE LINE" | judgement: keep "STOP {code}" (the artboard string is a placeholder) |
| 13 | Merge header captions ("18 JOINS AT MILL JUNCTION") | — | present | not implemented (illustrative); the header caption stays "STOP {code} · {city}" |
| 14 | Stop-name anchor | "anchored at the dot" | Main: text bottom 4 px above the ring; Merge: 20 px above | `across − 20` from the centre (4 px clear of the SVG ring) |
| 15 | Convergence geometry | "short white trunk stub" | Main: 44-long stub, curves at 1020→1120; Merge: 18-long stub, rails to 1164 | Main's numbers relative to the node (§B.4) |
| 16 | Nearby rows | 4 landscape / 6 portrait | same | same |
| 17 | Line chip destination | "destination underneath" | LinePicker: `NORTHGATE DEPOT`; phone: `NORTHGATE` | `line.destination ?? headsign`, 2 lines max |
| 18 | Data model | BRIEF §5 toy structs | — | POC model kept; §5 is a sketch (Global Constraints) |

### H.2 Data the shipping provider cannot supply (see §F.4 table)

- No per-vehicle delay, timestamp, plate, trip id from `GetRouteLocations`. Lateness comes from the matched **arrival** (`staticArrivalTime` vs `arrivalTime`); "N MIN AGO" only from our own observation history. Both degrade by omission, never by fabrication.
- Rank-based vehicle ids can jump when buses overtake. Accepted.
- `RouteGeometry.project` can snap to the wrong pass on a route that visits the same street twice (POC comment). Not fixed in this plan; a future improvement is to prefer the segment nearest the previous poll's distance.
- Israel has no GTFS-RT; MOT SIRI needs a static IP → not client-reachable. The provider seam is the mitigation; the memory note says: ship on bus.gov.il, apply for MOT SIRI with app screenshots.
- bus.gov.il is undocumented and can vanish (predecessor did). Mitigation: seam + Stride fallback (stale) + Mock. The app must show STALE and last-good data, never a blank board.
- Hebrew stop names: `.uppercased()` is a no-op; Space Mono lacks Hebrew → system cascade. Rotated −35° Hebrew labels read right-to-left along the rising baseline; acceptable, verify visually in Task 12.

### H.3 Judgement calls made (do not reopen)

1. Landscape decision rule `width > height && (width ≥ 900 || height ≤ 500 || vertical == .compact)` (§D.1).
2. Two-line landscape: the non-trunk goes top if it precedes the trunk in selection order, else bottom.
3. Phone portrait: non-trunk columns always LEFT of the trunk; iPad: one each side.
4. Trunk-terminus-inside-line and identical-route cases draw independent rails (no capsules) — §B.2.
5. Bundle compression when the shared segment exceeds the tail budget by ≥ 2 (§B.3 rule 1).
6. "NOW" replaces the numeral under 45 s.
7. Phone "beside" mode = sheet with the tapped card; wall phones default to beside only in landscape (`.phone` + wall mode → sheet is still used; a wall phone is expected in landscape).
8. Ambient dimming proxy = screen brightness + night hours; macOS = night hours only.
9. Nearby caption texts for denied/unavailable states (§E.5).
10. Light-mode values for the nine palette entries and UI chrome not shown in MainLight (§C.2/§C.3) — tune lightness only.
11. Appearance default = dark (brief), with a system option.
12. The 3-line phone tap-to-promote is manual and sticky until another promotion or relaunch; automatic trunk changes resume after relaunch.
13. `Font.custom(_, fixedSize:)` for all map/wall text; `relativeTo: .body` for readout and setup text in hand mode only.

### H.4 Open risks (not resolvable from the inputs)

- iPhone-duo posture API surface at iOS 27 — handled by geometry only (§D.3).
- Whether `CTFontManagerRegisterFontsForURL` needs the `.ttf` at the bundle root vs `Fonts/` on macOS with the synchronized group — Task 3 checks both paths.
- `UIScreen.main.brightness` availability under scene-based apps in iOS 27 (deprecated-but-working historically). If unavailable, the time-of-day fallback remains; log once.
- bus.gov.il rate limiting (429 exists): 3 lines × 2 calls every 20–30 s per device is modest; back-off handles 429 like any error.
- Static-font name tables are verified; if Apple's font parser ever registers Archivo Black under family "Archivo" the PostScript-name path still works (that is why family names are never used).

---

## I. Ordered task list

Follows BRIEF §8 with the test target and font verification pulled to the front. Each task ends with a verification through `zcode`. Steps use `- [ ]`. Commit after every green task (`git init` first if the folder is not a repository — it currently is not; Task 1 does this).

### Task 1: Unit-test target + scheme + git

**Files:** Modify `BusBus.xcodeproj/project.pbxproj`, `BusBus.xcodeproj/xcshareddata/xcschemes/BusBus.xcscheme`; Create `BusBusTests/SmokeTests.swift`.
**Produces:** a `BusBusTests` target that `@testable import BusBus` and runs via `POST /api/test`.

- [ ] Step 1: `git init` in `~/Developer/BusBus`, add a `.gitignore` (`DerivedData/`, `xcuserdata/`, `.DS_Store`), commit "chore: baseline POC".
- [ ] Step 2: Edit `project.pbxproj` — add these objects (keep the existing 24-hex id style):

```
/* in PBXFileReference section */
		AA0000000000000000000011 /* BusBusTests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = BusBusTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };

/* in PBXFileSystemSynchronizedRootGroup section */
		AA0000000000000000000033 /* BusBusTests */ = { isa = PBXFileSystemSynchronizedRootGroup; path = BusBusTests; sourceTree = "<group>"; };

/* PBXGroup: main group children += AA0000000000000000000033; Products children += AA0000000000000000000011 */

/* new sections */
/* Begin PBXContainerItemProxy section */
		AA0000000000000000000046 /* PBXContainerItemProxy */ = { isa = PBXContainerItemProxy; containerPortal = AA0000000000000000000070 /* Project object */; proxyType = 1; remoteGlobalIDString = AA0000000000000000000040; remoteInfo = BusBus; };
/* End PBXContainerItemProxy section */
/* Begin PBXTargetDependency section */
		AA0000000000000000000045 /* PBXTargetDependency */ = { isa = PBXTargetDependency; target = AA0000000000000000000040 /* BusBus */; targetProxy = AA0000000000000000000046 /* PBXContainerItemProxy */; };
/* End PBXTargetDependency section */

/* in PBXNativeTarget section */
		AA0000000000000000000041 /* BusBusTests */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = AA0000000000000000000061 /* Build configuration list for PBXNativeTarget "BusBusTests" */;
			buildPhases = ( AA0000000000000000000052 /* Sources */, AA0000000000000000000021 /* Frameworks */, AA0000000000000000000053 /* Resources */ );
			buildRules = ( );
			dependencies = ( AA0000000000000000000045 /* PBXTargetDependency */ );
			fileSystemSynchronizedGroups = ( AA0000000000000000000033 /* BusBusTests */ );
			name = BusBusTests; productName = BusBusTests;
			productReference = AA0000000000000000000011 /* BusBusTests.xctest */;
			productType = "com.apple.product-type.bundle.unit-test";
		};

/* PBXProject: targets += AA0000000000000000000041; TargetAttributes += AA0000000000000000000041 = { CreatedOnToolsVersion = 27.0; TestTargetID = AA0000000000000000000040; }; */

/* build phases (same shape as the app's) */
		AA0000000000000000000052 /* Sources */ = { isa = PBXSourcesBuildPhase; files = ( ); };
		AA0000000000000000000021 /* Frameworks */ = { isa = PBXFrameworksBuildPhase; files = ( ); };
		AA0000000000000000000053 /* Resources */ = { isa = PBXResourcesBuildPhase; files = ( ); };

/* XCBuildConfiguration for the test target (Debug = AA…94, Release = AA…95; identical settings) */
		AA0000000000000000000094 /* Debug */ = { isa = XCBuildConfiguration; buildSettings = {
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.hayek.BusBusTests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = auto;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";
				SWIFT_APPROACHABLE_CONCURRENCY = YES;
				SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/BusBus.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/BusBus";
			}; name = Debug; };
		AA0000000000000000000061 /* Build configuration list for PBXNativeTarget "BusBusTests" */ = { isa = XCConfigurationList; buildConfigurations = ( AA0000000000000000000094 /* Debug */, AA0000000000000000000095 /* Release */ ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
```

- [ ] Step 3: Edit the scheme: add a second `BuildActionEntry` (buildForTesting YES, others NO) referencing `BlueprintIdentifier="AA0000000000000000000041" BuildableName="BusBusTests.xctest" BlueprintName="BusBusTests"`, and inside `<Testables>`:
```xml
<TestableReference skipped="NO" parallelizable="YES">
   <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="AA0000000000000000000041" BuildableName="BusBusTests.xctest" BlueprintName="BusBusTests" ReferencedContainer="container:BusBus.xcodeproj"/>
</TestableReference>
```
- [ ] Step 4: Create `BusBusTests/SmokeTests.swift`:
```swift
import Testing
@testable import BusBus
struct SmokeTests {
    @Test func appModuleIsImportable() { #expect(TransitProviders.all.count >= 3) }
}
```
- [ ] Step 5: `GET /api/schemes` (BusBus selected), `GET /api/destinations` (select My Mac), `POST /api/test`, `GET /api/test-results` → 1 test passed. If the project fails to load, `GET /api/build-errors` and fix the pbxproj syntax.
- [ ] Step 6: Commit "build: add BusBusTests target".

### Task 2: MapEngine types, fixtures, junction detector (TDD)

**Files:** Create `BusBus/MapEngine/MapEngineTypes.swift`, `MapScene.swift`, `MapFixtures.swift`, `JunctionDetector.swift`; Create `BusBusTests/MapEngine/JunctionDetectorTests.swift`.
- [ ] Step 1: Write the types exactly as §B.1 and the fixtures as §B.8.
- [ ] Step 2: Write all `JunctionDetectorTests` from §B.8. Run tests → FAIL (symbol missing).
- [ ] Step 3: Implement `JunctionDetector.junction` per §B.2. Run → PASS.
- [ ] Step 4: Commit "feat(engine): junction detection".

### Task 3: Fonts — registration, typed API, verification

**Files:** Create `BusBus/Design/Typography.swift`, `FontRegistrar.swift`; Modify `BusBusApp.swift`; Create `BusBusTests/Design/FontRegistrationTests.swift`.
- [ ] Step 1: Write `FontRegistrationTests.fontFilesAreInBundle` and `allSixFacesResolve` (§C.4). Run → FAIL.
- [ ] Step 2: Implement `BusFace`, `TypeStyle`, `Font.bus`, `busText`, `FontRegistrar` (§C.4). Call `FontRegistrar.registerBundledFonts()` in `BusBusApp.init`.
- [ ] Step 3: `POST /api/build`; then confirm the `.ttf` files are inside the built app: `find ~/Library/Developer/Xcode/DerivedData -path "*BusBus.app*" -name "Archivo-Black.ttf"`. If absent, the synchronized group did not treat `Resources/Fonts` as resources — fix by adding an explicit `PBXFileSystemSynchronizedBuildFileExceptionSet` is NOT needed for resources; instead check the folder is not excluded, then re-run.
- [ ] Step 4: Run tests → PASS (all six PostScript names round-trip). Commit "feat(design): bundled Archivo/Space Mono with verified registration".

### Task 4: RouteCompressor (TDD)
**Files:** Create `BusBus/MapEngine/RouteCompressor.swift`, `BusBusTests/MapEngine/RouteCompressorTests.swift`.
- [ ] Step 1: Tests from §B.8 → FAIL. Step 2: implement §B.3 → PASS. Step 3: commit.

### Task 5: MapMetrics, RailPath, MapLayoutEngine (TDD, landscape first)
**Files:** Create `MapMetrics.swift`, `RailPath.swift`, `MapLayoutEngine.swift`, tests `RailPathTests.swift`, `MapLayoutEngineTests.swift`.
- [ ] Step 1: `RailPathTests` → implement `RailPath` → PASS.
- [ ] Step 2: Landscape `MapLayoutEngineTests` (no-merge, Merge A/B/C, convergence, pucks, dimming, single, scale, wide canvas, bundle compression, pitch shrink) → implement §B.4/§B.5 for `.horizontal` → PASS.
- [ ] Step 3: Portrait tests (phone 2/3 lines, spines, pad, convergence) → add the vertical mapping → PASS.
- [ ] Step 4: `TrunkSelector` + tests → PASS. Commit "feat(engine): layout engine with merge scenarios".

### Task 6: Design tokens, palette, theme
**Files:** Create `DesignTokens.swift`, `LinePalette.swift`; tests `LinePaletteTests.swift`.
- [ ] Tests → implement §C.1–C.3, §C.6–C.7 → PASS → commit.

### Task 7: Seam extensions + mock provider + pattern cache
**Files:** Modify `TransitModels.swift`, `TransitProvider.swift`, `BusGovILProvider.swift`, `StrideProvider.swift`, `BusProgressService.swift`; Rewrite `MockTransitProvider.swift`; Create `Transit/Cache/RoutePatternCache.swift`.
- [ ] Step 1: §F.1 changes. Step 2: `POST /api/build` clean. Step 3: run the existing POC screen against the Mock (via Settings → Debug later; for now the POC root) and confirm 3 lines appear for HARBOR GATE. Commit.

### Task 8: Board models + BoardViewModel (TDD)
**Files:** Create `Board/BoardModels.swift`, `Board/BoardViewModel.swift`, `Persistence/SettingsStore.swift`; tests `BoardViewModelTests.swift`, `SettingsStoreTests.swift`.
- [ ] Tests from §F.3/§F.5 → implement → PASS → commit.

### Task 9: Landscape board — header, map, readout, dark, static data (Main, SingleLine)
**Files:** Create `BoardLayoutMode.swift` (+ `BoardLayoutModeTests.swift`), `BoardView.swift`, `HeaderView.swift`, `MapView.swift`, `MapRailsCanvas.swift`, `StopLabelsLayer.swift`, `BusPuckView.swift`, `LineBadgeView.swift`, `ReadoutView.swift`, `ThenCardView.swift`, `LiveIndicatorView.swift`, `ClockView.swift`; Modify `ContentView.swift` (RootView with a temporary hard-coded Mock configuration), Delete `Home/HomeView.swift`.
- [ ] Step 1: `BoardLayoutModeTests` → implement → PASS.
- [ ] Step 2: Build the views per §E.1/§E.2 with the Mock provider (`mock.scenario = main`).
- [ ] Step 3: `POST /api/run` on My Mac at 1280×720: compare against `Main.dc.html` opened in a browser at 1280×720 — rows at 70/190/310, node at 1190, dash captions "+4/+6/+9", pucks on rails, readout numerals in Archivo Black. Set `mock.scenario` to mergeA/B/C and compare with Merge1–3 (capsules 54/72 high, junction names white). Set 1 line → SingleLine. Resize the window wider → dash grows, nothing else moves.
- [ ] Step 4: Commit "feat(board): landscape map and readout".

### Task 10: Live data, countdown, refresh, stale
- [ ] Wire the polling loop, `TimelineView` countdown, LIVE/STALE, `NWPathMonitor`, `scenePhase`. Run with `bus.gov.il` on a real Israeli stop (e.g. code 41122, lines 112 …) and with the network toggled off → STALE after 90 s, last data kept. Commit.

### Task 11: Setup flow + persistence + location
**Files:** `Setup/*`, `Persistence/SettingsStore.swift` (done), pbxproj settings (`ENABLE_RESOURCE_ACCESS_LOCATION = YES`, `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription`), `RootView` routing, `SettingsView` rewrite.
- [ ] `LineSelectionTests` → implement §E.5/§E.6/§E.9/§F.6/§F.7 → run on iPhone simulator portrait + Mac: first launch shows setup, permission prompt, nearby list (Mock: 6 stops), pick 3 lines, SHOW THE MAP → board; relaunch → board directly. Commit.

### Task 12: Portrait layouts (phone 1/2/3 lines, iPad)
**Files:** `ReadoutPortraitView.swift`, phone/pad branches in `MapView`, terminus badges, promote-to-trunk.
- [ ] Run on iPhone simulator portrait with 1, 2, 3 mock lines → compare PhoneOneLine/TwoLines/Portrait (columns 195 / 110+195 / 59+127+195, names outside, spines unnamed, tap a spine badge → it becomes the centre with names). iPad simulator portrait → PadPortrait (167/417/667, THEN bar). Rotate both → landscape rules. iPad Split View 1/3 → phone rules. Verify Hebrew names on bus.gov.il data. Commit.

### Task 13: Light theme, tap-a-bus (swap + beside), BusDetail card
- [ ] Appearance setting → MainLight check (cream everywhere, ink numerals, THEN outline, MIN grey). Tap pucks in swap mode (kicker SELECTED BUS, THEN recomputes) and beside mode (card 540 wide, others dimmed, ring on tapped puck, X/Esc dismiss). Commit.

### Task 14: Wall mode behaviours + settings affordance + macOS window
- [ ] Implement §G and the macOS `WindowGroup` sizing/title-bar (§D.2). Verify: wall mode on → idle timer flag set (iOS) / `beginActivity` (macOS); drift visible after 3 min (temporarily set 5 s to observe, then restore 180 s); dimming overlay when simulator brightness slider < 0.25 or at night; tap anywhere → gear → fades after 4 s; Cmd+, on Mac. Commit.

### Task 15: Accessibility and final checks
- [ ] VoiceOver pass on iPhone: header, pucks ("Bus 41, 2 minutes away, 1 stop"), node, chips ("Line 41 to Vista Park, selected"), buttons. Dynamic Type at XXL in hand mode: readout and setup scale; map labels do not. Contrast spot-check of every added light-mode value (≥ 4.5:1 text, ≥ 3:1 rails). Confirm no hairlines, no gradients, no emoji glyphs, no SF display text (grep for `Font.system` and `Font.custom` outside `Typography.swift` — only the SettingsView `Form` may use system fonts). All tests green via `/api/test`. Commit "feat: BusBus 1.0 board".

---

## Self-review notes

- Spec coverage: §1 setup (Tasks 11), §2 map rules (Tasks 2–5, 9), readout (9–10), tap behaviours (13), §3 orientation (12, §D), §4 visual system (3, 6, 13), §5 data (7–8, 10), §6 wall (14), §7 accessibility (15), §8 order (kept, test target and fonts first), §9 platforms/seam (Global Constraints, §A.3).
- Type names are consistent across sections: `MapLayoutRequest`, `MapScene`, `MapLineInput`, `MapVehicleInput`, `JunctionResult`, `CompressedLine`, `TrunkSelector`, `BoardLayout`, `BoardViewModel`, `BoardArrival`, `BoardBus`, `SettingsStore`, `BoardConfiguration`, `BusFace`, `TypeStyle`, `Theme`, `LinePalette`, `LineColorAssigner`, `NearbyStop`.
