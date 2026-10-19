# BusBus — Apple Watch: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task is independently buildable and is committed on its own when green.

**Spec:** `docs/plans/watch-spec.md` (read it first; this plan does not repeat its rationale). Every open question in spec §12 is resolved by adopting its default, except where **§0.3** below says the code contradicts it.

**Goal:** a watchOS app (`BusBusWatch`) and a watch WidgetKit extension (`BusBusWatchWidget`) embedded in the iOS build of `BusBus`, showing the rider's saved stops and their next buses; saved setups and the phone's latest snapshots reach the watch over Watch Connectivity; the watch fetches arrivals itself through the existing `WidgetSupport/` path; no Firebase, no keys, no map on the watch.

**Tech:** Swift 5 language mode, `SWIFT_APPROACHABLE_CONCURRENCY = YES`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, SwiftUI, WidgetKit, AppIntents, WatchConnectivity, Swift Testing. No packages. `BusBus.xcodeproj/project.pbxproj` (`objectVersion = 90`, file-system synchronized groups) is edited by hand; there is no XcodeGen.

---

## 0. Ground truth (verified on this machine, 2026-09-24)

### 0.1 Toolchain, SDKs, simulators

- Xcode 27.0 (27A266a) at `/Applications/Xcode-27.0.0.app`. `xcodebuild -showsdks`: `iphoneos27.0`, `iphonesimulator27.0`, `macosx27.0`, `watchos27.0`, `watchsimulator27.0`.
- Available watch simulators (`xcrun simctl list devices available`):
  - **watchOS 27.0:** `Apple Watch Series 12 (46mm)`, `Apple Watch Series 12 (42mm)`, `Apple Watch Ultra 4 (49mm)`, `Apple Watch SE 3 (44mm)`, `Apple Watch SE 3 (40mm)`.
  - watchOS 26.5: `Apple Watch Series 11 (46mm/42mm)`, `Ultra 3 (49mm)`, `SE 3 (44mm/40mm)` — **unusable**: the project's `WATCHOS_DEPLOYMENT_TARGET = 27.0`. The spec's `Apple Watch Series 11 (46mm)` destination is therefore replaced everywhere below by `Apple Watch Series 12 (46mm),OS=27.0`.
- iPhone simulators on iOS 27.0: `iPhone 17 Pro`, `iPhone 17 Pro Max`, `iPhone 17`, `iPhone 17e`, `iPhone Air`, `iPhone 18 Pro`, `iPhone 18 Pro Max` (plus the script's `BusBus Shots iPhone` / `BusBus Render iPhone`).

Destinations used by every acceptance check in this plan:

```bash
IOS_SIM='platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0'
WATCH_SIM='platform=watchOS Simulator,name=Apple Watch Series 12 (46mm),OS=27.0'
DD=build/watch-plan           # derived data; build/ is gitignored
```

### 0.2 watchOS 27.0 SDK facts (checked in `WidgetKit.swiftmodule/arm64_32-apple-watchos.swiftinterface` and MapKit headers)

- `WidgetFamily.systemSmall/…/systemExtraLargePortrait` are `@available(watchOS, unavailable)`; `accessoryCorner` exists (unavailable on iOS/macOS/visionOS). Every mention of a system family in shared code must be fenced with `#if !os(watchOS)`; every mention of `.accessoryCorner` with `#if os(watchOS)`.
- `TimelineEntryRelevance`, `TimelineEntry.relevance`, `AccessoryWidgetBackground`, `View.widgetLabel(_:)`, `widgetAccentable`, `showsWidgetContainerBackground`, `WidgetRenderingMode`, `AppIntentConfiguration`, `WidgetRelevance` / `RelevanceConfiguration` (deferred, not used) all exist.
- `WatchConnectivity.framework`, `MapKit.framework` (`MKLocalSearch` is `watchos(1.0)`), `Compression`, `CoreLocation`, `AppIntents` are in the watchOS SDK. The widget's 75-file shared set compiles on watchOS without change except `WidgetSupport/NextBusEntry.swift` (`WidgetLayout.for` switches on system families).

### 0.3 Repo facts that change the spec

| Spec says | Code says | Plan does |
|---|---|---|
| `BusBusWidget/AppClock.swift` is the widget's clock and both watch targets compile it (§7.5) | The working tree has an **uncommitted** refactor: new `BusBus/Transit/AppClock.swift` (with `isStaging`, `frozenNow`, `now`), and `ScreenshotMode.swift` / `TransitCache.swift` modified to use it. `BusBusWidget/AppClock.swift` still exists and still defines `AppClock`. Neither `Transit/AppClock.swift` nor the widget's is in the widget exception set `AA…E3` yet (the widget builds because its own file is in its folder). | Task 0 settles this before anything else; the watch targets compile exactly one `AppClock` (see Task 0). |
| Destination `Apple Watch Series 11 (46mm)` | That device runs watchOS 26.5 here | `Apple Watch Series 12 (46mm),OS=27.0` |
| New strings: machine-translate and mark `needs_review` "as the widget strings were" (§5.5, §12 #11) | `Localizable.xcstrings` has 2364 localizations, **all** `translated`; none `needs_review` | Follow the catalog: `"state" : "translated"` plus a `comment` on each key naming it a watch string; English and Hebrew by hand, the other 16 machine-translated |
| `waitsForConnectivity = false` on the watch's session (§9) | `HTTPClient.session` is `URLSession.shared`, whose configuration already has `waitsForConnectivity == false`; per-request `timeoutInterval` is set in `HTTPClient` | No change; nothing to add |
| `WatchStopModel` refresh policy tested in `BusBusWatchTests` with a stub `TransitProvider` (§11) | `WidgetArrivalsFetcher` has no injection point for providers (spec §8 says "No change") | The decisions (fetch or not, reload complications or not) are pure functions in `BusBus/WatchSupport/WatchRefreshPolicy.swift`, tested in `BusBusTests`; `WatchStopModel` takes a `fetch` closure, so `BusBusWatchTests` stubs it without touching the fetcher |
| `WidgetHeader` "extract the shared piece rather than duplicate" (§5.3) | `WidgetHeader` lives in `BusBusWidget/Views/NextBusWidgetView.swift`, which the watch cannot compile (system families throughout) | Task 1 moves `WidgetHeader` verbatim into `BusBusWidget/Views/WidgetReadout.swift` (already in `BusBusTests`' widget exception set `AA…EE`, and in the watch sets) |
| `WKApplication = YES` in `Config/BusBusWatch-Info.plist` (§10) | `GENERATE_INFOPLIST_FILE = YES` merges `INFOPLIST_KEY_*` with `INFOPLIST_FILE` | Both: `INFOPLIST_KEY_WKApplication = YES` and `INFOPLIST_KEY_WKCompanionAppBundleIdentifier` as build settings; the plist carries only `CFBundleURLTypes` (as `Config/BusBus-Release-Info.plist` does) |

Everything else in spec §12 is adopted as written: bundle ids `com.hayek.BusBus.watchkitapp` / `.watchkitapp.BusBusWatchWidget`, the same App Group `group.com.hayek.BusBus`, `BUSBUS_WIDGET` kept as the compilation condition, no independent install, no Firebase on the watch, fetch timeout 10 s, entry relevance only, corner = line number + curved countdown, Always On keeps the numeral and hides the dot, six `.ttf` in each watch bundle, `busbus://setup?id=` deep link, `WCSession` only while the iOS app runs.

### 0.4 pbxproj conventions to mirror

- Ids are 24 hex characters; the hand-written ones are `AA` + zeros + a suffix (`AA00000000000000000000E3`). New ids in this plan: `AA00000000000000000000F0`–`FF` (watch app), `AA0000000000000000000100`–`010A` (watch widget), `AA0000000000000000000110`–`0113` (embedding in the iOS app), `AA0000000000000000000120`–`012A` (watch tests). Verify none exists before adding: `grep -c 'AA00000000000000000000F0' BusBus.xcodeproj/project.pbxproj` must print 0.
- Targets own one `PBXFileSystemSynchronizedRootGroup` each (`fileSystemSynchronizedGroups`). A target that does **not** own a folder gets files from it through a `PBXFileSystemSynchronizedBuildFileExceptionSet` listed in that folder's `exceptions`, whose `membershipExceptions` are the files **added** (this is how `AA…E3` gives `BusBusWidget` 75 files from `BusBus/`, and `AA…EE` gives `BusBusTests` six views from `BusBusWidget/`).
- The widget is embedded through `PBXCopyFilesBuildPhase` `AA…EC` (`dstSubfolderSpec = 13`, PlugIns) with a `PBXBuildFile` carrying `settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }` and a `PBXTargetDependency` + `PBXContainerItemProxy` pair.
- Build phases and copy phases omit `buildActionMask` / `runOnlyForDeploymentPostprocessing` (objectVersion 90 defaults); keep that.
- `Config/` holds plists and entitlements referenced by path from build settings; only three of them are in the `Config` `PBXGroup`, and the widget's are not — new ones need no group entry.
- Signing: `CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = Q7U5734Q3T; REGISTER_APP_GROUPS = YES;` on every product target; test bundles carry no team (as `BusBusTests`).
- `CURRENT_PROJECT_VERSION = 1` and `MARKETING_VERSION = 0.1` are project-level; product targets inherit them, so the watch app's version strings equal the iOS app's, which App Store submission requires. Do not set them per target.

### 0.5 Verification commands (the loop every task ends with)

```bash
cd ~/Developer/BusBus
# iOS: builds and (after Task 3) embeds the watch app.
xcodebuild -scheme BusBus -destination 'generic/platform=iOS Simulator' -derivedDataPath $DD -quiet build
# Mac: must stay untouched by the platform-filtered embed.
xcodebuild -scheme BusBus -destination 'platform=macOS' -derivedDataPath $DD -quiet build
# Unit tests, on the Mac (fast) and on the iPhone (the ImageRenderer fit tests are #if os(iOS)).
xcodebuild -scheme BusBus -destination 'platform=macOS' -derivedDataPath $DD -quiet test
xcodebuild -scheme BusBus -destination "$IOS_SIM" -derivedDataPath $DD -quiet test -only-testing:BusBusTests/WidgetLayoutFitTests
# Watch (from Task 3 on).
xcodebuild -scheme BusBusWatch -destination "$WATCH_SIM" -derivedDataPath $DD -quiet build
xcodebuild -scheme BusBusWatch -destination "$WATCH_SIM" -derivedDataPath $DD -quiet test   # from Task 7 on
```

The `zcode` skill may be used for the interactive loop, but the commands above are the acceptance record; paste their exit status into the commit message body when a task's check is non-obvious.

---

## 1. Task graph

| # | Task | Touches pbxproj | Depends on | Parallel with |
|---|---|---|---|---|
| 0 | Pre-flight: settle `AppClock`, baseline builds | maybe (E3 only) | — | — |
| 1 | Shared code made watchOS-safe: family guards, `WidgetHeader` move, `AccessoryCornerView`, relevance score | no | 0 | 2 |
| 2 | `BusBus/WatchSupport/`: payload, apply, refresh policy + `BusBusTests` | no | 0 | 1 |
| 3 | Xcode scaffolding: `BusBusWatch` + `BusBusWatchWidget` targets, embed, plists, entitlements, scheme, `@main` stubs | **yes** | 1, 2 | — (sequential) |
| 4 | Watch complications: widget, view, families, `widgetURL`, previews | no | 3 | 5, 6, 8 |
| 5 | Phone side: `WatchSync` sender, `SettingsStore` / `WidgetBridge` / `BusBusApp` hooks, telemetry | no | 2 (3 for the end-to-end check) | 4, 6, 8 |
| 6 | Watch app: receiver, store, `WatchStopModel`, stop list, board, environment, deep link, strings | no | 3 | 4, 5, 8 |
| 7 | `BusBusWatchTests` target + watch-hosted tests | **yes** | 4, 6 | — (sequential) |
| 8 | Fit tests for accessory sizes, complication PNGs, `screenshots.sh watch` | no | 1 (4 to see the real widget) | 4, 5, 6 |
| 9 | (Deferred, before the first watch release) App Store watch screenshots | no | 6, 7 | — |

Rules: **Tasks 3 and 7 are the only ones that edit `project.pbxproj`, and they run alone.** Tasks 1 and 2 may run at the same time (disjoint files). Tasks 4, 5, 6 and 8 may run at the same time: 4 writes only under `BusBusWatchWidget/` (+ `NextBusTimelineProvider.swift`, already touched by 1, so 4 must start after 1 is merged), 5 only under `BusBus/WatchSupport/WatchSync.swift`, `SettingsStore.swift`, `WidgetBridge.swift`, `BusBusApp.swift`, 6 only under `BusBusWatch/` + `Localizable.xcstrings`, 8 only under `BusBusTests/Widget/` + `scripts/screenshots.sh`. Each parallel worker commits its own task; the integrator rebuilds everything after merging (§8 checklist).

---

## 2. Tasks

### Task 0: Pre-flight — one `AppClock`, clean tree, baseline

**Files:** `BusBus/Transit/AppClock.swift` (untracked), `BusBusWidget/AppClock.swift`, `BusBus/Screenshots/ScreenshotMode.swift` (modified), `BusBus/Transit/Cache/TransitCache.swift` (modified), possibly `project.pbxproj` exception set `AA…E3`.
**Produces:** a committed tree in which exactly one `AppClock` definition is reachable from each of: the app, the widget, and (later) the watch targets.

- [ ] Step 1: `git status --short`. Expected today: `M ScreenshotMode.swift`, `M TransitCache.swift`, `?? BusBus/Transit/AppClock.swift`, `?? docs/plans/watch-spec.md`. If the tree is already clean and `BusBus/Transit/AppClock.swift` is tracked, skip to Step 4.
- [ ] Step 2: Decide with the user (one question, default below) how to land the refactor. **Default:** keep `BusBus/Transit/AppClock.swift` as the one definition — its `isStaging` reads `UserDefaults.standard` `"screenshot"`, so it is correct in any process — and:
  - add `Transit/AppClock.swift,` to `AA…E3`'s `membershipExceptions` (alphabetically after `Transit/Providers/WienerLinienProvider.swift,` and before `Transit/TransitProvider.swift,`; the list is sorted by path);
  - `git rm BusBusWidget/AppClock.swift`;
  - keep the `ScreenshotMode.swift` and `TransitCache.swift` edits as they are.
  If the user prefers to keep `BusBusWidget/AppClock.swift` instead, revert the three working-tree changes and delete the untracked file; then in Task 3 the watch exception sets list `AppClock.swift` under the `BusBusWidget` folder rather than `Transit/AppClock.swift` under `BusBus`. The plan below writes both variants where it matters, marked **[AppClock]**.
- [ ] Step 3: Commit: `Move the clock into the transit layer` (with the `docs/plans/watch-spec.md` in a separate `Add the Apple Watch spec` commit).
- [ ] Step 4: Baseline the three builds and the Mac test run (§0.5, first four commands, without the watch ones). All must pass before Task 1 starts; if any fails, stop and report — nothing in this plan fixes pre-existing failures.
- [ ] Step 5: `grep -c 'AA00000000000000000000F0\|AA0000000000000000000100\|AA0000000000000000000110\|AA0000000000000000000120' BusBus.xcodeproj/project.pbxproj` → `0`.

**Acceptance:** tree clean; §0.5 iOS build, Mac build, Mac tests green.

---

### Task 1: Shared code made watchOS-safe (no pbxproj)

**Files:** Modify `BusBus/WidgetSupport/NextBusEntry.swift`, `BusBus/WidgetSupport/WidgetTimelineMath.swift`, `BusBusWidget/NextBusTimelineProvider.swift`, `BusBusWidget/SelectSavedSetupIntent.swift`, `BusBusWidget/Views/AccessoryViews.swift`, `BusBusWidget/Views/WidgetReadout.swift`, `BusBusWidget/Views/NextBusWidgetView.swift`, `BusBusWidget/NextBusWidget.swift`, `BusBusTests/Widget/WidgetTimelineMathTests.swift`.
**Produces:** every file the watch targets will compile is free of `WidgetFamily.system*` outside `#if !os(watchOS)`; `AccessoryCornerView` exists and is measurable on iOS; the Smart Stack score is a tested pure function. iOS and Mac behaviour unchanged.

- [ ] Step 1: `NextBusEntry.swift` — `WidgetLayout.for(_:content:hasMap:)`: wrap the five `case (.system…)` arms in `#if !os(watchOS) … #endif`, leaving `let content = …`, the `switch (family, content) {`, and the `default:` arm outside. On watchOS the switch then has only `default`, which is what every accessory family gets today.
- [ ] Step 2: `WidgetTimelineMath.swift` — add the Smart Stack score (pure, shared, tested):

```swift
    /// How much the Smart Stack should care right now: 100 when the next bus is within 15 minutes,
    /// climbing as it nears; 20 when there are numbers but the bus is further out; nil with none.
    /// `secondsToNext` is the next upcoming arrival's `expectedAt - now`, or nil.
    static func relevanceScore(secondsToNext: TimeInterval?) -> Float? {
        guard let secondsToNext else { return nil }
        let near: TimeInterval = 15 * 60
        guard secondsToNext < near else { return 20 }
        // 100 at the door, 60 fifteen minutes out.
        return Float(60 + 40 * (1 - max(0, secondsToNext) / near))
    }
```

- [ ] Step 3: `NextBusTimelineProvider.swift` — in `entries(for:family:history:snapshot:now:)`, fence the family/largeContent reads:

```swift
        #if os(watchOS)
        let routes: WidgetRoutes? = nil
        let layout = WidgetLayout.for(family, content: .laterBuses, hasMap: false)
        #else
        let large = [.systemLarge, .systemExtraLarge, .systemExtraLargePortrait].contains(family)
        let routes = large && configuration.largeContent == .map ? chosen.flatMap { self.routes.load(setupID: $0.id) } : nil
        let layout = WidgetLayout.for(family, content: configuration.largeContent,
                                      hasMap: chosen.map { WidgetMap.canDraw($0, routes: routes) } ?? false)
        #endif
```

  and extend the `TimelineEntry` conformance at the top of the file:

```swift
extension NextBusEntry: TimelineEntry {
    #if os(watchOS)
    /// Smart Stack: surface the stop as its next bus draws near (`WidgetTimelineMath.relevanceScore`).
    var relevance: TimelineEntryRelevance? {
        guard state == .board, liveness != .expired else { return nil }
        let next = arrivals.first.map { $0.expectedAt.timeIntervalSince(date) }
        return WidgetTimelineMath.relevanceScore(secondsToNext: next).map { TimelineEntryRelevance(score: $0) }
    }
    #endif
}
```

  Note `var routes = WidgetRouteStore()` stays a stored property (compiled, unused on watchOS).
- [ ] Step 4: `SelectSavedSetupIntent.swift` — the `largeContent` parameter under `#if !os(watchOS)`; keep `init() {}` and the `LargeWidgetContent: AppEnum` extension unconditional.
- [ ] Step 5: `AccessoryViews.swift` — change `#if os(iOS)` to `#if os(iOS) || os(watchOS)` and add, before the closing `#endif`:

```swift
/// Watch corner: the line number in the corner, the countdown curved along the bezel as the
/// label; with nothing due, the bus glyph and the stop's name. The label is a watch-only modifier,
/// so the struct compiles on iOS (where the fit tests measure it) without one.
struct AccessoryCornerView: View {
    var entry: NextBusEntry

    var body: some View {
        content
            #if os(watchOS)
            .widgetLabel { Text(verbatim: label) }
            #endif
    }

    @ViewBuilder private var content: some View {
        if let arrival = entry.arrivals.first {
            Text(verbatim: entry.line(for: arrival)?.shortName ?? arrival.lineID)
                .busText(TypeStyle(.archivoBlack, 22, tracking: -0.02))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .widgetAccentable()
        } else {
            Image(systemName: "bus.fill").font(.system(size: 20, weight: .bold))
        }
    }

    /// "4 MIN", "NOW", "1:15 HR", or the stop's name when nothing is due.
    var label: String {
        guard let arrival = entry.arrivals.first else {
            return entry.setup?.stop.name ?? String(appLocalized: WidgetMessage(entry)?.title ?? "NO BUSES DUE")
        }
        let board = arrival.board
        if board.isImminent(at: entry.date) { return String(appLocalized: "NOW") }
        let countdown = board.countdown(at: entry.date)
        return "\(countdown.figure) " + String(appLocalized: countdown.isHours ? "HR" : "MIN")
    }
}
```

  (`WidgetMessage.title` is a `LocalizedStringKey`; if `String(appLocalized:)` will not take it, build the fallback with a small `switch` on `WidgetMessage` — keep the existing keys.) `label` is internal, not private, so Task 8's fit test can measure it as a `Text` on iOS.
- [ ] Step 6: Move `struct WidgetHeader` (currently `NextBusWidgetView.swift` lines ~55–92, including its `caption(for:)`) verbatim into `WidgetReadout.swift`, after `WidgetMinutes`. Nothing else changes; `NextBusWidgetView.swift` keeps its `// MARK: Small` and every use.
- [ ] Step 7: `NextBusWidget.swift` — no functional change; confirm `families` stays `#if os(iOS)` for the accessory trio (the iOS widget never lists `.accessoryCorner`).
- [ ] Step 8: Tests, in `WidgetTimelineMathTests.swift`:

```swift
    @Test func relevanceRisesAsTheBusNears() {
        #expect(WidgetTimelineMath.relevanceScore(secondsToNext: nil) == nil)
        #expect(WidgetTimelineMath.relevanceScore(secondsToNext: 40 * 60) == 20)
        let far = WidgetTimelineMath.relevanceScore(secondsToNext: 14 * 60)!
        let near = WidgetTimelineMath.relevanceScore(secondsToNext: 2 * 60)!
        let now = WidgetTimelineMath.relevanceScore(secondsToNext: 0)!
        #expect(far > 20 && far < near && near < now && now == 100)
        #expect(WidgetTimelineMath.relevanceScore(secondsToNext: -20) == 100)
    }
```

**Acceptance:** §0.5 iOS build, Mac build, Mac tests, and `-only-testing:BusBusTests/WidgetLayoutFitTests` on `$IOS_SIM` all green (the header move must not change any measured size). Commit: `Fence the system widget families so the widget code compiles for watchOS`.

---

### Task 2: `BusBus/WatchSupport/` — payload, apply, refresh policy, tests (no pbxproj)

**Files:** Create `BusBus/WatchSupport/WatchSyncPayload.swift`, `BusBus/WatchSupport/WatchSyncApply.swift`, `BusBus/WatchSupport/WatchRefreshPolicy.swift`, `BusBusTests/Watch/WatchSyncPayloadTests.swift`, `BusBusTests/Watch/WatchSyncApplyTests.swift`, `BusBusTests/Watch/WatchRefreshPolicyTests.swift`.
**Produces:** the sync contract and every decision the watch makes, compiled into the app by the synchronized `BusBus` folder (no pbxproj edit) and tested from `BusBusTests`. Nothing here imports WatchConnectivity or WidgetKit.

- [ ] Step 1: `WatchSyncPayload.swift`:

```swift
import Foundation

/// What the iPhone sends the watch over Watch Connectivity: the history and what it takes to draw
/// it. Latest state wins (`WCSession.updateApplicationContext`), so it is whole, never a diff.
nonisolated struct WatchSyncPayload: Codable, Hashable, Sendable {
    static let currentVersion = 1
    /// The key under which the encoded payload sits in the application context dictionary.
    static let contextKey = "payload"
    /// A full payload (8 setups × 3 lines, 8 snapshots × ~10 arrivals) is a few KB; this is the
    /// ceiling a test holds it under so a new field cannot outgrow the context quietly.
    static let encodedSizeCap = 64 * 1024

    var version: Int = currentVersion
    var sentAt: Date
    /// `SavedSetups.sorted`, at most `SavedSetups.limit`.
    var history: [SavedSetup]
    var palette: [String: Int]
    var appearance: Appearance
    var language: String?
    /// Nil until the app has mirrored the remote switches — `SharedKeys.disabledProviders`'s meaning.
    var disabledProviders: [String]?
    /// The newest usable snapshot per setup in `history`.
    var snapshots: [WidgetSnapshot]

    /// Builds the payload the phone sends: history capped and sorted, and only snapshots that are
    /// still usable at `now` (`WidgetTimelineMath.liveness != .expired`) for setups in the history.
    static func make(history: [SavedSetup], palette: [String: Int], appearance: Appearance, language: String?,
                     disabledProviders: Set<String>?, snapshot: (String) -> WidgetSnapshot?, now: Date) -> WatchSyncPayload

    func encoded() throws -> Data          // JSONEncoder, .iso8601 dates
    /// Nil for a payload this build does not read (`version != currentVersion`) or bad data.
    static func decode(_ data: Data) -> WatchSyncPayload?
}
```

- [ ] Step 2: `WatchSyncApply.swift` — the pure "write a payload into these stores" step, keyed exactly as the phone writes (`SharedHistoryStore.save(_:at:)`, `SharedKeys.palette/appearance/language/disabledProviders`, `WidgetSnapshotStore.save/prune`, `WidgetRouteStore.prune`):

```swift
import Foundation

/// Applies a synced payload to the watch's own App Group, writing the very keys the phone writes,
/// so every `WidgetSupport` reader is unchanged. Injectable stores, so tests use throwaway ones.
nonisolated struct WatchSyncApply: Sendable {
    nonisolated(unsafe) var defaults: UserDefaults = AppGroup.defaults
    var snapshots = WidgetSnapshotStore()
    var routes = WidgetRouteStore()

    enum Outcome: Hashable, Sendable { case applied, olderThanStored, unreadable }

    /// Ignores a payload older than the history already stored (`SharedHistoryStore.savedAt`).
    /// Snapshots replace stored ones only when newer (`fetchedAt`). Prunes snapshots and routes of
    /// setups no longer in the history.
    @discardableResult
    func apply(_ payload: WatchSyncPayload) -> Outcome
    func apply(contextData data: Data) -> Outcome      // decode + apply
}
```

  Also add to `AppGroup.swift`'s `SharedHistoryStore` (small, tested):

```swift
    /// The phone's mirror of colours, appearance, language and switches, written together.
    func writeMirror(palette: [String: Int], appearance: Appearance, language: String?, disabledProviders: [String]?)
```

- [ ] Step 3: `WatchRefreshPolicy.swift` — the watch app's decisions as pure functions (the constants come from the code already there):

```swift
import Foundation

/// When the watch app fetches for itself and when it asks WidgetKit to redraw the complications.
/// The widget's own rules, restated for a process that stays in front.
nonisolated enum WatchRefreshPolicy {
    /// Numbers newer than this are not worth a request (`NextBusTimelineProvider.refetchAfter`).
    static let refetchAfter: TimeInterval = 60
    /// Complications are redrawn at most this often while the app is in front (`WidgetBridge.reloadInterval`).
    static let reloadInterval: TimeInterval = 3 * 60

    static func shouldFetch(snapshot: WidgetSnapshot?, now: Date) -> Bool
    static func shouldReloadComplications(lastReload: Date?, now: Date) -> Bool
    /// The provider's `refreshInterval` (20–30 s), or 30 s when the setup has no provider the watch may call.
    static func pollInterval(for provider: (any TransitProvider)?) -> Duration
}
```

- [ ] Step 4: Tests, following `SharedHistoryStoreTests` (a throwaway `UserDefaults(suiteName:)` per test) and `WidgetSnapshotTests` (a temp directory per test):
  - `WatchSyncPayloadTests`: round trip through `encoded()`/`decode`; `version: 2` decodes to nil; `make` caps at `SavedSetups.limit` and sorts pinned first; only usable snapshots are included and only for setups in the history; a full payload (8 setups × 3 lines with `providerRefs`-sized `TransitLine`s, 8 snapshots × 12 arrivals) encodes under `encodedSizeCap`.
  - `WatchSyncApplyTests`: after `apply`, `SharedHistoryStore(defaults:).load()`, `.savedAt()`, `.paletteAssignments()`, `.appearance()`, `.disabledProviders()` and `AppLanguage`'s key (`defaults.string(forKey: SharedKeys.language)`) return the payload's values; a snapshot older than the stored one is not written, a newer one is; `sentAt` older than `savedAt()` → `.olderThanStored` and nothing changes; removed setups' snapshot and route files are pruned; garbage data → `.unreadable`; `disabledProviders: nil` removes the key.
  - `WatchRefreshPolicyTests`: nil snapshot → fetch; 30 s old → no fetch; 61 s → fetch; reload: nil → yes, 2 min → no, 3 min → yes; `pollInterval` clamps to 20…30 s and is 30 s for nil.

**Acceptance:** §0.5 Mac build + Mac tests green (`-only-testing:BusBusTests/WatchSyncPayloadTests -only-testing:BusBusTests/WatchSyncApplyTests -only-testing:BusBusTests/WatchRefreshPolicyTests` first, then the whole suite); iOS build green. Commit: `Add the watch sync payload and how the watch applies it`.

---

### Task 3: Xcode scaffolding — two watch targets, embedding, config, scheme, `@main` stubs (pbxproj, sequential)

**Files:** Modify `BusBus.xcodeproj/project.pbxproj`. Create `BusBus.xcodeproj/xcshareddata/xcschemes/BusBusWatch.xcscheme`, `Config/BusBusWatch-Info.plist`, `Config/BusBusWatchWidget-Info.plist`, `Config/BusBusWatch.entitlements`, `Config/BusBusWatchWidget.entitlements`, `BusBusWatch/BusBusWatchApp.swift`, `BusBusWatchWidget/BusBusWatchWidgetBundle.swift`, `BusBusWatchWidget/WatchNextBusWidget.swift` (minimal).
**Produces:** `xcodebuild -scheme BusBusWatch` builds the watch app with its widget inside; `xcodebuild -scheme BusBus` for iOS embeds `Watch/BusBusWatch.app`; the Mac build does not. Later tasks only add Swift files under the new folders.

- [ ] Step 1: Create the folders and the minimum sources, so the synchronized groups have something to compile:

`BusBusWatch/BusBusWatchApp.swift`
```swift
import SwiftUI

@main struct BusBusWatchApp: App {
    init() {
        // Its own process and bundle: the phone's registration does not reach it.
        FontRegistrar.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            Text("STOPS")   // Task 6 replaces this with the root view.
        }
    }
}
```

`BusBusWatchWidget/BusBusWatchWidgetBundle.swift`
```swift
import SwiftUI
import WidgetKit

@main struct BusBusWatchWidgetBundle: WidgetBundle {
    init() { FontRegistrar.registerBundledFonts() }
    var body: some Widget { WatchNextBusWidget() }
}
```

`BusBusWatchWidget/WatchNextBusWidget.swift` (Task 4 finishes it; this much must compile now)
```swift
import SwiftUI
import WidgetKit

struct WatchNextBusWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.nextBus, intent: SelectSavedSetupIntent.self,
                               provider: NextBusTimelineProvider()) { entry in
            AccessoryRectangularView(entry: entry).modifier(WidgetEnvironment(appearance: entry.appearance))
        }
        .configurationDisplayName("Next bus")
        .description("The next arrivals at a stop from your history.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
```

- [ ] Step 2: `Config/` files.

`Config/BusBusWatch-Info.plist` — a copy of `Config/BusBus-Release-Info.plist` (the `CFBundleURLTypes` for `busbus`, `CFBundleURLName` `com.hayek.BusBus.watchkitapp`), comment: the complication's tap (`WidgetDeepLink`) lands here.
`Config/BusBusWatchWidget-Info.plist` — a copy of `Config/BusBusWidget-Info.plist` (`NSExtension` → `com.apple.widgetkit-extension`).
`Config/BusBusWatch.entitlements` and `Config/BusBusWatchWidget.entitlements` — a copy of `Config/BusBusWidget.entitlements` (`com.apple.security.application-groups` = `[group.com.hayek.BusBus]`), comments adjusted ("the watch's own container, shared by its app and complications; filled by WatchSyncReceiver"). **No** `appattest-environment` key on the watch.

- [ ] Step 3: `project.pbxproj` — add the objects below, section by section, keeping each section's alphabetical/ordered style. Replace `[AppClock]` lines per Task 0's outcome.

```
/* PBXBuildFile section — append */
		AA00000000000000000000F9 /* BusBusWatchWidget.appex in Embed Foundation Extensions */ = {isa = PBXBuildFile; fileRef = AA0000000000000000000101 /* BusBusWatchWidget.appex */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };
		AA00000000000000000000FF /* Icon.icon in Resources */ = {isa = PBXBuildFile; fileRef = 292D629730644FE700210F18 /* Icon.icon */; };
		AA0000000000000000000111 /* BusBusWatch.app in Embed Watch Content */ = {isa = PBXBuildFile; fileRef = AA00000000000000000000F1 /* BusBusWatch.app */; platformFilters = (ios, ); settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };

/* PBXContainerItemProxy section — append */
		AA00000000000000000000FA /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = AA0000000000000000000070 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = AA0000000000000000000100;
			remoteInfo = BusBusWatchWidget;
		};
		AA0000000000000000000112 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = AA0000000000000000000070 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = AA00000000000000000000F0;
			remoteInfo = BusBusWatch;
		};

/* PBXCopyFilesBuildPhase section — append */
		AA00000000000000000000F8 /* Embed Foundation Extensions */ = {
			isa = PBXCopyFilesBuildPhase;
			dstPath = "";
			dstSubfolderSpec = 13;
			files = (
				AA00000000000000000000F9 /* BusBusWatchWidget.appex in Embed Foundation Extensions */,
			);
			name = "Embed Foundation Extensions";
		};
		AA0000000000000000000110 /* Embed Watch Content */ = {
			isa = PBXCopyFilesBuildPhase;
			dstPath = "$(CONTENTS_FOLDER_PATH)/Watch";
			dstSubfolderSpec = 16;
			files = (
				AA0000000000000000000111 /* BusBusWatch.app in Embed Watch Content */,
			);
			name = "Embed Watch Content";
		};

/* PBXFileReference section — append */
		AA00000000000000000000F1 /* BusBusWatch.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = BusBusWatch.app; sourceTree = BUILT_PRODUCTS_DIR; };
		AA0000000000000000000101 /* BusBusWatchWidget.appex */ = {isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = BusBusWatchWidget.appex; sourceTree = BUILT_PRODUCTS_DIR; };

/* PBXFileSystemSynchronizedBuildFileExceptionSet section — append two sets on "BusBus" and two on "BusBusWidget" */
		AA00000000000000000000F3 /* Exceptions for "BusBus" folder in "BusBusWatch" target */ = {
			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
			membershipExceptions = (
				<the 75 entries of AA00000000000000000000E3, verbatim and in the same order>
				[AppClock: if Task 0 kept BusBus/Transit/AppClock.swift, E3 now contains Transit/AppClock.swift — copy it with the rest]
				WatchSupport/WatchRefreshPolicy.swift,
				WatchSupport/WatchSyncApply.swift,
				WatchSupport/WatchSyncPayload.swift,
			);
			target = AA00000000000000000000F0 /* BusBusWatch */;
		};
		AA0000000000000000000103 /* Exceptions for "BusBus" folder in "BusBusWatchWidget" target */ = {
			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
			membershipExceptions = (
				<identical list to AA00000000000000000000F3>
			);
			target = AA0000000000000000000100 /* BusBusWatchWidget */;
		};
		AA00000000000000000000F4 /* Exceptions for "BusBusWidget" folder in "BusBusWatch" target */ = {
			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
			membershipExceptions = (
				[AppClock: AppClock.swift,   — only if Task 0 kept BusBusWidget/AppClock.swift]
				NextBusTimelineProvider.swift,
				SavedSetupEntity.swift,
				SelectSavedSetupIntent.swift,
				Views/AccessoryViews.swift,
				Views/WidgetReadout.swift,
				Views/WidgetStates.swift,
				Views/WidgetTheme.swift,
				WidgetArrivalsFetcher.swift,
			);
			target = AA00000000000000000000F0 /* BusBusWatch */;
		};
		AA0000000000000000000104 /* Exceptions for "BusBusWidget" folder in "BusBusWatchWidget" target */ = {
			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
			membershipExceptions = (
				<identical list to AA00000000000000000000F4>
			);
			target = AA0000000000000000000100 /* BusBusWatchWidget */;
		};
```

  `WatchSupport/WatchSync.swift` (Task 5, iOS-only) is deliberately **not** in the watch sets. `NextBusWidgetView.swift`, `WidgetMapView.swift`, `Previews.swift`, `NextBusWidget.swift`, `BusBusWidgetBundle.swift` are **not** in them.

```
/* PBXFileSystemSynchronizedRootGroup section — extend the two existing groups' exceptions, append three groups */
		AA0000000000000000000031 /* BusBus */ = {
			...
			exceptions = (
				AA00000000000000000000E3 /* Exceptions for "BusBus" folder in "BusBusWidget" target */,
				AA00000000000000000000F3 /* Exceptions for "BusBus" folder in "BusBusWatch" target */,
				AA0000000000000000000103 /* Exceptions for "BusBus" folder in "BusBusWatchWidget" target */,
			);
			...
		AA00000000000000000000E2 /* BusBusWidget */ = {
			...
			exceptions = (
				AA00000000000000000000EE /* Exceptions for "BusBusWidget" folder in "BusBusTests" target */,
				AA00000000000000000000F4 /* Exceptions for "BusBusWidget" folder in "BusBusWatch" target */,
				AA0000000000000000000104 /* Exceptions for "BusBusWidget" folder in "BusBusWatchWidget" target */,
			);
			...
		AA00000000000000000000F2 /* BusBusWatch */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = BusBusWatch;
			sourceTree = "<group>";
		};
		AA0000000000000000000102 /* BusBusWatchWidget */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = BusBusWatchWidget;
			sourceTree = "<group>";
		};

/* PBXFrameworksBuildPhase section — append (empty, like AA…E5: Swift autolinks SwiftUI/WidgetKit/WatchConnectivity from imports) */
		AA00000000000000000000F6 /* Frameworks */ = { isa = PBXFrameworksBuildPhase; files = ( ); };
		AA0000000000000000000106 /* Frameworks */ = { isa = PBXFrameworksBuildPhase; files = ( ); };

/* PBXGroup section — main group children: insert after AA00000000000000000000E2 */
				AA00000000000000000000F2 /* BusBusWatch */,
				AA0000000000000000000102 /* BusBusWatchWidget */,
/* Products children: append */
				AA00000000000000000000F1 /* BusBusWatch.app */,
				AA0000000000000000000101 /* BusBusWatchWidget.appex */,

/* PBXNativeTarget section — modify BusBus (AA…40): */
			buildPhases = (
				AA0000000000000000000050 /* Sources */,
				AA0000000000000000000020 /* Frameworks */,
				AA0000000000000000000051 /* Resources */,
				AA00000000000000000000EC /* Embed Foundation Extensions */,
				AA0000000000000000000110 /* Embed Watch Content */,
				AA00000000000000000000C0 /* Upload Crashlytics Symbols */,
			);
			dependencies = (
				AA00000000000000000000EB /* PBXTargetDependency */,
				AA0000000000000000000113 /* PBXTargetDependency */,
			);
/* — append two targets */
		AA00000000000000000000F0 /* BusBusWatch */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = AA00000000000000000000FC /* Build configuration list for PBXNativeTarget "BusBusWatch" */;
			buildPhases = (
				AA00000000000000000000F5 /* Sources */,
				AA00000000000000000000F6 /* Frameworks */,
				AA00000000000000000000F7 /* Resources */,
				AA00000000000000000000F8 /* Embed Foundation Extensions */,
			);
			buildRules = (
			);
			dependencies = (
				AA00000000000000000000FB /* PBXTargetDependency */,
			);
			fileSystemSynchronizedGroups = (
				AA00000000000000000000F2 /* BusBusWatch */,
			);
			name = BusBusWatch;
			productName = BusBusWatch;
			productReference = AA00000000000000000000F1 /* BusBusWatch.app */;
			productType = "com.apple.product-type.application";
		};
		AA0000000000000000000100 /* BusBusWatchWidget */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = AA0000000000000000000108 /* Build configuration list for PBXNativeTarget "BusBusWatchWidget" */;
			buildPhases = (
				AA0000000000000000000105 /* Sources */,
				AA0000000000000000000106 /* Frameworks */,
				AA0000000000000000000107 /* Resources */,
			);
			buildRules = (
			);
			fileSystemSynchronizedGroups = (
				AA0000000000000000000102 /* BusBusWatchWidget */,
			);
			name = BusBusWatchWidget;
			productName = BusBusWatchWidget;
			productReference = AA0000000000000000000101 /* BusBusWatchWidget.appex */;
			productType = "com.apple.product-type.app-extension";
		};

/* PBXProject section — TargetAttributes += */
					AA00000000000000000000F0 = {
						CreatedOnToolsVersion = 27.0;
					};
					AA0000000000000000000100 = {
						CreatedOnToolsVersion = 27.0;
					};
/* targets += */
				AA00000000000000000000F0 /* BusBusWatch */,
				AA0000000000000000000100 /* BusBusWatchWidget */,

/* PBXResourcesBuildPhase section — append */
		AA00000000000000000000F7 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			files = (
				AA00000000000000000000FF /* Icon.icon in Resources */,
			);
		};
		AA0000000000000000000107 /* Resources */ = { isa = PBXResourcesBuildPhase; files = ( ); };

/* PBXSourcesBuildPhase section — append */
		AA00000000000000000000F5 /* Sources */ = { isa = PBXSourcesBuildPhase; files = ( ); };
		AA0000000000000000000105 /* Sources */ = { isa = PBXSourcesBuildPhase; files = ( ); };

/* PBXTargetDependency section — append */
		AA00000000000000000000FB /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = AA0000000000000000000100 /* BusBusWatchWidget */;
			targetProxy = AA00000000000000000000FA /* PBXContainerItemProxy */;
		};
		AA0000000000000000000113 /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			platformFilters = (
				ios,
			);
			target = AA00000000000000000000F0 /* BusBusWatch */;
			targetProxy = AA0000000000000000000112 /* PBXContainerItemProxy */;
		};

/* XCBuildConfiguration section — append four (Debug/Release identical per target) */
		AA00000000000000000000FD /* Debug configuration for PBXNativeTarget "BusBusWatch" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = Icon;
				CODE_SIGN_ENTITLEMENTS = Config/BusBusWatch.entitlements;
				CODE_SIGN_STYLE = Automatic;
				DEVELOPMENT_TEAM = Q7U5734Q3T;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = "Config/BusBusWatch-Info.plist";
				INFOPLIST_KEY_CFBundleDisplayName = "My Bus Stop";
				INFOPLIST_KEY_UISupportedInterfaceOrientations = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown";
				INFOPLIST_KEY_WKApplication = YES;
				INFOPLIST_KEY_WKCompanionAppBundleIdentifier = com.hayek.BusBus;
				INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp = NO;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				PRODUCT_BUNDLE_IDENTIFIER = com.hayek.BusBus.watchkitapp;
				PRODUCT_NAME = "$(TARGET_NAME)";
				REGISTER_APP_GROUPS = YES;
				SDKROOT = watchos;
				SKIP_INSTALL = YES;
				STRING_CATALOG_GENERATE_SYMBOLS = YES;
				SUPPORTED_PLATFORMS = "watchos watchsimulator";
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "BUSBUS_WIDGET $(inherited)";
				SWIFT_APPROACHABLE_CONCURRENCY = YES;
				SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = 4;
				WATCHOS_DEPLOYMENT_TARGET = 27.0;
			};
			name = Debug;
		};
		AA00000000000000000000FE /* Release configuration for PBXNativeTarget "BusBusWatch" */ = { same buildSettings; name = Release; };
		AA0000000000000000000109 /* Debug configuration for PBXNativeTarget "BusBusWatchWidget" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_ENTITLEMENTS = Config/BusBusWatchWidget.entitlements;
				CODE_SIGN_STYLE = Automatic;
				DEVELOPMENT_TEAM = Q7U5734Q3T;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = "Config/BusBusWatchWidget-Info.plist";
				INFOPLIST_KEY_CFBundleDisplayName = "My Bus Stop";
				INFOPLIST_KEY_NSHumanReadableCopyright = "";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
					"@executable_path/../../Frameworks",
				);
				PRODUCT_BUNDLE_IDENTIFIER = com.hayek.BusBus.watchkitapp.BusBusWatchWidget;
				PRODUCT_NAME = "$(TARGET_NAME)";
				REGISTER_APP_GROUPS = YES;
				SDKROOT = watchos;
				SKIP_INSTALL = YES;
				STRING_CATALOG_GENERATE_SYMBOLS = YES;
				SUPPORTED_PLATFORMS = "watchos watchsimulator";
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "BUSBUS_WIDGET $(inherited)";
				SWIFT_APPROACHABLE_CONCURRENCY = YES;
				SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = 4;
				WATCHOS_DEPLOYMENT_TARGET = 27.0;
			};
			name = Debug;
		};
		AA000000000000000000010A /* Release configuration for PBXNativeTarget "BusBusWatchWidget" */ = { same; name = Release; };

/* XCConfigurationList section — append */
		AA00000000000000000000FC /* Build configuration list for PBXNativeTarget "BusBusWatch" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				AA00000000000000000000FD /* Debug configuration for PBXNativeTarget "BusBusWatch" */,
				AA00000000000000000000FE /* Release configuration for PBXNativeTarget "BusBusWatch" */,
			);
			defaultConfigurationName = Release;
		};
		AA0000000000000000000108 /* Build configuration list for PBXNativeTarget "BusBusWatchWidget" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				AA0000000000000000000109 /* Debug configuration for PBXNativeTarget "BusBusWatchWidget" */,
				AA000000000000000000010A /* Release configuration for PBXNativeTarget "BusBusWatchWidget" */,
			);
			defaultConfigurationName = Release;
		};
```

  Deliberately absent from the watch configs: `baseConfigurationReference` (no `Debug.xcconfig`, so no `Secrets.xcconfig` and no keys), `ENABLE_APP_SANDBOX`/`ENABLE_*_NETWORK_CONNECTIONS` (macOS-only), `OTHER_LDFLAGS -ObjC` (Firebase's), any `packageProductDependencies`.

- [ ] Step 4: Sanity-parse: `plutil -lint BusBus.xcodeproj/project.pbxproj` and `xcodebuild -list -json | python3 -c 'import json,sys; t=json.load(sys.stdin)["project"]["targets"]; assert "BusBusWatch" in t and "BusBusWatchWidget" in t; print(t)'`.
- [ ] Step 5: `BusBus.xcodeproj/xcshareddata/xcschemes/BusBusWatch.xcscheme` — copy `BusBus.xcscheme` and change: both `BuildActionEntry` references → `BlueprintIdentifier = "AA00000000000000000000F0"`, `BuildableName = "BusBusWatch.app"`, `BlueprintName = "BusBusWatch"`; delete the `BusBusTests` build entry and the `<Testables>` content for now (Task 7 adds `BusBusWatchTests`, id `AA0000000000000000000120`, `BusBusWatchTests.xctest`); `LaunchAction`/`ProfileAction` runnables → the watch app; drop `allowLocationSimulation`. Keep `LastUpgradeVersion = "2700"`.
- [ ] Step 6: Build the watch scheme and the iOS scheme (§0.5). Then inspect the products:

```bash
P=$DD/Build/Products
ls "$P/Debug-watchsimulator/BusBusWatch.app/PlugIns/BusBusWatchWidget.appex" >/dev/null && echo "widget embedded in watch app"
ls "$P/Debug-iphonesimulator/BusBus.app/Watch/BusBusWatch.app" >/dev/null && echo "watch app embedded in iOS app"
plutil -p "$P/Debug-iphonesimulator/BusBus.app/Watch/BusBusWatch.app/Info.plist" | grep -E 'WKApplication|WKCompanionAppBundleIdentifier|CFBundleIdentifier|CFBundleURLSchemes|CFBundleShortVersionString'
plutil -p "$P/Debug-iphonesimulator/BusBus.app/Info.plist" | grep CFBundleShortVersionString   # must equal the watch app's
ls "$P/Debug-watchsimulator/BusBusWatch.app/" | grep -c '\.ttf$'      # 6 (or in a Fonts/ subfolder: FontRegistrar looks in both)
ls "$P/Debug-watchsimulator/BusBusWatch.app/PlugIns/BusBusWatchWidget.appex/" | grep -c '\.ttf$'   # 6
ls "$P/Debug-watchsimulator/BusBusWatch.app/" | grep -E 'lproj|Localizable' | head   # the catalog compiled in
! ls "$P/Debug-watchsimulator/BusBusWatch.app/GoogleService-Info.plist" 2>/dev/null && echo "no Firebase config on the watch"
! strings "$P/Debug-watchsimulator/BusBusWatch.app/BusBusWatch" | grep -qi firebase && echo "no Firebase symbols"
! plutil -p "$P/Debug-watchsimulator/BusBusWatch.app/Info.plist" | grep -q BusBusAPIKeys && echo "no API keys"
```

  And the Mac build, then: `! test -e "$P/Debug/BusBus.app/Contents/Watch" && echo "Mac build has no Watch folder"`.
- [ ] Step 7: Icon check: `ls "$P/Debug-watchsimulator/BusBusWatch.app/" | grep -i 'Assets.car\|AppIcon'` and `plutil -p …/Info.plist | grep -i icon`. If Icon Composer produced no watch icon (build warning "no app icon set" or nothing in the plist), add `BusBusWatch/Assets.xcassets` with an `AppIcon.appiconset` (watchOS, single 1024 image exported from `Icon.icon`) and set `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` for the watch app; the synchronized folder picks the catalog up without a pbxproj change.
- [ ] Step 8: Run the app once on the watch simulator to prove launch + fonts: `xcrun simctl boot "Apple Watch Series 12 (46mm)"` (use the udid from `xcrun simctl list devices available | grep 'Series 12 (46mm)'`), `xcrun simctl install <udid> "$P/Debug-watchsimulator/BusBusWatch.app"`, `xcrun simctl launch <udid> com.hayek.BusBus.watchkitapp` → the placeholder text is visible; `xcrun simctl io <udid> screenshot $DD/watch-launch.png`.

**Acceptance:** all of §0.5 except `test` on the watch scheme; the Step 6/7 checks print every expected line; Mac tests still green. Commit: `Add the watch app and its complications' targets, embedded in the iOS app`.

---

### Task 4: Watch complications (no pbxproj)

**Files:** Modify `BusBusWatchWidget/WatchNextBusWidget.swift`; create `BusBusWatchWidget/Views/WatchWidgetView.swift`, `BusBusWatchWidget/Views/Previews.swift`.
**Produces:** the four accessory families drawn by the existing views, configurable with `SelectSavedSetupIntent`, opening the watch app on the stop, with Smart Stack relevance (already on `NextBusEntry` from Task 1).

- [ ] Step 1: `WatchWidgetView.swift`:

```swift
import SwiftUI
import WidgetKit

/// One complication family at a time, in the app's language and appearance, opening the watch
/// app on its stop when tapped.
struct WatchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: NextBusEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: AccessoryCircularView(entry: entry)
            case .accessoryRectangular: AccessoryRectangularView(entry: entry)
            case .accessoryInline: AccessoryInlineView(entry: entry)
            case .accessoryCorner: AccessoryCornerView(entry: entry)
            @unknown default: AccessoryRectangularView(entry: entry)
            }
        }
        .modifier(WidgetEnvironment(appearance: entry.appearance))
        .widgetURL(WidgetDeepLink.url(for: entry.setup))
    }
}
```

  `WidgetEnvironment` calls `.containerBackground(for: .widget)`; accessory families ignore a colour there (the iOS widget already does this on the lock screen).
- [ ] Step 2: `WatchNextBusWidget.swift` — content closure becomes `WatchWidgetView(entry: entry)`; keep `static let kind = WidgetKind.nextBus`; `supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])`.
- [ ] Step 3: `Previews.swift` — `#if DEBUG` previews for the four families with `NextBusEntry.sample(at: .now)`, a stale entry, and an empty `.noHistory` entry (copy the private helpers from `BusBusWidget/Views/Previews.swift`).
- [ ] Step 4: Timeline behaviour is unchanged (`NextBusTimelineProvider`): confirm by reading, not by code: the watch's fetch path is `WidgetArrivalsFetcher` with `timeout = 10 s`; `reloadDate` 5–15 min; the last entry is never a number.
- [ ] Step 5: Manual check on the simulator: build the watch scheme, install (Task 3 Step 8), long-press a watch face in the simulator → Edit → add the "My Bus Stop" complication in each family (or use the Smart Stack). With no history it shows "CHOOSE YOUR STOP" / the bus glyph. Screenshot each: `xcrun simctl io <udid> screenshot $DD/complication-<family>.png`. Data-bearing checks happen in Task 8 (rendered PNGs) and after Task 5+6 (real sync).

**Acceptance:** watch scheme build green; iOS + Mac builds green (nothing shared changed); the four previews render in Xcode canvas (optional). Commit: `Show the next bus in every watch complication family`.

---

### Task 5: Phone side — `WatchSync` sender and its hooks (no pbxproj)

**Files:** Create `BusBus/WatchSupport/WatchSync.swift`. Modify `BusBus/Persistence/SettingsStore.swift`, `BusBus/WidgetSupport/WidgetBridge.swift`, `BusBus/BusBusApp.swift`, `BusBusTests/Persistence/SharedHistoryStoreTests.swift` (one test).
**Produces:** the iOS app pushes a `WatchSyncPayload` as `WCSession.default.applicationContext` whenever the history, palette, appearance, language, remote switches or a board snapshot change (throttled), and once at launch/activation; macOS and tests untouched.

- [ ] Step 1: `WatchSync.swift` — the whole file is `#if os(iOS)` with an `#else` stub so call sites are unconditional:

```swift
import Foundation
#if os(iOS)
import WatchConnectivity

/// The iPhone's side of the watch: sends the history and what draws it whenever they change.
/// Application context only — latest state wins, delivered when the watch wakes.
@MainActor final class WatchSync: NSObject {
    static let shared = WatchSync()

    /// A board refresh may push again this soon per setup; the board polls every 20–30 s.
    static let snapshotPushInterval: TimeInterval = 60

    private var session: WCSession? { WCSession.isSupported() ? .default : nil }
    private weak var settings: SettingsStore?
    private var lastPayload: WatchSyncPayload?
    private var lastSnapshotPush: [String: Date] = [:]

    /// Once at launch, after `Telemetry.start()`. A no-op on the iPad and everywhere WCSession is unsupported.
    static func activate() { shared.activateSession() }

    /// The history, colours, appearance, language or switches changed (SettingsStore's didSets).
    func settingsChanged(_ settings: SettingsStore)
    /// The board fetched numbers for `setupID` (WidgetBridge.boardDidRefresh); throttled per setup.
    func boardDidRefresh(setupID: String, settings: SettingsStore, at now: Date)

    /// Builds and sends unless: not active (screenshots/tests, as WidgetBridge.isActive), no
    /// session, not activated, no watch app installed, or identical to the last payload sent.
    private func push(from settings: SettingsStore, now: Date = .now)
}

extension WatchSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession)   // watch app just (un)installed → push
}
#else
@MainActor enum WatchSync {
    static func activate() {}
    static var shared: WatchSync.Type { self }
    static func settingsChanged(_ settings: SettingsStore) {}
    static func boardDidRefresh(setupID: String, settings: SettingsStore, at now: Date) {}
}
#endif
```

  Details that matter: the delegate methods run on a background queue, so each hops with `Task { @MainActor in … }`; `isWatchAppInstalled` is only meaningful after `activationDidCompleteWith`, so `activationDidCompleteWith` and `sessionWatchStateDidChange` both call `push(from: settings)` with the weakly held store; the payload is built with `WatchSyncPayload.make(history: settings.savedSetups, palette: settings.paletteAssignments, appearance: settings.appearance, language: settings.language, disabledProviders: SharedHistoryStore().disabledProviders(), snapshot: { WidgetSnapshotStore().load(setupID: $0) }, now:)`; sent as `try session.updateApplicationContext([WatchSyncPayload.contextKey: data])` (errors logged with `os.Logger`, subsystem `com.hayek.BusBus`, category `watch`); telemetry: `Telemetry.log("watch_app_installed")` once per launch when installed, `Telemetry.log("watch_sync_pushed", ["setups": payload.history.count])` per push. The "is active" rule is copied from `WidgetBridge.isActive` (`ScreenshotMode.current == nil` and no `XCTestConfigurationFilePath`) — make `WidgetBridge.isActive` internal (drop `private`) and reuse it.
- [ ] Step 2: Hooks (iOS-only by construction of the stub):
  - `SettingsStore.savedSetups.didSet`: after `WidgetBridge.historyChanged(…)` add `WatchSync.shared.settingsChanged(self)`.
  - `SettingsStore.mirrorForWidget()`: after `WidgetBridge.settingsChanged()` add `WatchSync.shared.settingsChanged(self)`.
  - `SettingsStore.mirrorProviderSwitches()`: after `shared.set(disabled, …)` add `WatchSync.shared.settingsChanged(self)`.
  - `WidgetBridge.boardDidRefresh(configuration:snapshot:at:)`: after the snapshot save, `WatchSync.shared.boardDidRefresh(setupID: setupID, settings: ???, at: now)` — `WidgetBridge` has no store; give it one: `BoardViewModel` calls `WidgetBridge.boardDidRefresh` and owns `settings`, so add a `settings: SettingsStore` parameter to `boardDidRefresh` and pass it from `BoardViewModel` (grep `WidgetBridge.boardDidRefresh(` for the one call site).
  - `BusBusApp.init`: after `Task { await RemoteFlags.shared.activate() }` add `WatchSync.activate()` (inside the `guard ScreenshotMode.current == nil` so staged runs never activate).
- [ ] Step 3: Test (Mac-hosted, so it exercises the stub path on macOS and the guard on iOS): in `SharedHistoryStoreTests`, `@Test func settingsChangesDoNotCrashWithoutAWatch()` — create a `SettingsStore(defaults: suite("own"), shared: suite("shared"))`, mutate `appearance`, `language`, `savedSetups`; `#expect(true)` — it documents the hook is safe under test (`XCTestConfigurationFilePath` set → no push). The payload logic is already covered by Task 2.
- [ ] Step 4: End-to-end on simulators (needs Task 3; do it here, repeat after Task 6):

```bash
PHONE=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print([d["udid"] for r,ds in json.load(sys.stdin)["devices"].items() if "iOS-27" in r for d in ds if d["name"]=="iPhone 17 Pro"][0])')
WATCH=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print([d["udid"] for r,ds in json.load(sys.stdin)["devices"].items() if "watchOS-27" in r for d in ds if d["name"]=="Apple Watch Series 12 (46mm)"][0])')
xcrun simctl pair "$WATCH" "$PHONE"          # once; prints a pair id; ignore "already paired"
xcrun simctl boot "$PHONE"; xcrun simctl boot "$WATCH"
xcrun simctl install "$PHONE" "$DD/Build/Products/Debug-iphonesimulator/BusBus.app"   # installs the embedded watch app on the paired watch
xcrun simctl launch "$PHONE" com.hayek.BusBus
```

  Pick a stop in the phone app (mock provider available in Debug via Settings), then `xcrun simctl launch "$WATCH" com.hayek.BusBus.watchkitapp`; until Task 6 lands the watch shows the placeholder, but `log stream --predicate 'subsystem == "com.hayek.BusBus"' --device …` on the phone shows `watch_sync_pushed` (or the `os.Logger` line).

**Acceptance:** §0.5 iOS build, Mac build, Mac tests, iOS fit test green; the sync log line appears on a paired simulator pair. Commit: `Send the history and the board's numbers to the watch`.

---

### Task 6: Watch app — receiver, store, model, list, board, environment, deep link, strings (no pbxproj)

**Files:** Create `BusBusWatch/WatchSyncReceiver.swift`, `BusBusWatch/WatchStore.swift`, `BusBusWatch/WatchStopModel.swift`, `BusBusWatch/Views/WatchEnvironment.swift`, `BusBusWatch/Views/StopListView.swift`, `BusBusWatch/Views/StopBoardView.swift`, `BusBusWatch/Views/WatchRootView.swift`. Modify `BusBusWatch/BusBusWatchApp.swift`, `BusBus/Localizable.xcstrings`.
**Produces:** the spec §5 app: list → board, live countdown, own fetches, complications reloaded, deep link from a complication, Hebrew RTL, six new strings in 18 languages.

- [ ] Step 1: `WatchStore.swift` — the watch's read model of the mirror, bumped by the receiver:

```swift
import Foundation
import Observation

/// What the watch knows from the phone, read from the App Group on demand and re-read whenever a
/// sync lands. Views read this; nothing on the watch writes the history.
@MainActor @Observable final class WatchStore {
    private(set) var history: [SavedSetup] = []
    private(set) var savedAt: Date?
    private(set) var palette: [String: Int] = [:]
    private(set) var appearance: Appearance = .system
    private(set) var language: String?
    /// The stop a complication asked for, consumed by the root once.
    var requestedSetupID: String?

    init(history store: SharedHistoryStore = SharedHistoryStore()) { reload(from: store) }
    func reload(from store: SharedHistoryStore = SharedHistoryStore())
    func setup(id: String) -> SavedSetup? { history.first { $0.id == id } }
}
```

- [ ] Step 2: `WatchSyncReceiver.swift`:

```swift
import Foundation
import WatchConnectivity
import WidgetKit
import os

/// Receives the phone's payload and writes it into the watch's App Group (`WatchSyncApply`), then
/// tells the store and WidgetKit.
@MainActor final class WatchSyncReceiver: NSObject {
    private let log = Logger(subsystem: "com.hayek.BusBus", category: "watch")
    private let store: WatchStore
    private var apply = WatchSyncApply()

    init(store: WatchStore)
    /// Activates the session and applies whatever context is already there (`receivedApplicationContext`).
    func activate()
    /// Decode + apply + notify. Exposed for tests (a dictionary shaped like a context).
    @discardableResult func apply(context: [String: Any]) -> WatchSyncApply.Outcome
}

extension WatchSyncReceiver: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?)
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any])
}
```

  On `.applied`: `store.reload()` and `WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nextBus)`. `.olderThanStored` and `.unreadable` are logged at `.info`/`.error` and nothing else happens.
- [ ] Step 3: `WatchStopModel.swift`:

```swift
import Foundation
import Observation
import WidgetKit

/// One stop's board while it is on screen: the stored snapshot at once, then the watch's own
/// fetches on the provider's cadence, saved for the complications.
@MainActor @Observable final class WatchStopModel {
    enum Fetching: Hashable, Sendable { case idle, fetching, failed }

    let setup: SavedSetup
    private(set) var snapshot: WidgetSnapshot?
    private(set) var fetching: Fetching = .idle
    /// Whether the watch may call this setup's provider at all (`WidgetProviderGate` via the fetcher);
    /// false for snapshot-only providers, whose numbers only ever come from the phone.
    let canFetch: Bool
    let provider: (any TransitProvider)?
    private var lastComplicationReload: Date?
    private var task: Task<Void, Never>?

    init(setup: SavedSetup,
         snapshots: WidgetSnapshotStore = WidgetSnapshotStore(),
         fetcher: WidgetArrivalsFetcher = WidgetArrivalsFetcher(),
         fetch: ((SavedSetup, Date) async throws -> WidgetSnapshot)? = nil,   // tests stub this
         reloadComplications: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nextBus) },
         now: @escaping () -> Date = { .now })

    /// The picture at `date`: the timeline's first entry from the stored numbers, which gives
    /// liveness, the "ran out" rule and the arrivals list for free.
    func entry(at date: Date, palette: [String: Int], appearance: Appearance) -> NextBusEntry {
        NextBusTimeline.entries(history: [setup], chosenID: setup.id, snapshot: snapshot,
                                layout: WidgetLayout(arrivalsShown: WidgetLayout.readoutArrivals + WidgetLayout.largeLaterRows),
                                palette: palette, appearance: appearance, now: date).first!
    }

    /// Fetches now if the stored numbers are old (`WatchRefreshPolicy.shouldFetch`), then every
    /// `WatchRefreshPolicy.pollInterval` until `stop()`.
    func start()
    func stop()
    /// One fetch. Failure keeps the last good numbers and sets `fetching = .failed`.
    func refresh() async
}
```

  Every successful fetch: `snapshots.save(fetched)`; then if `WatchRefreshPolicy.shouldReloadComplications(lastReload:now:)` → `reloadComplications()`.
- [ ] Step 4: `WatchEnvironment.swift` — the root modifier: reads `store.appearance` → `Theme.resolve(appearance.colorScheme ?? colorScheme)` into `\.theme`, and `AppLanguage.override` (the `BUSBUS_WIDGET` branch reads `SharedKeys.language`) into `\.locale` and `\.layoutDirection`, exactly the two lines `WidgetEnvironment` uses; `.preferredColorScheme(appearance.colorScheme)`; sets `\.widgetIsMonochrome` false. No `containerBackground`. Also `.id(store.language)` on the stack so captions built in code are rebuilt when the language changes (as `RootView` does).
- [ ] Step 5: `StopListView.swift` (spec §5.2): `List` or `ScrollView` of `SavedSetups.sorted(store.history)` rows — `NavigationLink(value: setup.id)`: stop name (`TypeStyle(.archivoBlack, 17, tracking: -0.013)`, one line, `minimumScaleFactor(0.7)`), under it up to three `WidgetBadge(number:colorIndex:side: 20, numeralSize: 10)` using `LineColorAssigner.provisionalIndex(for:persisted: store.palette)`, a `pin.fill` glyph trailing for pinned, and — when `WidgetSnapshotStore().load(setupID:)` is usable at `now` — `WidgetMinutes` (number 22, unit 12) trailing; footer `Text("FROM YOUR IPHONE · SYNCED \(WidgetFormat.time(savedAt))")` and the row `Text("Language and colours follow your iPhone")` in `TypeStyles.creditLinePhone`; title `Text("STOPS")` in `TypeStyles.sectionHeaderPhone`. Empty history → `WidgetMessageView`-style block: title `"CHOOSE YOUR STOP"`, detail `"PICK A STOP ON YOUR IPHONE FIRST"`.
- [ ] Step 6: `StopBoardView.swift` (spec §5.3): `ScrollView` with `TimelineView(isLuminanceReduced ? .everyMinute : .periodic(from: .now, by: 1))`, `let entry = model.entry(at: context.date, …)`:
  1. `WidgetHeader(entry: entry, titleSize: 17, showsCode: false)` (now in `WidgetReadout.swift`), dot hidden under `isLuminanceReduced`;
  2. `WidgetPrimaryReadout(entry:arrival:metrics: .watch)` — add to `WidgetPrimaryReadout.Metrics` in `WidgetReadout.swift`: `static let watch = Metrics(badge: 40, numeral: 20, minutes: 56, unit: 16, kicker: 0, subline: 12, gap: 10)` and skip the kicker `ViewThatFits` when `metrics.kicker == 0`;
  3. `WidgetThenCard(entry:arrival:style: .row)`;
  4. up to `WidgetLayout.largeLaterRows` `WidgetArrivalRow`s;
  5. states via `WidgetMessage(entry)`: `.expired` → title `"NO LIVE DATA"`, detail: `!model.canFetch` → `"OPEN MY BUS STOP ON YOUR IPHONE"`; `model.fetching == .failed` → `"CAN'T REACH THE FEED"`; `model.fetching == .fetching && model.snapshot == nil` → `LiveState.connecting.label`; else `"OPEN MY BUS STOP ON YOUR IPHONE"`. `.noBusesDue` unchanged. `.notConfigured`/`.noHistory` cannot occur here.
  6. `Text(verbatim: provider.attribution)` in `TypeStyles.creditLinePhone` when non-nil.
  `.task { model.start() }` / `.onDisappear { model.stop() }` and `.onChange(of: scenePhase)` → stop when not `.active`, start again when active. `.navigationTitle` empty; `.toolbar(.hidden)` is not needed on watchOS.
- [ ] Step 7: `WatchRootView.swift` — `NavigationStack(path:)` with `StopListView` as root and `.navigationDestination(for: String.self) { id in StopBoardView(model: WatchStopModel(setup: store.setup(id: id)!)) }`; initial path `[HistoryLookup.defaultEntry(in: store.history)?.id].compactMap { $0 }` (the phone's "board on the very first frame" rule); `.onOpenURL { if let id = WidgetDeepLink.setupID(from: $0), store.setup(id: id) != nil { path = [id] } }`; `.onChange(of: store.history)` → if the shown id vanished, pop to the list. Keep one `WatchStopModel` per pushed id via `@State`; recreate on id change.
- [ ] Step 8: `BusBusWatchApp.swift` — `@State private var store = WatchStore()`, `@State private var receiver: WatchSyncReceiver`; `init` registers fonts and builds the receiver with the store; `WindowGroup { WatchRootView(store: store).modifier(WatchEnvironment(store: store)) }`; `.task { receiver.activate() }` (activation from the scene, once).
- [ ] Step 9: Strings — add to `BusBus/Localizable.xcstrings` (the file is JSON; insert keys in sorted position with the existing 2-space style, `"comment"` naming the watch screen, every one of the 17 other languages `"state" : "translated"`; English is the source and needs no entry beyond the key):
  `STOPS`, `FROM YOUR IPHONE · SYNCED %@`, `PICK A STOP ON YOUR IPHONE FIRST`, `CAN'T REACH THE FEED`, `OPEN MY BUS STOP ON YOUR IPHONE`, `Language and colours follow your iPhone`. Hebrew by hand (e.g. `תחנות`, `מהאייפון שלך · סונכרן %@`, `בחרו קודם תחנה באייפון`, `אין גישה לשירות`, `פתחו את התחנה שלי באייפון`, `השפה והצבעים לפי האייפון`), the other 16 machine-translated to match the register of the neighbouring widget strings (all caps where the English is). Validate: `plutil -lint BusBus/Localizable.xcstrings` and `python3 -c "import json;d=json.load(open('BusBus/Localizable.xcstrings'));ks=['STOPS','FROM YOUR IPHONE · SYNCED %@','PICK A STOP ON YOUR IPHONE FIRST',\"CAN'T REACH THE FEED\",'OPEN MY BUS STOP ON YOUR IPHONE','Language and colours follow your iPhone'];[print(k, len(d['strings'][k]['localizations'])) for k in ks]"` → each `17`.
- [ ] Step 10: Simulator walk-through (paired pair from Task 5 Step 4): pick a stop on the phone → the watch list shows it within seconds; open it → the board counts down; `xcrun simctl openurl "$WATCH" 'busbus://setup?id=<id>'` (percent-encode `|` as `%7C`) → the board opens on that stop; change the phone's language to Hebrew → the watch mirrors (list and board right-to-left, "דק׳"). Screenshots of list and board, light and dark, `en` and `he`, into `$DD/`.

**Acceptance:** watch build green; iOS/Mac builds and Mac tests green (`WidgetReadout.swift` changed: re-run `-only-testing:BusBusTests/WidgetLayoutFitTests` on `$IOS_SIM`); the walk-through works. Commit: `Add the watch app: the saved stops and one stop's board, synced from the iPhone`.

---

### Task 7: `BusBusWatchTests` target + watch-hosted tests (pbxproj, sequential)

**Files:** Modify `project.pbxproj`, `BusBusWatch.xcscheme`. Create `BusBusWatchTests/FontRegistrationOnWatchTests.swift`, `BusBusWatchTests/WatchStopModelTests.swift`, `BusBusWatchTests/WatchSyncReceiverTests.swift`.
**Produces:** `xcodebuild -scheme BusBusWatch … test` runs a thin suite inside the watch app.

- [ ] Step 1: `project.pbxproj`:

```
/* PBXContainerItemProxy — append */
		AA0000000000000000000126 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = AA0000000000000000000070 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = AA00000000000000000000F0;
			remoteInfo = BusBusWatch;
		};
/* PBXFileReference — append */
		AA0000000000000000000121 /* BusBusWatchTests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = BusBusWatchTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
/* PBXFileSystemSynchronizedRootGroup — append */
		AA0000000000000000000122 /* BusBusWatchTests */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = BusBusWatchTests;
			sourceTree = "<group>";
		};
/* PBXFrameworksBuildPhase / PBXResourcesBuildPhase / PBXSourcesBuildPhase — append */
		AA0000000000000000000124 /* Frameworks */ = { isa = PBXFrameworksBuildPhase; files = ( ); };
		AA0000000000000000000125 /* Resources */ = { isa = PBXResourcesBuildPhase; files = ( ); };
		AA0000000000000000000123 /* Sources */ = { isa = PBXSourcesBuildPhase; files = ( ); };
/* PBXGroup — main children after AA0000000000000000000102: AA0000000000000000000122 /* BusBusWatchTests */; Products: AA0000000000000000000121 */
/* PBXNativeTarget — append */
		AA0000000000000000000120 /* BusBusWatchTests */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = AA0000000000000000000128 /* Build configuration list for PBXNativeTarget "BusBusWatchTests" */;
			buildPhases = (
				AA0000000000000000000123 /* Sources */,
				AA0000000000000000000124 /* Frameworks */,
				AA0000000000000000000125 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
				AA0000000000000000000127 /* PBXTargetDependency */,
			);
			fileSystemSynchronizedGroups = (
				AA0000000000000000000122 /* BusBusWatchTests */,
			);
			name = BusBusWatchTests;
			productName = BusBusWatchTests;
			productReference = AA0000000000000000000121 /* BusBusWatchTests.xctest */;
			productType = "com.apple.product-type.bundle.unit-test";
		};
/* PBXProject — TargetAttributes += AA0000000000000000000120 = { CreatedOnToolsVersion = 27.0; TestTargetID = AA00000000000000000000F0; }; targets += AA0000000000000000000120 */
/* PBXTargetDependency — append */
		AA0000000000000000000127 /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = AA00000000000000000000F0 /* BusBusWatch */;
			targetProxy = AA0000000000000000000126 /* PBXContainerItemProxy */;
		};
/* XCBuildConfiguration — append (Debug AA…0129, Release AA…012A, identical) */
			buildSettings = {
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_STYLE = Automatic;
				GENERATE_INFOPLIST_FILE = YES;
				PRODUCT_BUNDLE_IDENTIFIER = com.hayek.BusBusWatchTests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = watchos;
				SUPPORTED_PLATFORMS = "watchos watchsimulator";
				SWIFT_APPROACHABLE_CONCURRENCY = YES;
				SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = 4;
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/BusBusWatch.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/BusBusWatch";
				WATCHOS_DEPLOYMENT_TARGET = 27.0;
			};
/* XCConfigurationList — append AA0000000000000000000128 listing AA…0129 / AA…012A, defaultConfigurationName = Release */
```

  `ENABLE_TESTABILITY = YES` is project-level Debug, so `@testable import BusBusWatch` works.
- [ ] Step 2: `BusBusWatch.xcscheme` — add the `BuildActionEntry` (buildForTesting only) and the `<Testables>` reference for `AA0000000000000000000120` / `BusBusWatchTests.xctest` / `BusBusWatchTests`, mirroring `BusBus.xcscheme`'s `BusBusTests` entries.
- [ ] Step 3: Tests (Swift Testing, `@testable import BusBusWatch`):
  - `FontRegistrationOnWatchTests`: `FontRegistrar.url(for:)` non-nil for all six faces; after `registerBundledFonts()`, `unresolvedFaces().isEmpty` (mirror of `BusBusTests/Design/FontRegistrationTests`); the widget's copies: `Bundle.main.builtInPlugInsURL?.appending(path: "BusBusWatchWidget.appex")` holds all six.
  - `WatchStopModelTests`: with `WidgetSnapshotStore(directory: tempDir)`, a stubbed `fetch` counting calls and a `now` closure: no snapshot → `refresh()` fetches once and saves to the store; a 30 s-fresh stored snapshot → `start()`'s first pass does not fetch; a throwing stub → `snapshot` keeps the previous value and `fetching == .failed`; `reloadComplications` called on the first success and not again within 3 min.
  - `WatchSyncReceiverTests`: build a `WatchSyncPayload` (sample from `NextBusEntry.sample(at:)`'s setup), `receiver.apply(context: ["payload": data])` with a `WatchSyncApply` pointed at a throwaway suite/dirs → `.applied`, `store.history` has the setup; garbage → `.unreadable`; older `sentAt` → `.olderThanStored`. (Give `WatchSyncReceiver` an `init(store:apply:)` for this.)

**Acceptance:** `xcodebuild -scheme BusBusWatch -destination "$WATCH_SIM" -derivedDataPath $DD -quiet test` green; §0.5 iOS/Mac builds and Mac tests green. Commit: `Test the watch app where only the watch can: fonts, the refresh loop, the receiver`.

---

### Task 8: Accessory fit sizes, complication PNGs, `screenshots.sh watch` (no pbxproj)

**Files:** Modify `BusBusTests/Widget/WidgetLayoutFitTests.swift`, `BusBusTests/Widget/WidgetScreenshotTests.swift`, `scripts/screenshots.sh`.
**Produces:** measured proof that all four families fit at every current watch size in `en de fi he ja`; PNGs under `screenshots/widgets/watch/<language>/<look>/<family>-<state>.png`.

- [ ] Step 1: Watch accessory sizes (points, from the HIG's complication tables for the current cases; read `xcrun simctl` metrics if the simulator exposes them, else use these): circular 40 mm 50×50, 42 mm 54×54, 44 mm 54×54, 46 mm 58×58, 49 mm 60×60; rectangular 40 mm 150×47, 42 mm 162×52, 44 mm 168×52, 46 mm 176×56, 49 mm 180×58; inline 40 mm 133×18, 49 mm 178×22; corner (the glyph area) 40 mm 32×32, 49 mm 40×40. Put them in a new `WidgetLayoutFitTests.watchSizes: [(Family, CGSize)]` with new `Family` cases `.circular, .rectangular, .inline, .corner`, `margin: 0`, and views `AccessoryCircularView`, `AccessoryRectangularView`, `AccessoryInlineView`, `AccessoryCornerView` (the latter also measured as `Text(verbatim: view.label)` at 12 pt for the curved label's length ≤ the family's width). Run them in `everySizeFits` under `WidgetEnvironment(appearance: .dark)` with `.environment(\.widgetRenderingMode, .vibrant)`. Exclude `.expired`/`.missing` from the corner's numeric check (they show the glyph).
- [ ] Step 2: `WidgetScreenshotTests.Device` gains `case watch` with `families`: `(.accessoryCircular, 58×58), (.accessoryRectangular, 176×56), (.accessoryInline, 178×22)` (46 mm) and the 42/49 mm circular+rectangular variants, `scale = 2`, `cornerRadius` unused, `margin = 0`, `monochromeLook = .vibrant`; `looks` for the watch: `[(.dark, .vibrant, "vibrant"), (.dark, .fullColor, "color")]` (watch faces render both). The corner family cannot be measured with `.widgetLabel` on iOS: render `AccessoryCornerView` content + its `label` as a second `Text` line and name it `corner-<state>.png`. `isAccessory` gains `.accessoryCorner` under `#if os(watchOS)` only — on iOS the corner shot is drawn by the special-case branch above, so keep it out of `isAccessory`.
- [ ] Step 3: `scripts/screenshots.sh`: `WIDGET_DEVICES` default becomes `iphone ipad mac watch`; `watch` runs on the iPhone simulator pass (`for spec in "iphone|$IPHONE" "ipad|$IPAD" "watch|$IPHONE"`), exporting to `$OUT/widgets/watch`; update the header comment (`family … circular, rectangular, inline, corner (watch)`; `look … vibrant, color (watch)`).
- [ ] Step 4: Run `WIDGET_DEVICES=watch scripts/screenshots.sh widgets` and eyeball `screenshots/widgets/watch/en/vibrant/rectangular-live.png` and the `he` one (RTL).

**Acceptance:** `xcodebuild -scheme BusBus -destination "$IOS_SIM" -derivedDataPath $DD -quiet test -only-testing:BusBusTests/WidgetLayoutFitTests` green; the script produces PNGs for every family × state × language; Mac tests still green (the accessory tests are `#if os(iOS)`). Commit: `Measure and render the watch complications with the widget's fit tests`.

---

### Task 9 (deferred; do before the first watch release, not in the first PR): App Store watch screenshots

Sketch only — write its own plan when scheduled. `BusBusWatch/WatchScreenshotMode.swift` reads `-screenshot stops|board` and `-screenshotAppearance`, seeds the watch's App Group with `NextBusEntry.sample`-style history and a fresh snapshot (no mock provider on the watch; the sample data needs none) and freezes `AppClock` (`isStaging` already keys on the same `-screenshot` argument). `scripts/screenshots.sh watch` boots a 46 mm and a 42 mm watchOS 27 simulator, installs `BusBusWatch.app` from `Build/Products/Release-iphonesimulator/BusBus.app/Watch/`, launches with the arguments, `simctl io screenshot` in light/dark × en/he; try `simctl status_bar` for 9:41 and accept the live time if the watch runtime refuses it (spec §12 #13).

---

## 3. Pitfalls (read before each task)

1. **`#if os` guards.** Any `WidgetFamily.system*` outside `#if !os(watchOS)` breaks the watch build; any `.accessoryCorner` outside `#if os(watchOS)` breaks iOS/macOS. `AccessoryViews.swift` is `#if os(iOS) || os(watchOS)` because macOS has no accessory families. `WatchSync.swift` is `#if os(iOS)` with a stub `#else` because the `BusBus` target also builds for macOS, where `WatchConnectivity` does not exist. `WidgetLayoutFitTests`/`WidgetScreenshotTests` stay `#if os(iOS)` / iOS-only branches for accessories.
2. **Firebase never reaches the watch.** The Firebase products are `packageProductDependencies` of the `BusBus` target only; the watch targets add none, link no `-ObjC`, and their exception sets exclude `Telemetry/`, `GoogleService-Info.plist`, `ServiceHealth.swift`, `SupportedRegions.swift`, `TransitCache.swift`, `Setup/`, `Wall/`, `Screenshots/`, `WidgetBridge.swift`, `MockTransitProvider.swift`, `MapFixtures.swift`. `BUSBUS_WIDGET` must be defined on both watch targets or `TransitProviders.staged` references `MockTransitProvider` (link error) and `AppLanguage.override` reads the wrong suite.
3. **App Group.** Both watch targets carry `com.apple.security.application-groups = [group.com.hayek.BusBus]` and `REGISTER_APP_GROUPS = YES`; without either, `AppGroup.containerURL` is nil on the watch, `AppGroup.defaults` falls back to `.standard`, and the app and its complications silently stop sharing (the list works, the complications show "CHOOSE YOUR STOP"). Check with `codesign -d --entitlements - <app>` on the built products.
4. **WCSession.** Activate exactly once per process (`BusBusApp.init` on the phone, the scene's `.task` on the watch). iOS delegates must implement `sessionDidBecomeInactive`/`sessionDidDeactivate` (re-activate in the latter). `isWatchAppInstalled`/`isReachable` are meaningless before `activationDidCompleteWith`; push there and on `sessionWatchStateDidChange`. `updateApplicationContext` throws for non-plist values — send `[String: Data]`. Delegate callbacks are off-main; with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` the delegate methods must be `nonisolated` and hop with `Task { @MainActor in }`. The iPad reports `WCSession.isSupported() == false`; guard it, never force-unwrap `.default`.
5. **Localization catalogs.** `Localizable.xcstrings` and `InfoPlist.xcstrings` must be in both watch exception sets (they are, by copying `AA…E3`); `STRING_CATALOG_GENERATE_SYMBOLS = YES` and `SWIFT_EMIT_LOC_STRINGS = YES` on both. New keys go into `BusBus/Localizable.xcstrings` only (one catalog, three bundles). Strings built in code use `String(appLocalized:)`; `Text("KEY")` resolves through the environment locale set by `WatchEnvironment`.
6. **Signing mirrors the existing targets.** `CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM = Q7U5734Q3T`, `CODE_SIGN_ENTITLEMENTS` per target, `SKIP_INSTALL = YES` on the watch app and its extension (they are embedded, not installed on their own). Test bundles carry no team, like `BusBusTests`. Automatic signing creates the two new App IDs; on a machine without the team's credentials the simulator builds still work.
7. **Exception sets are allow-lists for non-owning targets.** A path that does not exist on disk is an error, so Task 3 runs after Tasks 1–2 created every file it lists. Paths with hyphens are quoted (`"Resources/Fonts/Archivo-Black.ttf"`). Keep the two "BusBus" sets and the two "BusBusWidget" sets byte-identical to each other (diff them).
8. **One `AppClock`.** `BusProgressService.swift` (in the shared set) calls `AppClock.now`; the watch targets need exactly one definition (Task 0). Two → "invalid redeclaration"; none → "cannot find 'AppClock'".
9. **Simulators.** Watch destinations must say `OS=27.0`; the 26.5 runtime cannot run a 27.0-deployment app. `xcodebuild test` on a watch simulator boots it itself; pairing is only needed for the end-to-end sync check (`xcrun simctl pair`). Installing the iOS app on a paired phone simulator installs the embedded watch app on the watch simulator.
10. **`WidgetKind.nextBus` is the same string in two bundles** — fine, kinds are per bundle. `WidgetCenter.shared.reloadTimelines(ofKind:)` on the watch reaches only the watch's extension.
11. **`SelectSavedSetupIntent` compiles into three targets** (iOS widget, watch app, watch widget). AppIntents metadata is extracted per target; the parameter list differs on watchOS (`largeContent` fenced), which is fine because each bundle has its own intent definition.
12. **`WidgetEnvironment` inside an app.** The widget-only environment values default sensibly outside WidgetKit, but `containerBackground(for: .widget)` is not for app views — the watch app uses `WatchEnvironment`, not `WidgetEnvironment`. The complications keep `WidgetEnvironment`.
13. **Always On.** `isLuminanceReduced` → `.everyMinute` schedule, dot hidden; the numeral still updates on the minute. Never a per-second schedule in the background.
14. **Versions.** `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` are project-level; do not override on the watch targets or App Store validation fails with a version mismatch between the iOS app and the embedded watch app.
15. **Icon.** Keep `ASSETCATALOG_COMPILER_APPICON_NAME = Icon` with `Icon.icon` in the watch app's Resources; verify the built product has an icon (Task 3 Step 7) and fall back to a watch `AppIcon` set only if it does not.
16. **Do not** add `Config/Debug.xcconfig` (and so `Secrets.xcconfig`) to any watch configuration; `APIKeys.key` must be nil on the watch in every configuration.

---

## 4. Final verification checklist

Run from a clean derived data folder (`rm -rf $DD`) on the integrated branch, in this order; every line must pass.

- [ ] `git status --short` is empty; `git log --oneline -12` shows one commit per task (0–8) with the messages above.
- [ ] `xcodebuild -scheme BusBus -destination 'generic/platform=iOS Simulator' -derivedDataPath $DD -quiet build`
- [ ] `xcodebuild -scheme BusBus -destination 'platform=macOS' -derivedDataPath $DD -quiet build` and `! test -e $DD/Build/Products/Debug/BusBus.app/Contents/Watch`
- [ ] `xcodebuild -scheme BusBusWatch -destination "$WATCH_SIM" -derivedDataPath $DD -quiet build`
- [ ] `xcodebuild -scheme BusBusWatch -destination "$WATCH_SIM" -derivedDataPath $DD -quiet test`
- [ ] `xcodebuild -scheme BusBus -destination 'platform=macOS' -derivedDataPath $DD -quiet test` (includes `WatchSyncPayloadTests`, `WatchSyncApplyTests`, `WatchRefreshPolicyTests`, the relevance test, `SharedHistoryStoreTests`)
- [ ] `xcodebuild -scheme BusBus -destination "$IOS_SIM" -derivedDataPath $DD -quiet test -only-testing:BusBusTests/WidgetLayoutFitTests -only-testing:BusBusTests/FontRegistrationTests`
- [ ] Products: `Debug-iphonesimulator/BusBus.app/Watch/BusBusWatch.app/PlugIns/BusBusWatchWidget.appex` exists; both watch bundles hold the six `.ttf`; `plutil -p` of the watch app's Info.plist shows `WKApplication = 1`, `WKCompanionAppBundleIdentifier = "com.hayek.BusBus"`, `CFBundleIdentifier = "com.hayek.BusBus.watchkitapp"`, `CFBundleURLSchemes = ["busbus"]`, and the same `CFBundleShortVersionString` as the iOS app.
- [ ] Hygiene: `strings` of `BusBusWatch` and `BusBusWatchWidget` binaries contain no `Firebase`, no `GoogleService`, no `MTA_BUSTIME_KEY`; neither watch Info.plist has `BusBusAPIKeys`; `codesign -d --entitlements - <each watch product>` lists `group.com.hayek.BusBus` and no `appattest`.
- [ ] Widget exception sets: `diff <(sed -n '/AA00000000000000000000F3/,/target =/p' project.pbxproj | grep -v 'AA0000\|target =') <(sed -n '/AA0000000000000000000103/,/target =/p' project.pbxproj | grep -v 'AA0000\|target =')` is empty (same for F4 vs 0104); `plutil -lint BusBus.xcodeproj/project.pbxproj` OK; opening the project in Xcode shows no "missing file" warnings on the new targets.
- [ ] End to end on a paired simulator pair (Task 5 Step 4 + Task 6 Step 10): a stop picked on the phone appears on the watch; the board counts down live and shows LIVE; after 10 minutes without the app in front the dot greys (or simulate by setting the phone's clock forward); a complication tap opens that stop; Hebrew on the phone flips the watch to RTL with "דק׳"; pulling a provider via `disabledProviders` (toggle `regionIsAvailable` in a Debug build or edit the mirrored key) stops the watch fetching it after the phone app's next launch.
- [ ] `WIDGET_DEVICES=watch scripts/screenshots.sh widgets` lands PNGs for circular, rectangular, inline and corner in `en` and `he`, states live/stale/no-live-data/no-history/removed-stop, none clipped.
- [ ] `docs/plans/watch-spec.md` §13 acceptance list re-read against the above; anything not met is listed in the PR description as deferred (Task 9 is expected there).

---

## 5. Implementation notes (deviations found while executing)

- **Task 0:** the widget's membership exception set held 70 entries, not 75 (71 once `Transit/AppClock.swift` joined). `AppClock` sits in its alphabetical place, before `Transit/Models`, rather than where Task 0 placed it.
- **Task 2:** `WatchSyncPayload` encodes dates with `JSONEncoder`'s default strategy, not ISO 8601, so sub-second precision survives the round trip and the "newer than stored" comparison stays exact.
- **Task 3:** on watchOS, `AppIntentTimelineProvider` requires `recommendations()` (a complication has no intent editor). `NextBusTimelineProvider` gains a `#if os(watchOS)` `recommendations()` returning one `AppIntentRecommendation` per history entry, in the picker's order. Task 4 may refine it.
- **Task 3:** Icon Composer's `Icon.icon` does yield a watch icon (`Assets.car`, `CFBundleIconName = Icon`), so Step 7's fallback `AppIcon.appiconset` was not needed.
- **Task 3:** simulator builds sign ad hoc, so `codesign -d --entitlements -` prints an empty dict; the app group is checked in the `*-Simulated.xcent` files under `Intermediates.noindex` instead (both watch products list `group.com.hayek.BusBus`, no `appattest`).
- **Task 4:** `recommendations()` now offers one unconfigured complication before the first sync (so it can go on a face and follow the top of the history once it lands), and `WatchSyncReceiver` calls `WidgetCenter.shared.invalidateConfigurationRecommendations()` after every applied payload so the face's gallery follows the history. Step 5's manual face editing was not done (no scripted way to edit a watch face in the simulator); the families are covered by Task 8's rendered PNGs and fit tests.
- **Task 5:** `WatchSync` only knows the store after a `settingsChanged`, so `SettingsStore.init` also calls it once — that is the "once at launch" push. Payloads are compared without `sentAt` when skipping an identical push; the last-sent payload is forgotten when the session or the watch app's install state changes. Besides `isWatchAppInstalled`, `push` also checks `isPaired`. `mirrorProviderSwitches()` and `mirrorForWidget()` notify the watch only when they changed something, as they do the widget.
- **Task 6:** `WidgetHeader` gained `showsLiveDot` (default true) for Always On, and `WidgetPrimaryReadout` skips the kicker when `metrics.kicker == 0` (`Metrics.watch`). The THEN row is drawn at `scale: 0.8` to fit the watch's width. `WatchStopModel` exposes `catchUp()` (re-read the store, fetch only if old) as the first pass of `start()`, and re-reads the store before every poll so a synced phone snapshot replaces an older one — the only source for snapshot-only providers. The board's message detail is a `Text`, not a `LocalizedStringKey`, so `LiveState.connecting.label` (already localised) is shown verbatim. The pin glyph is hidden from VoiceOver rather than adding a new "Pinned" string. `plutil -lint` cannot read a JSON `.xcstrings` (it rejects the committed file too); the catalog was validated with `python3 -m json.tool` and the per-key count check (17 each), and the diff is additive only.
- **Task 6 walk-through:** on the existing Series 12 (46mm) / iPhone 18 Pro Max pair, with a seeded phone history, the phone logged `Pushed 2 setups and 2 snapshots`, the watch list and board showed them, and switching the phone to Hebrew flipped the watch to RTL with "דק׳". Seeding the phone's App Group plist only takes effect with the phone simulator shut down (cfprefsd caches the domain). `xcrun simctl openurl` on the watch fails with LSApplicationWorkspaceErrorDomain 115 for `busbus://` (the scheme is in the built Info.plist), so the complication deep link is untested; relaunching opens the default stop's board as intended. In Hebrew the system back button sits under the clock (the app flips its own layout direction; the system chrome follows the device language).
- **Task 8:** the first measured run found the lock-screen views too tall for the watch: the rectangle drew 61 pt in 47–58 and the 40 mm circle 52 pt in 50. `AccessoryRectangularView` now picks with `ViewThatFits(in: .vertical)` from the lock-screen layout, then the same with its captions in `widgetCaptionLine` boxes, then without the THEN line (and a one-line message detail); `AccessoryCircularView` falls back to caption line boxes and 2 pt padding. The first layout still fits the iPhone's lock screen, so the iOS widget is unchanged. The inline complication's height is not checked (the face sets it in its own font; with `.lineLimit(1)` only its width is the view's), and the corner's curved label is held to an estimated 60 pt budget, not a published size. The watch shots use `-42mm`/`-46mm`/`-49mm` in the circle and rectangle file names (the same family at three sizes), and the corner is drawn as its glyph over its label. `scripts/screenshots.sh` now takes `DERIVED` from the environment (so it can share a derived data folder); run here with `DERIVED=build/DD WIDGET_DEVICES=watch scripts/screenshots.sh widgets` → 160 PNGs (en, he × vibrant, color).
- **Task 7:** `WatchStopModelTests` drive `catchUp()` (the first pass of `start()`) rather than `start()` itself, so no test waits on the poll loop's sleep. `WatchSyncReceiver` already took `init(store:apply:)` from Task 6. `xcodebuild -scheme BusBusWatch … test` on the Series 12 (46mm) simulator: 10 tests in 3 suites pass.
- **Review fixes:** `WatchSyncReceiver` activates in the app's `init` (so a background launch gets it), not in a view's `.task`, and the scene carries `.backgroundTask(.watchConnectivity)`: it waits (≤ 10 s) for the session to be activated with no `hasContentPending`, then applies `receivedApplicationContext` only when it is newer than the stored history (the delegate may already have applied it), which reloads the complications. That path needs a paired device to exercise and has no automated test. Activation is skipped under XCTest (`XCTestConfigurationFilePath`, the phone's `WidgetBridge.isActive` rule). The phone's dedupe, per-setup 60 s throttle and session reset moved into `WatchPushLedger` (`BusBus/WatchSupport/`, tested on the Mac); the throttle now starts only once `updateApplicationContext` has taken a payload. `NextBusEntry.relevanceScore` holds the Smart Stack guard (watchOS `relevance` wraps it) so it is tested off the watch. `NextBusTimeline.entry(…)` builds only the picture at `now` (the timeline's first entry, tested equal to it), used by the board every second and by the stop list. Board models are made once per stop on the path by `WatchBoardModels` in `WatchRootView` and dropped when the stop leaves the path. The board's expired detail reads "CONNECTING" whenever the watch may fetch (and has not just failed); "OPEN MY BUS STOP ON YOUR IPHONE" only when it may not. `WidgetHeader` takes `titleLineLimit` (1 by default; the watch board passes 2), and the stop list's names take two lines too. On watchOS the rectangular complication's expired detail for a snapshot-only provider (`WidgetProviderGate.isSnapshotOnly`) reuses the board's "OPEN MY BUS STOP ON YOUR IPHONE" (`WidgetMessage.watchDetail`); no new string. The watch app no longer sets `INFOPLIST_KEY_UISupportedInterfaceOrientations`.
- **RTL chrome (deviation from spec §5.5):** `WatchEnvironment` (language, colours, the `.id(language)` rebuild) is applied to each screen's content inside the `NavigationStack` — the list and each board destination — rather than to the stack. The system chrome (back button, clock) keeps the watch's own direction, so in Hebrew the back chevron no longer sits under the clock, while the content is still mirrored; and `path` now lives outside the `.id`, so a language sync leaves the rider on their board. Re-taken on the Series 12 (46mm): `build/watch-shots/board-en.png`, `board-he.png`. The list was not re-taken: the app opens on the default stop's board and `simctl` cannot tap back (Simulator.app is not installed with this Xcode for UI scripting); the English shot needed the watch's `shared.historySavedAt` moved past the system-kept application context, which otherwise re-applies the phone's Hebrew on activation (restored afterwards).
