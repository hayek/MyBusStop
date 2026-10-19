import Foundation

/// The history as it travels between the rider's devices: the entries, and a note of each entry
/// removed and when, so a stop taken off on one device does not come back from another's copy.
nonisolated struct SyncedHistory: Codable, Hashable, Sendable {
    var entries: [SavedSetup]
    /// Entry id → when it was removed.
    var tombstones: [String: Date]

    init(entries: [SavedSetup] = [], tombstones: [String: Date] = [:]) {
        self.entries = entries
        self.tombstones = tombstones
    }
}

/// Merges two devices' histories. Pure, so the rules can be tested without iCloud.
///
/// - The newer change to an entry wins, whichever device made it; a pin set on the phone and an
///   unpin made later on the TV end unpinned on both.
/// - A removal beats every change made before it, and loses to a use after it: the rider added the
///   stop again.
/// - The cap applies to the merged list, so two full histories come back to eight, pins kept.
nonisolated enum HistorySync {
    /// Long enough for a device left off for a while to hear about a removal, short enough that
    /// the notes do not pile up.
    static let tombstoneLifetime: TimeInterval = 60 * 24 * 60 * 60

    static func merge(local: SyncedHistory, remote: SyncedHistory, now: Date = Date()) -> SyncedHistory {
        var tombstones = local.tombstones.merging(remote.tombstones) { max($0, $1) }
        tombstones = tombstones.filter { now.timeIntervalSince($0.value) < tombstoneLifetime }

        var byID: [String: SavedSetup] = [:]
        for entry in local.entries { byID[entry.id] = entry }
        for entry in remote.entries {
            guard let mine = byID[entry.id] else {
                byID[entry.id] = entry
                continue
            }
            byID[entry.id] = newer(mine, entry)
        }

        var entries: [SavedSetup] = []
        for entry in byID.values {
            if let removedAt = tombstones[entry.id] {
                guard entry.modifiedAt > removedAt else { continue }
                tombstones[entry.id] = nil
            }
            entries.append(entry)
        }
        return SyncedHistory(entries: SavedSetups.capped(entries), tombstones: tombstones)
    }

    /// The copy changed last, with the later of the two uses. On a tie the local copy stands.
    private static func newer(_ local: SavedSetup, _ remote: SavedSetup) -> SavedSetup {
        var winner = remote.modifiedAt > local.modifiedAt ? remote : local
        winner.lastUsedAt = max(local.lastUsedAt, remote.lastUsedAt)
        return winner
    }
}
