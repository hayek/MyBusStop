# BusBus — Apple Watch: product and technical spec (v1)

Status: spec, not an implementation plan. Every file name below exists in the repo today unless it is marked *new*. Platform facts marked [SDK] were checked against the watchOS 27.0 SDK in Xcode 27.0 (27A266a) on this machine, which also has watchOS 27.0 simulators (Series 11/12, SE 3, Ultra 3/4).

## 1. Summary

Add a watchOS app and watch complications (WidgetKit accessory widgets, Smart Stack) that show the next buses at the stops the rider already saved on the iPhone. The watch reuses the widget's data path almost unchanged: the iPhone syncs the saved setups (and its latest numbers) over Watch Connectivity into the watch's own App Group container, and from there everything the WidgetKit extension already does — resolve the chosen stop, count down from a snapshot, fetch `arrivals(for:at:)` itself when the numbers go old — runs on the wrist through the same `WidgetSupport/` types. No map, no setup flow, no Firebase on the watch in v1.

## 2. Goals and non-goals

### Goals (v1)

1. A watchOS app, bundled with the iOS app, that lists the rider's saved stops (`SavedSetup`, pinned first) and shows one stop's board: the next bus (badge, minutes, unit), the one after it, and the later buses there is room for — the board's readout at watch scale, in the app's own type and colours.
2. Complications for every accessory family watchOS offers — `accessoryCircular`, `accessoryRectangular`, `accessoryInline`, `accessoryCorner` — configurable to a saved stop exactly as the iOS widget is (same `SelectSavedSetupIntent`), and a Smart Stack presence with relevance around the next bus.
3. Saved setups, line colours, appearance and language follow the iPhone: the watch is a companion of the phone's history, never a second place to set things up.
4. The watch fetches arrivals for itself, directly from the transit APIs, with the same provider gate the widget applies (`WidgetProviderGate`): nothing switched off remotely, nothing needing a key or App Check.
5. Hebrew (and every other catalog language) with the same right-to-left handling the widget already has.
6. Build verification on the watchOS simulator, unit tests for everything new that is logic, and rendered PNGs of the complications in the existing screenshot pipeline.

### Non-goals (v1)

- Choosing a stop or lines on the watch (search, nearby, location). The history is the phone's.
- The rail map. `MapEngine/` compiles on watchOS (Foundation + CoreGraphics only) and stays in the target because `NextBusEntry` references `WidgetMapFrame`, but nothing draws it on a 40–49 mm screen.
- Vehicle positions, `BusProgressService`, "N STOPS" sub-lines from the watch's own fetches (the watch, like the widget, calls only `arrivals(for:at:)`; `stopsAway` shows only when the numbers came from the phone's board).
- Firebase on the watch: Analytics, Crashlytics, Remote Config, App Check. See §9.
- An independently installable watch app (`WKRunsIndependentlyOfCompanionApp`), background app refresh, notifications, haptics for approaching buses, Live Activities.
- Syncing anything from the watch back to the phone (e.g. bumping `lastUsedAt` when a stop is opened on the wrist).
- macOS: the watch app is embedded only in the iOS build of `BusBus`; the Mac build is unchanged.

## 3. What exists today, and what the watch reuses

The widget work (commits `cb0e403` … `ef7d488`) already split the app into "the app" and "a companion process that reads the app's mirror". The watch is a second such process on another device. What each piece does today:

| Piece | File(s) | Role today | On the watch |
|---|---|---|---|
| App Group suite and keys | `BusBus/Persistence/AppGroup.swift` (`AppGroup.identifier = "group.com.hayek.BusBus"`, `SharedKeys`, `SharedHistoryStore`) | The app writes history, palette, appearance, language, disabled providers; the widget reads them | Unchanged. The watch app and its widget extension share the same group id on the watch; the sync receiver writes the same keys (§7) |
| Saved setups | `BusBus/Persistence/SavedSetup.swift` (`SavedSetup`, `SavedSetups.sorted/capped`) | The history, ≤ 8 entries, Codable | Unchanged; it is the sync payload's core |
| Snapshots | `BusBus/WidgetSupport/WidgetSnapshot.swift` (`WidgetArrival`, `WidgetSnapshot`, `WidgetSnapshotStore` in `Library/Caches/WidgetSnapshots`) | The board's last numbers per setup; freshness thresholds (10 min fresh, 30 min usable) | Unchanged; the receiver writes the phone's snapshots here, the watch app and complications write their own fetches here |
| Routes | `BusBus/WidgetSupport/WidgetRoutes.swift` | Per-setup route stops for the map | Compiled, unused (no map). Not synced |
| Timeline maths | `WidgetTimelineMath.swift`, `NextBusEntry.swift` (`NextBusTimeline.entries`, `WidgetLayout`), `HistoryLookup.swift`, `WidgetMessage.swift` | Pure timeline construction, resolution of the chosen entry, message states | Unchanged, except `WidgetLayout.for` and `NextBusTimelineProvider` mention `WidgetFamily.system*`, which are `@available(watchOS, unavailable)` [SDK] — see §8 |
| Provider gate | `WidgetProviderGate.swift` (`snapshotOnly = ["mta-bustime", "metrotransit"]`, `offUntilMirrored = [transitous]`) | Which providers a companion may call | Unchanged; the same reasoning holds on the watch (no App Check → no proxy; no memory for a GTFS inflate) |
| Fetcher | `BusBusWidget/WidgetArrivalsFetcher.swift` | Per-line `arrivals(for:at:)` in a task group with a 10 s cap | Reused by both the watch app and the watch widget (membership) |
| Transit seam | `BusBus/Transit/TransitProvider.swift`, `Networking/HTTPClient.swift` (URLSession), `TransitProxy.swift`, `APIKeys.swift`, all of `Providers/` | Plain URLSession code, `nonisolated`, Sendable | Compiles as-is [SDK]: `MTABusTimeProvider`'s `MKLocalSearch` is `watchos(1.0)`; `MetroTransitProvider`'s `Compression` module exists on watchOS |
| Widget views | `BusBusWidget/Views/AccessoryViews.swift`, `WidgetReadout.swift` (`WidgetMinutes`, `WidgetSubline`, `WidgetPrimaryReadout`, `WidgetThenCard`, `WidgetArrivalRow`), `WidgetTheme.swift` (`Theme.widget`, `WidgetEnvironment`, `WidgetBadge`, `WidgetLiveDot`, `WidgetFormat`), `WidgetStates.swift` | The readout at widget sizes; the language/appearance environment | Reused: the accessory views become the complications, the readout pieces become the watch app's board |
| Intent + entity | `BusBusWidget/SelectSavedSetupIntent.swift`, `SavedSetupEntity.swift` | Editing the widget lists the history | Reused; `AppIntentConfiguration` exists on watchOS [SDK] |
| Timeline provider | `BusBusWidget/NextBusTimelineProvider.swift` | Loads history + snapshot, refetches after 60 s, builds entries, reload policy | Reused with the family guard (§8) |
| Design | `BusBus/Design/DesignTokens.swift`, `Typography.swift`, `LinePalette.swift`, `FontRegistrar.swift` (CoreText registration) | Tokens, `TypeStyle`, `LocaleAwareBusFont`, the six bundled faces | Unchanged; CoreText registration works on watchOS. The `.ttf` files must be members of both watch targets |
| Board models | `BusBus/Board/BoardModels.swift` (`BoardArrival.minutes/isImminent/countdown`, `Countdown`, `LiveState`, `ReadoutKicker`) | Rounding, NOW, "1:15" | Unchanged |
| Language | `BusBus/Persistence/AppLanguage.swift` (`#if BUSBUS_WIDGET` reads `SharedKeys.language`) | The widget speaks the app's chosen language | Same branch on the watch (§8) |
| Deep link | `WidgetDeepLink.swift` (`busbus://setup?id=…`) | Tapping a widget opens that stop's board | Same URL from a complication opens the watch app on that stop (`widgetURL` → `onOpenURL` on watchOS 10+) |
| App-only glue | `WidgetBridge.swift` (imports UIKit/AppKit, `WidgetCenter` reloads, snapshot writes on `boardDidRefresh`) | The app's side of the widget | Not on the watch. Its hooks are where the phone also pushes to the watch (§7) |
| Telemetry, flags | `BusBus/Telemetry/Telemetry.swift`, `RemoteFlags.swift`; `SettingsStore.mirrorProviderSwitches()` | Firebase in the app; the widget gets a mirror of the switches | The watch gets the same mirror through sync; no Firebase (§9) |

Data flow today (app → widget) and with the watch:

```
iPhone app (BusBus)                                  Apple Watch
┌────────────────────────────┐   WCSession           ┌──────────────────────────────┐
│ SettingsStore              │   applicationContext   │ BusBusWatch app              │
│  savedSetups ─┐            │ ───────────────────▶   │  WatchSyncReceiver (new)     │
│  palette/appearance/lang ──┼─▶ WatchSync (new)      │   └▶ AppGroup.defaults       │
│  disabledProviders         │   WatchSyncPayload      │      SharedHistoryStore      │
│ BoardViewModel.load        │   (history, palette,    │      WidgetSnapshotStore     │
│  └▶ WidgetBridge           │    appearance, language,│  WatchStopModel (new)        │
│      .boardDidRefresh ─────┼─▶ disabled, snapshots)  │   └▶ WidgetArrivalsFetcher   │
│                            │                         │       └▶ TransitProviders     │
│ App Group (phone)          │                         │            (URLSession)       │
│  ← BusBusWidget reads      │                         │ App Group (watch)             │
└────────────────────────────┘                         │  ← BusBusWatchWidget reads    │
                                                       │     NextBusTimelineProvider   │
                                                       └──────────────────────────────┘
```

## 4. Architecture decision: fetch on the watch, sync setups from the phone

**Decision:** the watch fetches arrivals itself; only the saved setups (and, opportunistically, the phone's latest snapshots) come over Watch Connectivity.

Why, grounded in the code:

- The transit clients are `nonisolated struct … : TransitProvider` over `HTTPClient` (URLSession, `os.Logger`, `OSAllocatedUnfairLock`). Nothing in `Transit/` needs UIKit, MapKit views, CoreLocation or Firebase; the widget target already proves it by compiling 26 providers without the app (`project.pbxproj`, exception set `AA00000000000000000000E3`). The same file list compiles for watchOS [SDK].
- The widget's fetch policy is already the right one for a constrained process: `WidgetArrivalsFetcher` (one `arrivals` call per line, 10 s cap, partial results accepted) and `NextBusTimelineProvider.refetchAfter = 60`.
- Relaying live numbers through the phone would make the watch only as live as the phone app is *running*; `WCSession` is unavailable in the phone's widget extension, and the iOS app is not resident. Direct fetching keeps the wrist honest whether or not the phone app is open, and Watch Connectivity carries only what changes rarely.
- The phone's snapshots are still worth sending: when the rider was just looking at the board, the watch shows the same numbers instantly, with `stopsAway` for the sub-line, and the complication needs no request of its own for the next minute.

What stays phone-only, and why the watch shows the phone's numbers for it: `WidgetProviderGate.snapshotOnly` — MTA Bus Time (proxy needs an App Check token the watch cannot mint) and Metro Transit (inflates a GTFS `stops.txt` into memory). Unchanged.

## 5. The watch app: screens and UX

Design language: the board's, as the widgets already carry it — `Theme.dark`/`.light` (`DesignTokens.swift`), Archivo Black numerals, Space Mono captions, line badges from `LinePalette`, the green/grey live dot, the `THEN` card. The watch app renders in the appearance chosen in the phone's Settings via `SharedHistoryStore.appearance()` (dark by default; `Theme.widget(renderingMode: .fullColor, …)` already resolves `Appearance` against the colour scheme). No new colours, no new faces.

### 5.1 Navigation

`NavigationStack` with the stop list as root, as `RootView` does in `BusBus/ContentView.swift`. On launch, if the history has a default entry (`HistoryLookup.defaultEntry`: pinned first, then last used), the stack starts pushed onto that stop's board — the phone's "a board that exists must be on the very first frame" rule. Back goes to the list. A complication tap (`busbus://setup?id=`) replaces the path with that stop (`WidgetDeepLink.setupID(from:)`).

### 5.2 Stop list (root)

- Title: "STOPS" (new string), Space Mono section-header style (`TypeStyles.sectionHeaderPhone`).
- One row per `SavedSetups.sorted(history)` entry: stop name (Archivo Black, `titlePhone` scaled to ~17 pt, one line, `minimumScaleFactor`), under it up to three `WidgetBadge`s (side 20) for the lines, as `HistoryLookup.subtitle` lists them in the widget editor. A pinned entry shows a small pin glyph trailing.
- If a usable snapshot exists for the entry (`WidgetTimelineMath.liveness != .expired`), the row's trailing edge shows the next bus's minutes with `WidgetMinutes` (number 22, unit 12) so the list itself is a glance. Nothing is fetched for the list; it reads stores only.
- Footer caption: "FROM YOUR IPHONE · SYNCED 12:04" (new strings) from `SharedHistoryStore.savedAt()`; when nothing was ever synced the list is replaced by the empty state.
- Empty state (no history): `WidgetMessageView`-style: title "CHOOSE YOUR STOP" (existing), detail "PICK A STOP ON YOUR IPHONE FIRST" (new; the widget's "PICK A STOP IN THE APP FIRST" is ambiguous on a watch).

### 5.3 Stop board (detail)

Vertical scroll (Digital Crown), one column, safe-area padded:

1. Header: stop name (Archivo Black ~17 pt, two lines max), `WidgetLiveDot(liveness:showsLabel:)` trailing with LIVE / AS OF 14:20 — the widget's `WidgetHeader` cut to one column (extract the shared piece rather than duplicate).
2. Primary readout: `WidgetPrimaryReadout` with a new `Metrics.watch` (badge 40, minutes 56, unit 16, kicker off, subline 12). The minutes are live: wrapped in `TimelineView(.periodic(from: .now, by: 1))` and given `context.date`, which is exactly the argument `WidgetMinutes(date:)` takes — the watch app can tick where a widget cannot. Under `isLuminanceReduced` (Always On) the dot is hidden and the schedule cadence is fine at once a minute.
3. THEN: `WidgetThenCard(style: .row)`.
4. Later buses: up to 4 `WidgetArrivalRow`s (`WidgetLayout.largeLaterRows`), then nothing — a watch list does not scroll for ever.
5. States: `WidgetMessage` cases map one to one — `.expired` reads "NO LIVE DATA" with a watch detail "CAN'T REACH THE FEED" (new) when the watch's own fetch failed and the snapshot ran out, or the existing "OPEN THE APP FOR LIVE TIMES" reworded for the wrist as "OPEN MY BUS STOP ON YOUR IPHONE" (new) for snapshot-only providers; `.noBusesDue` unchanged; `.notConfigured` cannot happen in the app (the list only offers existing entries).
6. Attribution: the provider's credit line (`TransitProvider.attribution`) in `creditLinePhone` at the foot, since the board shows data the licence asks to credit. Small; one line.

Refresh policy (`WatchStopModel`, *new*, `@MainActor @Observable`): on appear, show the stored snapshot at once; fetch through `WidgetArrivalsFetcher` when the snapshot is older than `NextBusTimelineProvider.refetchAfter` (60 s) or absent, then every `provider.refreshInterval` (20–30 s, `TransitProvider.refreshInterval`) while the scene is active; cancel on background. Every successful fetch is saved with `WidgetSnapshotStore.save` so the complications inherit it, and complications are reloaded at most every `3 * 60` s while the app is in front (mirror of `WidgetBridge.reloadInterval`). Failed fetches keep the last good numbers; liveness comes from `WidgetTimelineMath.liveness(fetchedAt:now:)`, so the dot greys at 10 min and the numbers vanish at 30 min exactly as on the phone.

### 5.4 Settings on the watch

None in v1. A single row at the foot of the stop list, "Language and colours follow your iPhone" (new string), tells the rider where to change things. Appearance and language are read from the mirror on every appear.

### 5.5 Localization and RTL

- Words: `Localizable.xcstrings` is a member of both watch targets (it is already in the widget's exception set). `Text(...)` keys resolve through the environment locale; strings built in code use `String(appLocalized:)`. The environment is set once at the root with the same modifier the widget uses: `WidgetEnvironment` reads `AppLanguage.override` (the `#if BUSBUS_WIDGET` branch → `SharedKeys.language`) and sets `\.locale` and `\.layoutDirection`, so Hebrew mirrors the whole app and `LocaleAwareBusFont` sets Hebrew solid in Archivo (system fallback), never tracked Space Mono. The watch app applies the same modifier at its root; its `NavigationStack` and lists follow the layout direction the environment sets.
- Digits and times: `Countdown.figure` prints Western digits; `WidgetFormat.time` formats with `AppLanguage.locale`. Hebrew reads "4 דק׳" with the existing "MIN" → "דק׳" translation.
- Six new English strings (§5.2–5.4) need the catalog's 17 other languages. Machine-translate in the same change, mark `needs_review`, as the catalog's own history suggests was done for the widget strings.
- The system-set families (`accessoryInline`) take their font and direction from watchOS; nothing to do.

### 5.6 Accessibility

The reused views carry their labels (`WidgetMinutes` speaks `countdown.spoken`, `WidgetLiveDot` speaks "Live data"/"Data is stale"). New rows combine children. Dynamic Type: the watch respects it; `TypeStyle.relativeTo` is set on the readout styles already, and `TypeStyle.readableMinimum = 12` holds. No text under 12 pt.

## 6. Complications (WidgetKit accessory families) and Smart Stack

One widget kind, `WidgetKind.nextBus` (same string as iOS; kinds are per bundle), one `AppIntentConfiguration` with the existing `SelectSavedSetupIntent`, provider `NextBusTimelineProvider`.

| Family | Content | Source view |
|---|---|---|
| `accessoryCircular` | Line number over the minutes and unit (or NOW); `bus.fill` when nothing is due | `AccessoryCircularView` as is; `AccessoryWidgetBackground` exists on watchOS [SDK] |
| `accessoryRectangular` | Stop name; next bus badge + minutes + time; THEN line | `AccessoryRectangularView` as is |
| `accessoryInline` | "18 · 4 MIN · ALLENBY" with `bus.fill` | `AccessoryInlineView` as is |
| `accessoryCorner` (watch only) | Line number as the corner's main text; minutes as the curved `widgetLabel` ("4 MIN", "NOW", or the stop name when nothing is due) | `AccessoryCornerView` *new* in `AccessoryViews.swift`, guarded `#if os(watchOS)` only where `.widgetLabel` is used; keep the struct compilable on iOS so `WidgetLayoutFitTests` can measure it |

Rendering modes: the accessory views already use `.widgetAccentable()` and the monochrome `Theme.widgetMonochrome` through `WidgetEnvironment`; `WidgetRenderingMode` and `showsWidgetContainerBackground` exist on watchOS [SDK].

Smart Stack: give every `NextBusEntry` a `relevance: TimelineEntryRelevance?` in the watch target (`extension NextBusEntry: TimelineEntry` lives in `NextBusTimelineProvider.swift`; the property is computed there under `#if os(watchOS)`): score 100 when the next bus is within 15 minutes and rising as it nears, 20 when numbers exist but are further out, nil when there is nothing to show. `WidgetRelevance`/`RelevanceConfiguration` (a second, relevance-driven configuration) exist on watchOS 27 [SDK] but are deferred: entry relevance is enough to surface the stack around departure times without another widget kind.

Tapping any complication opens the watch app on that stop: `.widgetURL(WidgetDeepLink.url(for: entry.setup))` as on iOS, handled by `.onOpenURL` at the watch app root.

Timeline and budget: unchanged from iOS — entries at every minute boundary (`WidgetTimelineMath.entryDates`), reload between 5 and 15 minutes (`reloadDate`), the last entry never a number. On the wrist the fetcher's 10 s cap is kept; if watchOS proves stingier with extension time, lower `WidgetArrivalsFetcher.timeout` to 8 s for the watch only (open question §12).

## 7. Data model and sync

### 7.1 Payload

*New* `BusBus/WatchSupport/WatchSyncPayload.swift` (folder new; compiled into the app, the tests and both watch targets):

```swift
nonisolated struct WatchSyncPayload: Codable, Hashable, Sendable {
    static let currentVersion = 1
    var version: Int
    var sentAt: Date
    /// SavedSetups.sorted, at most SavedSetups.limit (8).
    var history: [SavedSetup]
    var palette: [String: Int]
    var appearance: Appearance
    var language: String?
    /// Nil until the app has mirrored the remote switches — the same meaning as SharedKeys.disabledProviders.
    var disabledProviders: [String]?
    /// The newest usable snapshot per setup in `history`, if any (WidgetSnapshot.usableFor).
    var snapshots: [WidgetSnapshot]
}
```

Everything in it is already `Codable` (`SavedSetup`, `TransitStop`, `TransitLine`, `WidgetSnapshot`, `Appearance`). Size: 8 setups × 3 lines with `providerRefs`, plus 8 snapshots × ~10 arrivals, is a few KB of JSON — well inside what `updateApplicationContext` is meant for. Routes (`WidgetRoutes`) are not sent.

### 7.2 Transport

`WCSession.updateApplicationContext(["payload": data])` — "latest state wins", persisted by the system, delivered when the counterpart wakes, readable on first launch from `receivedApplicationContext`. No `transferUserInfo` queues, no `sendMessage` in v1: nothing here needs ordering or a reply.

### 7.3 Phone side — `WatchSync` (*new*, `BusBus/WatchSupport/WatchSync.swift`, `@MainActor`, `#if os(iOS)` — the `BusBus` target also builds for macOS, where `WatchConnectivity` does not exist)

- Activates `WCSession.default` at launch (from `BusBusApp.init`, after `Telemetry.start()`), when `WCSession.isSupported()` (false on iPad).
- `push(from settings: SettingsStore)` builds the payload from `settings.savedSetups`, `paletteAssignments`, `appearance`, `language`, the shared suite's `disabledProviders`, and `WidgetSnapshotStore().load(setupID:)` for each entry; skips when `!session.isWatchAppInstalled`; skips when the payload equals the last one pushed (application context updates are cheap but not free).
- Hooked exactly where `WidgetBridge` is already told: `SettingsStore.savedSetups.didSet`, `mirrorForWidget()`, `mirrorProviderSwitches()`, and `WidgetBridge.boardDidRefresh` (throttled to once a minute per setup — the board polls every 20–30 s). Also on `sessionWatchStateDidChange` (watch app just installed) and once at launch.
- Respects `WidgetBridge.isActive`'s rule: screenshot runs and tests never push (`ScreenshotMode.current == nil`, no `XCTestConfigurationFilePath`).

### 7.4 Watch side — `WatchSyncReceiver` (*new*, `BusBusWatch/WatchSyncReceiver.swift`)

- `WCSessionDelegate`; on `didReceiveApplicationContext` and at launch from `receivedApplicationContext`, decodes the payload (unknown `version` → ignore, log), then **writes the same keys the phone writes**, so every `WidgetSupport` type is unchanged: `SharedHistoryStore(defaults: AppGroup.defaults).save(history, at: sentAt)`; `SharedKeys.palette/appearance/language/disabledProviders` set directly (a small `SharedHistoryStore.write(mirror:)` helper is reasonable, tested); `WidgetSnapshotStore().save` for each snapshot newer than the one stored; `WidgetSnapshotStore().prune(keeping:)` and `WidgetRouteStore().prune(keeping:)` for removed setups.
- A payload with `sentAt` older than `SharedHistoryStore.savedAt()` is ignored (the context is latest-wins, but the guard costs nothing).
- After applying: `WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nextBus)` and a change notification the `WatchStopModel`/list observe.

### 7.5 Shared code across targets

The rule that keeps tests possible: **anything with logic lives under `BusBus/` (compiled into the app, `BusBusTests` and the watch targets by membership); the `BusBusWatch/` and `BusBusWatchWidget/` folders hold only views, the `WCSession` plumbing and `@main`.**

Membership for the two watch targets = the widget's exception set on the `BusBus` folder (`AA00000000000000000000E3`, 75 entries incl. the six `.ttf` files and both `.xcstrings`) plus `WatchSupport/*`, minus nothing. The list already excludes everything platform-bound: `Setup/` (CoreLocation, MapKit views), `Wall/`, `Board/BoardView*`, `SensorHousing`, `Telemetry/`, `Screenshots/`, `Transit/ServiceHealth.swift`, `TransitCache.swift`, `SupportedRegions.swift`, `MockTransitProvider`/`MapFixtures`, `WidgetBridge.swift`.

From the `BusBusWidget` folder, both watch targets also compile: `AppClock.swift` (needed: `BusProgressService.swift` in the shared set calls `AppClock.now`), `WidgetArrivalsFetcher.swift`, `SavedSetupEntity.swift`, `SelectSavedSetupIntent.swift`, `NextBusTimelineProvider.swift`, `Views/AccessoryViews.swift`, `Views/WidgetTheme.swift`, `Views/WidgetReadout.swift`, `Views/WidgetStates.swift`. **Not** `NextBusWidgetView.swift` (system families throughout), `WidgetMapView.swift`, `Previews.swift`, `NextBusWidget.swift`, `BusBusWidgetBundle.swift` — the watch widget gets its own three small files (§10).

## 8. Source changes required in shared code (all small, all guarded)

Verified against the SDK: `WidgetFamily.systemSmall/Medium/Large/ExtraLarge/ExtraLargePortrait` are `@available(watchOS, unavailable)` [SDK], so every mention must be fenced.

| File | Change |
|---|---|
| `BusBus/WidgetSupport/NextBusEntry.swift` — `WidgetLayout.for` | Wrap the `.systemLarge`/`.systemExtraLarge`/`.systemExtraLargePortrait` cases in `#if !os(watchOS)`; the `default` (two readout arrivals) already serves every accessory family |
| `BusBusWidget/NextBusTimelineProvider.swift` — `entries(for:family:…)` | `let large = …contains(family)` and the `configuration.largeContent == .map` read under `#if !os(watchOS)`; on watchOS `routes = nil`, `content: .laterBuses`. Add the `relevance` computed property under `#if os(watchOS)` |
| `BusBusWidget/SelectSavedSetupIntent.swift` | The `largeContent` parameter under `#if !os(watchOS)` so the complication's editor offers only "Stop" (the struct is compiled per target; the `LargeWidgetContent: AppEnum` extension can stay) |
| `BusBusWidget/Views/AccessoryViews.swift` | `#if os(iOS)` → `#if os(iOS) \|\| os(watchOS)`; add `AccessoryCornerView` |
| `BusBus/Persistence/AppLanguage.swift`, `BusBus/Transit/TransitProvider.swift` | No change: both watch targets define `BUSBUS_WIDGET`, so the mirror-reading language branch and the mock-free `TransitProviders.staged` apply. The name now means "compiled outside the app module"; renaming it `BUSBUS_COMPANION` is an optional follow-up, not v1 |
| `BusBus/Persistence/AppGroup.swift` | No change: the `#if os(macOS)` probe does not run on watchOS; `containerURL(forSecurityApplicationGroupIdentifier:)` works on watchOS with the entitlement |
| `BusBus/Persistence/SettingsStore.swift` | Calls into `WatchSync` beside the existing `WidgetBridge` calls (iOS only, via a `#if os(iOS)` in `WatchSync` itself so the call sites stay clean) |
| `BusBus/BusBusApp.swift` | `WatchSync.activate()` after `Telemetry.start()` (no-op off iOS) |
| `BusBusWidget/WidgetArrivalsFetcher.swift` | No change |
| `BusBus/Localizable.xcstrings` | Six new strings (§5) |

Nothing in `Transit/`, `MapEngine/`, `Design/`, `Board/BoardModels.swift` changes.

## 9. Networking, secrets, telemetry on watchOS

**Networking.** `URLSession.shared` works on watchOS for a foreground app and inside a WidgetKit timeline request; the system routes via the paired iPhone, Wi‑Fi or cellular. Consequences: latency is higher when tethered (seconds, not hundreds of ms) — the 10 s fetch cap and "show the last good numbers first" policy already absorb it; there is no long-lived polling in the background (the app polls only while active; complications refresh on WidgetKit's schedule); set `waitsForConnectivity = false` on the watch's session so a dead link fails fast into the stale state rather than hanging a timeline request. All provider hosts are HTTPS (ATS default). `TransitProxy.attestation` stays nil on the watch, as in the widget, so the proxy is never called (and `KeyedEndpoint.resolve` throws `missingAPIKey` for keyed providers, which `hasRequiredAPIKey` already turns into "unavailable").

**Secrets.** No keys reach the watch, in any configuration. `Config/Debug.xcconfig` (which includes `Secrets.xcconfig`) is the base configuration of the `BusBus` app target only, and `BusBusAPIKeys` lives in `Config/BusBus-Info.plist`, also app-only; the watch targets get neither, so `APIKeys.key` is nil and MTA Bus Time is snapshot-only on the watch even in Debug — the same as a Release phone widget. This is deliberate: nothing to keep out of the watch bundle. Do not add the xcconfig to the watch targets.

**Telemetry.** Firebase's own README calls watchOS "community supported" and states `FirebaseAnalytics` will not work on watchOS (checked in the resolved package, firebase-ios-sdk 12.19.2, `README.md` §watchOS). Decision for v1: **the watch links no Firebase**, like the widget. What replaces it:

- Usage signal from the phone: `Telemetry.log("watch_app_installed")` once per launch when `WCSession.default.isWatchAppInstalled`, and `watch_sync_pushed` with the setup count — enough to know adoption without a watch SDK.
- Remote switches reach the watch through the mirrored `disabledProviders` (§7), so pulling a provider from the Firebase console still stops the watch calling it within one sync. `transit_proxy_url` is irrelevant on the watch (no proxy).
- Outage reporting (`ServiceHealth`, `OutageReporter.firebase`) stays phone-side; the watch neither counts nor reports outages. A feed that is down shows as stale, then "NO LIVE DATA".
- Crashes: `os.Logger` only. Crashlytics on watchOS (which the package does build, `CLS_SDK_NAME = "Crashlytics watchOS SDK"`) is a candidate for v1.1 if crash visibility turns out to matter; it would also need `GoogleService-Info.plist` in the watch bundle and App Check would remain absent.

## 10. Xcode project changes (`BusBus.xcodeproj/project.pbxproj`, edited by hand; `objectVersion = 90`)

Two new native targets, two new synchronized folders, two new exception sets, one copy phase on the app, one scheme.

| Item | Value |
|---|---|
| Watch app target | `BusBusWatch`, `com.apple.product-type.application`, product `BusBusWatch.app`; folder `BusBusWatch/` (`PBXFileSystemSynchronizedRootGroup`) |
| Watch widget target | `BusBusWatchWidget`, `com.apple.product-type.app-extension`, product `BusBusWatchWidget.appex`; folder `BusBusWatchWidget/`; embedded in `BusBusWatch` (Copy Files, `dstSubfolderSpec = 13` PlugIns, as `AA00000000000000000000EC` does for the phone widget) |
| Bundle ids | `com.hayek.BusBus.watchkitapp` and `com.hayek.BusBus.watchkitapp.BusBusWatchWidget` (a companion watch app's id must be prefixed by the iOS app's; `.watchkitapp` is Xcode's own convention) |
| Embedding in the iOS app | `BusBus` target gains a target dependency on `BusBusWatch` and an "Embed Watch Content" `PBXCopyFilesBuildPhase` (`dstPath = "$(CONTENTS_FOLDER_PATH)/Watch"`, `dstSubfolderSpec = 16`), both with `platformFilters = (ios, );` so the macOS build of the same target neither builds nor embeds it |
| Build settings (both watch targets) | `SDKROOT = watchos`; `SUPPORTED_PLATFORMS = "watchos watchsimulator"`; `TARGETED_DEVICE_FAMILY = 4`; `WATCHOS_DEPLOYMENT_TARGET = 27.0` (already set at project level, matching iOS/macOS 27.0 — the app uses iOS 27 APIs such as `systemExtraLargePortrait`, and the same-release floor keeps one story); `SWIFT_VERSION = 5.0`; `SWIFT_APPROACHABLE_CONCURRENCY = YES`; `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`; `STRING_CATALOG_GENERATE_SYMBOLS = YES`; `SWIFT_EMIT_LOC_STRINGS = YES`; `SWIFT_ACTIVE_COMPILATION_CONDITIONS = "BUSBUS_WIDGET $(inherited)"`; `GENERATE_INFOPLIST_FILE = YES` with `INFOPLIST_FILE`; `CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM = Q7U5734Q3T`; `SKIP_INSTALL = YES`; `ENABLE_PREVIEWS = YES`; `REGISTER_APP_GROUPS = YES` |
| Watch app extras | `INFOPLIST_KEY_WKCompanionAppBundleIdentifier = com.hayek.BusBus`; `INFOPLIST_KEY_CFBundleDisplayName = "My Bus Stop"` (localised by the shared `InfoPlist.xcstrings`); `ASSETCATALOG_COMPILER_APPICON_NAME = Icon` with the root `Icon.icon` (Icon Composer) added to the target's Resources — Icon Composer renders the watch's circular icon from the same document; verify in the simulator, else add a watch `AppIcon` set |
| Info.plists (*new* in `Config/`) | `BusBusWatch-Info.plist`: `CFBundleURLTypes` for `busbus` (as `BusBus-Info.plist`), `WKApplication = YES`. `BusBusWatchWidget-Info.plist`: `NSExtension` with `com.apple.widgetkit-extension`, a copy of `BusBusWidget-Info.plist` |
| Entitlements (*new* in `Config/`) | `BusBusWatch.entitlements` and `BusBusWatchWidget.entitlements`, each `com.apple.security.application-groups = [group.com.hayek.BusBus]`. No App Attest entitlement on the watch (no proxy). The group id is per team and platform-agnostic; the watch app and its extension share the watch-side container |
| Exception sets | On the `BusBus` folder: one per watch target, the widget's list (`AA…E3`) plus `WatchSupport/…`. On the `BusBusWidget` folder: one per watch target, the nine files in §7.5. On `BusBusWatch`: an exception set giving `BusBusWatchWidget` nothing (default) |
| Tests membership | `BusBusTests`' existing exception set on `BusBusWidget` (`AA…EE`) already compiles the accessory and readout views; extend it with nothing unless `AccessoryCornerView` lands in a new file |
| Scheme | *New* shared `BusBusWatch.xcscheme` (build + run the watch app on a watch simulator, test `BusBusWatchTests`). The existing `BusBus.xcscheme` needs no change: building `BusBus` for an iOS destination builds and embeds the watch app through the dependency |
| Frameworks | Watch app: `WatchConnectivity`, `WidgetKit` (reload), `SwiftUI`, `AppIntents`. Watch widget: `WidgetKit`, `SwiftUI`, `AppIntents`. No packages |

New files (all *new*):

- `BusBus/WatchSupport/WatchSyncPayload.swift` — the payload and its version.
- `BusBus/WatchSupport/WatchSyncApply.swift` — pure "apply a payload to these stores" (takes `UserDefaults` and store directories, like `SettingsStore(defaults:shared:)` does), so it is testable from `BusBusTests`.
- `BusBus/WatchSupport/WatchSync.swift` — iOS-only `WCSession` sender.
- `BusBusWatch/BusBusWatchApp.swift` — `@main`, registers fonts (`FontRegistrar.registerBundledFonts()` as `BusBusWidgetBundle.init` does), activates the receiver, root view with `onOpenURL`.
- `BusBusWatch/WatchSyncReceiver.swift`, `BusBusWatch/WatchStopModel.swift`, `BusBusWatch/Views/StopListView.swift`, `BusBusWatch/Views/StopBoardView.swift`, `BusBusWatch/Views/WatchEnvironment.swift` (root modifier reusing `WidgetEnvironment`'s locale/appearance logic).
- `BusBusWatchWidget/BusBusWatchWidgetBundle.swift` — `@main`, registers fonts.
- `BusBusWatchWidget/WatchNextBusWidget.swift` — `AppIntentConfiguration(kind: WidgetKind.nextBus, …)`, `supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])`.
- `BusBusWatchWidget/Views/WatchWidgetView.swift` — the accessory family switch, `.widgetURL`, `WidgetEnvironment`.
- `BusBusWatchWidget/Views/Previews.swift` — `#Preview(as: .accessory…)` with `NextBusEntry.sample`.
- `Config/BusBusWatch-Info.plist`, `Config/BusBusWatchWidget-Info.plist`, `Config/BusBusWatch.entitlements`, `Config/BusBusWatchWidget.entitlements`.
- `BusBusWatchTests/` (§11).

## 11. Testing

**Unit tests in `BusBusTests` (Swift Testing, hosted by the iOS/macOS app; the shared files under `BusBus/` are already visible with `@testable import BusBus`)** — this is where the logic goes, following `BusBusTests/Persistence/SharedHistoryStoreTests.swift` (a throwaway `UserDefaults(suiteName:)` per test) and `BusBusTests/Widget/WidgetProviderGateTests.swift`:

- `Watch/WatchSyncPayloadTests.swift`: round trip; unknown version rejected; history capped at `SavedSetups.limit`; only usable snapshots included; encoded size of a full payload stays under a documented cap (e.g. 64 KB) so a future field cannot silently outgrow application context.
- `Watch/WatchSyncApplyTests.swift`: applying a payload makes `SharedHistoryStore.load()`, `paletteAssignments()`, `appearance()`, `disabledProviders()` return it; `WidgetSnapshotStore` gains the newer snapshots only; an older `sentAt` never overwrites; removed setups are pruned from a temp snapshot directory.
- `Widget/WidgetLayoutFitTests.swift`: add the watch accessory sizes (circular, rectangular, inline, corner at 40/42/44/45/46/49 mm, read from the simulators' metrics as the iPhone/iPad sizes were) to the existing measured fit run, for `en de fi he ja`. The views are the same code on iOS, so this needs no watch host.
- `Widget/NextBusTimelineTests.swift`: relevance scores (once the property lands in a shared file — put the scoring function in `WidgetTimelineMath` and call it from the watch-only property).

**Watch-hosted tests — `BusBusWatchTests` (*new* unit-test bundle, `TEST_HOST` the watch app, run on a watch simulator):** thin, for what cannot run elsewhere: `FontRegistrar.unresolvedFaces()` is empty on the watch (mirrors `BusBusTests/Design/FontRegistrationTests.swift`); `WatchStopModel` refresh policy with a stub `TransitProvider` (fetches once when the snapshot is old, not when it is 30 s fresh, keeps last good on failure, saves to the store); the receiver's decode-and-apply on a sample context dictionary.

**Build verification** (the `zcode` skill for the local loop, as `docs/plans/implementation-plan.md` prescribes; `xcodebuild` for anything scripted):

```bash
# The iOS build embeds the watch app; this is the gate that the embed phase and dependency are right.
xcodebuild -scheme BusBus -destination 'generic/platform=iOS Simulator' -quiet build
# The Mac build must be untouched by the platform-filtered embed.
xcodebuild -scheme BusBus -destination 'platform=macOS' -quiet build
# The watch app and its complications on their own.
xcodebuild -scheme BusBusWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' -quiet build
xcodebuild -scheme BusBusWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' -quiet test
# The existing suites, which now include the watch payload/apply tests and the accessory fit sizes.
xcodebuild -scheme BusBus -destination 'platform=macOS' -quiet test
```

**Screenshots.** Two extensions of `scripts/screenshots.sh`:

1. Complication PNGs: extend `BusBusTests/Widget/WidgetScreenshotTests.swift`'s `Device` with `.watch` (accessory sizes for 42, 46 and 49 mm; scale 2; vibrant and full-colour looks as the lock screen is done today) and the script's `WIDGET_DEVICES` with `watch`. The views render on the iPhone simulator run already used for the lock-screen families, so this is a table entry plus a `case`, and lands at `screenshots/widgets/watch/<language>/<look>/<family>-<state>.png`. Worth doing in v1: it is the cheapest proof that every family fits in both scripts.
2. App Store watch screenshots (required to list a watch app): a `watch` target in the script that boots a watch simulator, installs `BusBusWatch.app` from the iOS build's embedded `Watch/` folder, seeds the watch's App Group with `NextBusEntry.sample`-style history and snapshots via a `-screenshot` launch argument (`WatchScreenshotMode`, *new*, tiny — the mock provider is not in the watch target, but the sample data does not need it), and captures `simctl io screenshot` in light and dark, `en` and `he`, for the stop list and the board. Sizes are whatever App Store Connect lists for the current watch models at submission time. Do this before the first watch release, not necessarily in the first PR.

## 12. Open questions, risks, and the default for each

| # | Question / risk | Recommended default (proceed with this unless overruled) |
|---|---|---|
| 1 | Bundle id and App Store listing: `com.hayek.BusBus.watchkitapp` needs a new App ID and profiles | Automatic signing creates them; keep Xcode's `.watchkitapp` suffix. The watch app ships inside the iOS binary; no separate App Store record |
| 2 | Is the same App Group id valid on watchOS? | Yes — App Groups are per team, not per platform; the watch app and its widget share the watch-side container. Reuse `group.com.hayek.BusBus` unchanged so `AppGroup.swift` compiles as is |
| 3 | `BUSBUS_WIDGET` on the watch app reads as a misnomer | Accept for v1 (zero churn, correct semantics: "reads the mirror, links no Firebase, no mock"). Optional rename to `BUSBUS_COMPANION` in a later cleanup touching two `#if`s and three targets |
| 4 | Independent watch install (`WKRunsIndependentlyOfCompanionApp`) | No. Without the phone there is no history; the empty state says so. Revisit only if a watch-only setup flow is ever built |
| 5 | Should the watch also link Firebase (Crashlytics/Remote Config)? | No in v1 (§9). Flags arrive via the mirror; usage is logged from the phone. Crashlytics on watch is a v1.1 candidate |
| 6 | WidgetKit's time budget for a complication timeline request on the watch may be shorter than iOS | Keep `WidgetArrivalsFetcher.timeout = 10 s` and the 60 s refetch gate; the phone's synced snapshots cut the number of fetches. If timeline requests are observed timing out on device, add a watch-only `timeout` of 8 s (one initializer argument) |
| 7 | Smart Stack: entry `relevance` versus a `RelevanceConfiguration` widget | Entry relevance on the existing timeline only. `RelevanceConfiguration`/`WidgetRelevance` exist on watchOS 27 [SDK] but add a second kind and more surface; defer |
| 8 | Corner complication content | Line number as the corner glyph, the countdown as the curved label; the stop name only when nothing is due. Fit-tested like the others |
| 9 | Always On (luminance reduced) | Keep the numeral, hide the live dot, no per-second updates; `TimelineView(.periodic(by: 1))` is throttled by the system anyway |
| 10 | Fonts on the watch: six `.ttf`s in two bundles (~0.5 MB each) and CoreText registration | Fine. `FontRegistrar.registerBundledFonts()` in both `@main`s; `unresolvedFaces()` asserted empty in `BusBusWatchTests` |
| 11 | New strings need 17 translations | Add English + Hebrew by hand, machine-translate the rest marked `needs_review`, as the catalog's widget strings were handled |
| 12 | Deep link from a complication into the watch app | `.widgetURL` → `.onOpenURL` on watchOS 10+; the same `busbus://setup?id=` URL and `WidgetDeepLink.setupID(from:)`. Verified in the simulator during implementation |
| 13 | Watch simulator `simctl status_bar` override (frozen 9:41) for App Store shots | Try it; if unsupported on watch runtimes, accept the real time in the status area and keep the data staged |
| 14 | Phone-side push only happens while the iOS app runs (`WCSession` is unavailable in the widget extension) | Accepted: `applicationContext` persists, and the history changes only when the app runs anyway. The board's snapshots reach the watch only while the phone app is open, which is when they exist |
| 15 | iPad and Mac builds of `BusBus` | `WCSession.isSupported()` guards iPad; `#if os(iOS)` compiles `WatchSync` out on macOS; `platformFilters = (ios,)` keeps the embed off the Mac build. Verified by the three build commands in §11 |
| 16 | `MetroTransitProvider` and `MTABusTimeProvider` on watchOS | Both compile [SDK]; both are `snapshotOnly`, so they are never called from the watch. No change |
| 17 | The watch app polling every 20–30 s while in front, on a tethered link | Same cadence as the widget's own refetch would allow; the app is in front for seconds at a time. If battery telemetry ever matters, floor the interval at 30 s on the watch (`refreshInterval` is already clamped to 20–30) |
| 18 | Test hosting: watch-only code cannot be tested from `BusBusTests` | Rule in §7.5: logic under `BusBus/WatchSupport/`, watch folders hold views and session plumbing; `BusBusWatchTests` stays small |

## 13. Acceptance for v1

- `xcodebuild` builds in §11 all pass; `BusBusTests` and `BusBusWatchTests` green.
- With the iPhone app run once (history present), the watch app lists the stops within one sync and shows a board that counts down live, greys after 10 min without a fetch, and fetches for itself from bus.gov.il and every keyless provider in `TransitProviders.all`.
- Each of the four accessory families renders every `WidgetMessage` state and the live/stale/hours cases in `en` and `he` without clipping (fit tests), and appears in the Smart Stack around a bus's arrival.
- Pulling a provider in the Firebase console stops the watch calling it after the phone app's next launch.
- No Firebase symbols, no API keys, no `Secrets.xcconfig` content in either watch bundle (`strings` check on the built products as part of the release checklist).
