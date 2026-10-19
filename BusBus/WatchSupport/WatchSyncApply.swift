import Foundation

/// Applies a synced payload to the watch's own App Group, writing the very keys the phone writes,
/// so every `WidgetSupport` reader is unchanged. Injectable stores, so tests use throwaway ones.
nonisolated struct WatchSyncApply: Sendable {
    // `UserDefaults` is documented thread-safe, but not marked Sendable.
    nonisolated(unsafe) var defaults: UserDefaults = AppGroup.defaults
    var snapshots = WidgetSnapshotStore()
    var routes = WidgetRouteStore()

    enum Outcome: Hashable, Sendable { case applied, olderThanStored, unreadable }

    /// Ignores a payload older than the history already stored (`SharedHistoryStore.savedAt`).
    /// Snapshots replace stored ones only when newer (`fetchedAt`). Prunes snapshots and routes of
    /// setups no longer in the history.
    @discardableResult
    func apply(_ payload: WatchSyncPayload) -> Outcome {
        guard payload.version == WatchSyncPayload.currentVersion else { return .unreadable }
        let store = SharedHistoryStore(defaults: defaults)
        if let savedAt = store.savedAt(), payload.sentAt < savedAt { return .olderThanStored }

        store.save(payload.history, at: payload.sentAt)
        store.writeMirror(palette: payload.palette, appearance: payload.appearance, language: payload.language,
                          disabledProviders: payload.disabledProviders)

        let ids = Set(payload.history.map(\.id))
        for snapshot in payload.snapshots where ids.contains(snapshot.setupID) {
            // The watch's own fetch may be newer than what the phone last saw.
            if let stored = snapshots.load(setupID: snapshot.setupID), stored.fetchedAt >= snapshot.fetchedAt { continue }
            snapshots.save(snapshot)
        }
        snapshots.prune(keeping: ids)
        routes.prune(keeping: ids)
        return .applied
    }

    /// Decodes an application context's payload, then applies it.
    @discardableResult
    func apply(contextData data: Data) -> Outcome {
        guard let payload = WatchSyncPayload.decode(data) else { return .unreadable }
        return apply(payload)
    }
}
