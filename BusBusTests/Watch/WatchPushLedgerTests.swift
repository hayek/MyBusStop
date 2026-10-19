import Testing
import Foundation
@testable import BusBus

/// The phone's bookkeeping between pushes to the watch: what counts as new, how often a board
/// refresh may push, and what a new session forgets.
struct WatchPushLedgerTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func payload(at date: Date, palette: [String: Int] = ["18": 0]) -> WatchSyncPayload {
        let setup = NextBusEntry.sample(at: now).setup!
        return WatchSyncPayload.make(history: [setup], palette: palette, appearance: .system, language: nil,
                                     disabledProviders: nil, snapshot: { _ in nil }, now: date)
    }

    @Test func anythingIsNewBeforeTheFirstPush() {
        #expect(WatchPushLedger().isNew(payload(at: now)))
    }

    @Test func aPayloadThatDiffersOnlyInItsTimeIsNotNew() {
        var ledger = WatchPushLedger()
        ledger.didPush(payload(at: now), snapshotFor: nil, at: now)
        #expect(!ledger.isNew(payload(at: now.addingTimeInterval(90))))
        #expect(ledger.isNew(payload(at: now.addingTimeInterval(90), palette: ["18": 4])))
    }

    @Test func aBoardRefreshPushesAtMostOncePerMinutePerSetup() {
        var ledger = WatchPushLedger()
        #expect(ledger.allowsSnapshotPush(setupID: "a", now: now))
        ledger.didPush(payload(at: now), snapshotFor: "a", at: now)
        #expect(!ledger.allowsSnapshotPush(setupID: "a", now: now.addingTimeInterval(30)))
        #expect(ledger.allowsSnapshotPush(setupID: "b", now: now.addingTimeInterval(30)))
        #expect(ledger.allowsSnapshotPush(setupID: "a", now: now.addingTimeInterval(WatchPushLedger.snapshotPushInterval)))
    }

    /// A push that never went out (no session, no watch app, an error) must not hold the next one back.
    @Test func onlyASentPushStartsTheThrottle() {
        let ledger = WatchPushLedger()
        #expect(ledger.allowsSnapshotPush(setupID: "a", now: now))
        #expect(ledger.allowsSnapshotPush(setupID: "a", now: now.addingTimeInterval(1)))
    }

    /// A reinstalled watch app starts empty: what was sent before counts for nothing.
    @Test func aNewSessionForgetsWhatWasSent() {
        var ledger = WatchPushLedger()
        ledger.didPush(payload(at: now), snapshotFor: "a", at: now)
        ledger.sessionChanged()
        #expect(ledger.isNew(payload(at: now)))
        #expect(ledger.allowsSnapshotPush(setupID: "a", now: now.addingTimeInterval(1)))
    }
}
