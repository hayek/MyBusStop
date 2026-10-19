import Foundation

/// A stop and the lines watched there, kept so it can be returned to in one tap.
///
/// The lines are stored whole rather than by id alone: resuming an entry goes straight to the
/// map, and re-fetching the stop's lines first would put a spinner — and a failure — in front of
/// something the rider has already chosen once.
nonisolated struct SavedSetup: Identifiable, Codable, Hashable, Sendable {
    var stop: TransitStop
    var lines: [TransitLine]
    var lastUsedAt: Date
    var pinned: Bool
    /// The provider the stop and lines came from, so resuming the entry in another city still
    /// polls the right feed. Nil for entries saved before providers followed location.
    var providerID: String?
    /// The last time this device used, pinned or unpinned the entry: which copy wins when the
    /// history is merged with another device's (`HistorySync`).
    var modifiedAt: Date

    /// The same stop with the same lines is one entry, however often it is used.
    var id: String { Self.identifier(stop: stop, lineIDs: lines.map(\.id)) }
    var lineIDs: [String] { lines.map(\.id) }

    init(stop: TransitStop, lines: [TransitLine], lastUsedAt: Date = Date(), pinned: Bool = false,
         providerID: String? = nil, modifiedAt: Date? = nil) {
        self.stop = stop
        self.lines = lines
        self.lastUsedAt = lastUsedAt
        self.pinned = pinned
        self.providerID = providerID
        self.modifiedAt = modifiedAt ?? lastUsedAt
    }

    private enum CodingKeys: String, CodingKey { case stop, lines, lastUsedAt, pinned, providerID, modifiedAt }

    /// Entries saved before the history synced have no `modifiedAt`: their last use stands in.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stop = try container.decode(TransitStop.self, forKey: .stop)
        lines = try container.decode([TransitLine].self, forKey: .lines)
        lastUsedAt = try container.decode(Date.self, forKey: .lastUsedAt)
        pinned = try container.decode(Bool.self, forKey: .pinned)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? lastUsedAt
    }

    static func identifier(stop: TransitStop, lineIDs: [String]) -> String {
        ([stop.code] + lineIDs.sorted()).joined(separator: "|")
    }
}

nonisolated enum SavedSetups {
    /// Enough to cover the handful of stops anyone actually uses, few enough to stay scannable.
    static let limit = 8

    /// Pinned first, then whatever was used most recently.
    static func sorted(_ setups: [SavedSetup]) -> [SavedSetup] {
        setups.sorted { left, right in
            if left.pinned != right.pinned { return left.pinned }
            if left.lastUsedAt != right.lastUsedAt { return left.lastUsedAt > right.lastUsedAt }
            return left.id < right.id
        }
    }

    /// Drops the oldest unpinned entries once the list outgrows the cap. A pin is a promise that
    /// the entry stays, so pins are never aged out even when they alone exceed the cap.
    static func capped(_ setups: [SavedSetup], limit: Int = limit) -> [SavedSetup] {
        let ordered = sorted(setups)
        guard ordered.count > limit else { return ordered }
        var kept: [SavedSetup] = []
        var unpinnedAllowance = max(0, limit - ordered.filter(\.pinned).count)
        for setup in ordered {
            if setup.pinned {
                kept.append(setup)
            } else if unpinnedAllowance > 0 {
                kept.append(setup)
                unpinnedAllowance -= 1
            }
        }
        return kept
    }

    /// Records a setup as just used. An entry that already exists keeps its pin — reusing an entry
    /// must never quietly unpin it.
    static func recording(_ setup: SavedSetup, in setups: [SavedSetup], limit: Int = limit) -> [SavedSetup] {
        var entry = setup
        if let existing = setups.first(where: { $0.id == setup.id }) { entry.pinned = existing.pinned }
        return capped(setups.filter { $0.id != entry.id } + [entry], limit: limit)
    }

    static func togglingPin(id: String, in setups: [SavedSetup], at date: Date = Date()) -> [SavedSetup] {
        sorted(setups.map { setup in
            guard setup.id == id else { return setup }
            var copy = setup
            copy.pinned.toggle()
            copy.modifiedAt = date
            return copy
        })
    }

    static func removing(id: String, from setups: [SavedSetup]) -> [SavedSetup] {
        sorted(setups.filter { $0.id != id })
    }
}

nonisolated enum RecentSearches {
    static let limit = 6

    /// Most recent first, no duplicates, and nothing so short it would match everything.
    static func recording(_ term: String, in terms: [String], limit: Int = limit) -> [String] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return terms }
        return Array(([trimmed] + terms.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame })
            .prefix(limit))
    }
}
