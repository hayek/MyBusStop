import Foundation

/// The history as the widget offers and resolves it: the same list, in the same order, as the
/// history picker on the stop list.
nonisolated enum HistoryLookup {
    /// What a widget's chosen entry comes to against the history as it is now.
    enum Resolution: Hashable, Sendable {
        case setup(SavedSetup)
        /// Nothing has been watched yet, so there is nothing to offer.
        case noHistory
        /// The widget was set to an entry that has since been removed from the history. It says so
        /// rather than quietly showing some other stop under the rider's nose.
        case missing
    }

    /// Pinned first, then whatever was used most recently — the picker's order.
    static func sorted(_ history: [SavedSetup]) -> [SavedSetup] { SavedSetups.sorted(history) }

    /// The entries with these ids, in the order asked for; ids no longer in the history are dropped.
    static func entries(ids: [String], in history: [SavedSetup]) -> [SavedSetup] {
        ids.compactMap { id in history.first { $0.id == id } }
    }

    /// What an unconfigured widget shows: the top of the picker.
    static func defaultEntry(in history: [SavedSetup]) -> SavedSetup? { sorted(history).first }

    /// The chosen entry, or the default when none was chosen.
    static func resolve(id: String?, in history: [SavedSetup]) -> Resolution {
        guard !history.isEmpty else { return .noHistory }
        guard let id else { return defaultEntry(in: history).map(Resolution.setup) ?? .noHistory }
        return history.first { $0.id == id }.map(Resolution.setup) ?? .missing
    }

    /// "18 · 41 · 7": the lines watched there, as the widget's editor lists them.
    static func subtitle(for setup: SavedSetup) -> String {
        setup.lines.map(\.shortName).joined(separator: " · ")
    }
}
