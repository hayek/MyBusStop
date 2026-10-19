import SwiftUI

/// What a widget says when it has no numbers to show, in words the board already uses.
nonisolated enum WidgetMessage: Hashable, Sendable {
    /// The history is empty: the app has to be used once first.
    case noHistory
    /// The entry the widget was set to has been removed from the history.
    case notConfigured
    /// The last numbers are too old to count down from.
    case expired
    /// Current, and nothing is coming.
    case noBusesDue

    init?(_ entry: NextBusEntry) {
        switch entry.state {
        case .noHistory: self = .noHistory
        case .notConfigured: self = .notConfigured
        case .board:
            if entry.liveness == .expired { self = .expired } else if entry.arrivals.isEmpty { self = .noBusesDue } else { return nil }
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .noHistory, .notConfigured: "CHOOSE YOUR STOP"
        case .expired: "NO LIVE DATA"
        case .noBusesDue: "NO BUSES DUE"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .noHistory: "PICK A STOP IN THE APP FIRST"
        case .notConfigured: "EDIT THE WIDGET TO PICK ONE OF MY STOPS"
        case .expired: "OPEN THE APP FOR LIVE TIMES"
        case .noBusesDue: "NOTHING SCHEDULED RIGHT NOW"
        }
    }

    /// The detail on the wrist, where "the app" could be either: a stop only the iPhone can fetch
    /// for says so (the watch board's wording); everything else reads as on the phone.
    func watchDetail(snapshotOnly: Bool) -> LocalizedStringKey {
        self == .expired && snapshotOnly ? "OPEN MY BUS STOP ON YOUR IPHONE" : detail
    }
}
