import Foundation

/// The order Apple TV shows the saved stops in, on its home row and when the remote flips between
/// boards: pinned first, then the most recently used — the history's own order.
nonisolated enum TVStopOrder {
    static func ordered(_ history: [SavedSetup]) -> [SavedSetup] { SavedSetups.sorted(history) }

    /// The stop `step` places along from `id` in `ordered`, taken as it is (the board keeps the
    /// order it was opened with), wrapping at either end; nil when there is no other.
    static func neighbour(of id: String, step: Int, in ordered: [SavedSetup]) -> SavedSetup? {
        guard ordered.count > 1, let index = ordered.firstIndex(where: { $0.id == id }) else { return nil }
        let count = ordered.count
        return ordered[((index + step) % count + count) % count]
    }

    /// The upcoming bus after `current` for the remote's select button, in the order they arrive;
    /// nil after the last, which lets go of the selection.
    static func nextBus(after current: String?, in busIDs: [String]) -> String? {
        var seen = Set<String>()
        let unique = busIDs.filter { seen.insert($0).inserted }
        guard let current, let index = unique.firstIndex(of: current) else { return unique.first }
        return index + 1 < unique.count ? unique[index + 1] : nil
    }
}
