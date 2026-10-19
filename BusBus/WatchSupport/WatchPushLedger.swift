import Foundation

/// The iPhone's bookkeeping between pushes to the watch (`WatchSync`): whether a payload says
/// anything new, how often a board refresh may push, and what a new session forgets. Pure, so the
/// rules are tested on the Mac, where WatchSync itself is a stub.
nonisolated struct WatchPushLedger: Sendable {
    /// A board refresh may push again this soon per setup; the board polls every 20–30 s.
    static let snapshotPushInterval: TimeInterval = 60

    private(set) var lastPayload: WatchSyncPayload?
    private var lastSnapshotPush: [String: Date] = [:]

    /// Every payload carries its own time; two that differ only in that say nothing new.
    func isNew(_ payload: WatchSyncPayload) -> Bool {
        guard var last = lastPayload else { return true }
        last.sentAt = payload.sentAt
        return last != payload
    }

    /// Whether a board refresh for `setupID` may push now: not within a minute of the last one sent for it.
    func allowsSnapshotPush(setupID: String, now: Date) -> Bool {
        guard let last = lastSnapshotPush[setupID] else { return true }
        return now.timeIntervalSince(last) >= Self.snapshotPushInterval
    }

    /// After the system took the payload, and only then: a push that never went out holds nothing back.
    /// - Parameter setupID: the setup whose board refresh sent it, if one did.
    mutating func didPush(_ payload: WatchSyncPayload, snapshotFor setupID: String?, at now: Date) {
        lastPayload = payload
        if let setupID { lastSnapshotPush[setupID] = now }
    }

    /// The session came up, or the watch app was installed or removed. A reinstalled watch app
    /// starts empty, so what was sent before counts for nothing.
    mutating func sessionChanged() {
        lastPayload = nil
        lastSnapshotPush = [:]
    }
}
