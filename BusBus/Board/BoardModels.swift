import Foundation

/// A bus the board can draw and talk about, independent of which feed it came from.
nonisolated struct BoardBus: Identifiable, Hashable, Sendable {
    var id: String
    var lineID: String
    var lastStopIndex: Int
    var progressToNext: Double
    var stopsAway: Int
    var lastStopCode: String?
    var lastStopName: String?
    /// Only set once we have watched this bus move past a stop — no feed tells us when it happened.
    var lastStopPassedAt: Date?
    /// How old the position is, when the provider timestamps it.
    var positionAge: TimeInterval?

    /// Past this age a fix no longer answers "where is the bus now", whatever the feed claims.
    static let positionStaleAfter: TimeInterval = 120

    var hasStalePosition: Bool { (positionAge ?? 0) > Self.positionStaleAfter }

    var isAtTerminus: Bool { lastStopIndex == 0 && progressToNext < 0.02 }
}

nonisolated struct BoardArrival: Identifiable, Hashable, Sendable {
    var id: String
    var lineID: String
    var expectedAt: Date
    var isRealtime: Bool
    var delay: TimeInterval?
    var bus: BoardBus?
    /// Worked out on the device from where the bus is, because the feed gave this bus no time.
    /// Still realtime (it comes from the bus, not a timetable), just not the operator's number.
    var isEstimate = false

    /// Rounded up, because a rider who reads "2" and arrives in 2 minutes should not have missed it.
    func minutes(at now: Date) -> Int {
        max(0, Int((expectedAt.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// Under three quarters of a minute the number stops being useful and the board says so.
    func isImminent(at now: Date) -> Bool { expectedAt.timeIntervalSince(now) < 45 }

    func countdown(at now: Date) -> Countdown { Countdown(minutes: minutes(at: now)) }
}

/// The wait as the board prints it. An hour or more reads "1:15" rather than "75", which would
/// leave the rider to do the division.
nonisolated struct Countdown: Hashable, Sendable {
    var minutes: Int

    var isHours: Bool { minutes >= 60 }

    /// "45", or "1:15" once the wait reaches an hour.
    var figure: String {
        isHours ? String(format: "%d:%02d", minutes / 60, minutes % 60) : String(minutes)
    }

    /// What VoiceOver reads for the figure: "45 minutes", or "1 hour, 15 minutes".
    var spoken: String {
        guard isHours else { return String(appLocalized: "\(minutes) minutes") }
        return Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(AppLanguage.locale))
    }
}

nonisolated struct BoardSnapshot: Hashable, Sendable {
    var fetchedAt: Date
    /// Every upcoming arrival across the watched lines, soonest first.
    var arrivals: [BoardArrival]
    var buses: [BoardBus]
    /// Per line id, trimmed so the last stop is the rider's.
    var patterns: [String: RoutePattern]
    /// Per line id, terminus to terminus: what the full route view draws past the rider's stop.
    var fullPatterns: [String: RoutePattern] = [:]

    static let empty = BoardSnapshot(fetchedAt: .distantPast, arrivals: [], buses: [], patterns: [:])
}

nonisolated enum ReadoutKicker: Hashable, Sendable {
    case nextArrival, selectedBus

    var text: String {
        switch self {
        case .nextArrival: String(appLocalized: "NEXT ARRIVAL")
        case .selectedBus: String(appLocalized: "SELECTED BUS")
        }
    }
}

nonisolated struct ReadoutPrimary: Hashable, Sendable {
    var arrival: BoardArrival
    var line: TransitLine
    var colorIndex: Int
    var kicker: ReadoutKicker
}

nonisolated struct ReadoutSecondary: Hashable, Sendable {
    var arrival: BoardArrival
    var line: TransitLine
    var colorIndex: Int
}

nonisolated struct TappedBusDetail: Hashable, Sendable {
    var bus: BoardBus
    var arrival: BoardArrival?
    var line: TransitLine
    var colorIndex: Int
}

nonisolated enum TapBehaviour: String, CaseIterable, Codable, Sendable {
    /// The readout switches to the tapped bus.
    case swap
    /// The next arrival keeps its place and the tapped bus opens a card beside it.
    case beside

    var title: String {
        switch self {
        case .swap: String(appLocalized: "Swap the readout")
        case .beside: String(appLocalized: "Show beside")
        }
    }
}

nonisolated enum LiveState: Hashable, Sendable {
    case connecting, live, stale

    var label: String {
        switch self {
        case .connecting: String(appLocalized: "CONNECTING")
        case .live: String(appLocalized: "LIVE")
        case .stale: String(appLocalized: "STALE")
        }
    }
}

/// What the rider chose in setup. Persisted, so the board never asks again.
nonisolated struct BoardConfiguration: Codable, Hashable, Sendable {
    var providerID: String
    var stop: TransitStop
    /// In selection order, at most three.
    var lines: [TransitLine]
}
