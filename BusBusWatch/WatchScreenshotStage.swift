import SwiftUI

/// Stages the watch app on the mock provider for App Store screenshots, the phone's
/// `ScreenshotMode` at watch scale. Off unless the app is launched with `-screenshot <screen>`,
/// which `scripts/screenshots.sh` does:
///
///     -screenshot stops|board
///     -screenshotAppearance light|dark        (default dark)
///     -screenshotLines 1|2|3                  (default 3)
///     -screenshotPlace <key>                  (MockPlace)
///     -settings.language <code>
///
/// What the phone would have synced is written into the App Group, as `WatchSyncApply` writes a
/// real payload: the phone's staged history (HARBOR GATE last) with numbers fetched just before
/// 9:41, so the list and the board read the same stores they always do.
nonisolated struct WatchScreenshotStage: Sendable {
    enum Screen: String, Sendable {
        /// The stop list.
        case stops
        /// HARBOR GATE's board.
        case board
    }

    var screen: Screen
    var appearance: Appearance
    var lineCount: Int
    var language: String?

    /// Nil for every ordinary launch.
    static let current: WatchScreenshotStage? = {
        let arguments = UserDefaults.standard
        guard let screen = arguments.string(forKey: "screenshot").flatMap(Screen.init) else { return nil }
        let lines = arguments.integer(forKey: "screenshotLines")
        return WatchScreenshotStage(
            screen: screen,
            appearance: arguments.string(forKey: "screenshotAppearance").flatMap(Appearance.init) ?? .dark,
            lineCount: (1...3).contains(lines) ? lines : 3,
            language: arguments.string(forKey: AppLanguage.defaultsKey))
    }()

    /// The phone's: two share a corridor into the stop, one or three are the main artboard.
    private var scenario: MockScenario { lineCount == 2 ? .corridor : .main }

    private var lineIDs: [String] {
        switch lineCount {
        case 1: ["41"]
        case 2: ["41", "18"]
        default: ["18", "41", "7"]
        }
    }

    /// Wipes whatever an earlier run left and writes the staged payload in its place.
    func apply() {
        let apply = WatchSyncApply()
        apply.defaults.removePersistentDomain(forName: AppGroup.identifier)
        for key in [SharedKeys.history, SharedKeys.historySavedAt] { apply.defaults.removeObject(forKey: key) }
        apply.snapshots.prune(keeping: [])
        apply.apply(payload())
    }

    private func payload() -> WatchSyncPayload {
        let now = AppClock.frozenNow
        let mock = MockTransitProvider(scenario: scenario)
        var history: [SavedSetup] = []
        var palette: [String: Int] = [:]
        // `ScreenshotMode.makeSettings`'s history, oldest first.
        var visits: [(code: String, hoursAgo: Double, lines: [String]?)] = [("CANAL-ST", 50, nil), ("PIER-FOUR", 26, nil)]
        visits.append((MapFixtures.userCode, 1, lineIDs))
        for visit in visits {
            guard let staged = mock.staged(stopCode: visit.code) else { continue }
            let lines = visit.lines.map { ids in ids.compactMap { id in staged.lines.first { $0.id == id } } } ?? staged.lines
            palette = LineColorAssigner.resolve(persisted: palette, selected: lines.map(\.id),
                                                preferred: lines.reduce(into: [:]) { $0[$1.id] = $1.brandColorIndex })
            history = SavedSetups.recording(SavedSetup(stop: staged.stop, lines: lines,
                                                       lastUsedAt: now.addingTimeInterval(-visit.hoursAgo * 3600),
                                                       providerID: mock.id),
                                            in: history)
        }
        // Every stop's numbers as the phone last saved them, twenty seconds before 9:41.
        let fetchedAt = now.addingTimeInterval(-20)
        let snapshots = history.map { setup in
            let arrivals = setup.lines.flatMap { line in
                mock.arrivals(for: line, at: setup.stop, now: fetchedAt).map { arrival in
                    let bus = mock.position(of: arrival, line: line, at: setup.stop, now: fetchedAt)
                    return WidgetArrival(lineID: line.id, expectedAt: arrival.expectedAt, isRealtime: arrival.isRealtime,
                                         stopsAway: bus?.stopsAway, progressToNext: bus?.progressToNext,
                                         busID: bus.map { _ in arrival.tripId ?? line.id })
                }
            }
            return WidgetSnapshot(setupID: setup.id, fetchedAt: fetchedAt,
                                  arrivals: arrivals.sorted { $0.expectedAt < $1.expectedAt })
        }
        return WatchSyncPayload(sentAt: now, history: SavedSetups.sorted(history), palette: palette,
                                appearance: appearance, language: language, disabledProviders: [],
                                snapshots: snapshots)
    }
}

extension TimelineViewDefaultContext {
    /// The tick's date, unless screenshots have frozen the clock at 9:41 (`AppClock`).
    nonisolated var now: Date { AppClock.isStaging ? AppClock.now : date }
}
