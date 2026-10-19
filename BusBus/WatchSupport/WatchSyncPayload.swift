import Foundation

/// What the iPhone sends the watch over Watch Connectivity: the history and what it takes to draw
/// it. Latest state wins (`WCSession.updateApplicationContext`), so it is whole, never a diff.
nonisolated struct WatchSyncPayload: Codable, Hashable, Sendable {
    static let currentVersion = 1
    /// The key under which the encoded payload sits in the application context dictionary.
    static let contextKey = "payload"
    /// A full payload (8 setups × 3 lines, 8 snapshots × ~10 arrivals) is a few KB; this is the
    /// ceiling a test holds it under so a new field cannot outgrow the context quietly.
    static let encodedSizeCap = 64 * 1024

    var version: Int = currentVersion
    var sentAt: Date
    /// `SavedSetups.sorted`, at most `SavedSetups.limit`.
    var history: [SavedSetup]
    var palette: [String: Int]
    var appearance: Appearance
    var language: String?
    /// Nil until the app has mirrored the remote switches — `SharedKeys.disabledProviders`'s meaning.
    var disabledProviders: [String]?
    /// The newest usable snapshot per setup in `history`.
    var snapshots: [WidgetSnapshot]

    /// Builds the payload the phone sends: history capped and sorted, and only snapshots that are
    /// still usable at `now` (`WidgetTimelineMath.liveness != .expired`) for setups in the history.
    static func make(history: [SavedSetup], palette: [String: Int], appearance: Appearance, language: String?,
                     disabledProviders: Set<String>?, snapshot: (String) -> WidgetSnapshot?, now: Date) -> WatchSyncPayload {
        // `capped` keeps every pin even past the limit; the watch gets the limit, pins first.
        let history = Array(SavedSetups.capped(history).prefix(SavedSetups.limit))
        let snapshots = history.compactMap { setup -> WidgetSnapshot? in
            guard let stored = snapshot(setup.id), stored.setupID == setup.id,
                  WidgetTimelineMath.liveness(fetchedAt: stored.fetchedAt, now: now) != .expired else { return nil }
            return stored
        }
        return WatchSyncPayload(sentAt: now, history: history, palette: palette, appearance: appearance,
                                language: language, disabledProviders: disabledProviders.map { $0.sorted() },
                                snapshots: snapshots)
    }

    /// JSON with the stores' own date encoding, so a date survives the trip to the second's fraction
    /// and "newer than stored" compares like with like.
    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Nil for a payload this build does not read (`version != currentVersion`) or bad data.
    static func decode(_ data: Data) -> WatchSyncPayload? {
        guard let payload = try? JSONDecoder().decode(WatchSyncPayload.self, from: data),
              payload.version == currentVersion else { return nil }
        return payload
    }
}
