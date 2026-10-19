import Foundation

/// A saved stop at a glance: its lines and the next buses on each, as Apple TV's home row and its
/// Top Shelf show it. Built from the history and the snapshots the board saves on every refresh,
/// so neither has to ask the network before it can draw.
nonisolated struct StopGlance: Identifiable, Hashable, Sendable {
    nonisolated struct LineGlance: Hashable, Sendable {
        var line: TransitLine
        /// The next arrivals on this line, soonest first: at most `StopGlances.arrivalsPerLine`.
        var next: [Countdown]
    }

    var setup: SavedSetup
    var lines: [LineGlance]
    /// When the numbers were fetched; nil when there are none to show.
    var fetchedAt: Date?

    var id: String { setup.id }
    /// Where selecting it goes: the stop's board (`WidgetDeepLink`, which the app already opens).
    var deepLink: URL { WidgetDeepLink.url(for: setup) }
    var hasNumbers: Bool { fetchedAt != nil }
}

nonisolated enum StopGlances {
    static let arrivalsPerLine = 2
    /// Past this a snapshot is refetched before it is shown (the widget's own rule).
    static let refetchAfter: TimeInterval = 60

    /// Every saved stop, pinned first then most recent, with the numbers known for it at `now`.
    /// Numbers older than a widget would show (`WidgetSnapshot.usableFor`) are left off.
    static func build(history: [SavedSetup], snapshot: (String) -> WidgetSnapshot?, now: Date) -> [StopGlance] {
        TVStopOrder.ordered(history).map { setup in
            let numbers = snapshot(setup.id).flatMap {
                now.timeIntervalSince($0.fetchedAt) <= WidgetSnapshot.usableFor ? $0 : nil
            }
            let upcoming = numbers?.upcoming(at: now) ?? []
            let lines = setup.lines.map { line in
                StopGlance.LineGlance(line: line, next: upcoming.filter { $0.lineID == line.id }
                    .prefix(arrivalsPerLine).map { $0.board.countdown(at: now) })
            }
            return StopGlance(setup: setup, lines: lines, fetchedAt: numbers?.fetchedAt)
        }
    }

    /// The saved stops whose numbers are missing or older than `refetchAfter`.
    static func needingFetch(history: [SavedSetup], snapshot: (String) -> WidgetSnapshot?, now: Date) -> [SavedSetup] {
        history.filter { setup in
            snapshot(setup.id).map { now.timeIntervalSince($0.fetchedAt) > refetchAfter } ?? true
        }
    }
}
