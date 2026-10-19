import Testing
import Foundation
@testable import BusBusWatch
import WatchConnectivity

/// The receiver's half of a sync: a context dictionary in, the store and the App Group updated.
@MainActor
struct WatchSyncReceiverTests {
    private func receiver() -> (WatchSyncReceiver, WatchStore) {
        let defaults = UserDefaults(suiteName: "watch-sync-\(UUID().uuidString)")!
        let temp = FileManager.default.temporaryDirectory
        let apply = WatchSyncApply(defaults: defaults,
                                   snapshots: WidgetSnapshotStore(directory: temp.appending(path: "snapshots-\(UUID().uuidString)")),
                                   routes: WidgetRouteStore(directory: temp.appending(path: "routes-\(UUID().uuidString)")))
        let store = WatchStore(history: SharedHistoryStore(defaults: defaults))
        return (WatchSyncReceiver(store: store, apply: apply), store)
    }

    private func payload(sentAt: Date) throws -> Data {
        let setup = NextBusEntry.sample(at: sentAt).setup!
        return try WatchSyncPayload.make(history: [setup], palette: ["18": 3], appearance: .dark, language: "he",
                                         disabledProviders: [], snapshot: { _ in nil }, now: sentAt).encoded()
    }

    @Test func aPayloadReachesTheStore() throws {
        let (receiver, store) = receiver()
        #expect(store.history.isEmpty)
        let outcome = receiver.apply(context: [WatchSyncPayload.contextKey: try payload(sentAt: .now)])
        #expect(outcome == .applied)
        #expect(store.history.count == 1)
        #expect(store.palette["18"] == 3)
        #expect(store.appearance == .dark)
        #expect(store.language == "he")
    }

    @Test func garbageIsUnreadable() {
        let (receiver, store) = receiver()
        #expect(receiver.apply(context: [WatchSyncPayload.contextKey: Data("nope".utf8)]) == .unreadable)
        #expect(receiver.apply(context: [:]) == .unreadable)
        #expect(store.history.isEmpty)
    }

    @Test func anOlderPayloadIsIgnored() throws {
        let (receiver, _) = receiver()
        let now = Date.now
        #expect(receiver.apply(context: [WatchSyncPayload.contextKey: try payload(sentAt: now)]) == .applied)
        let older = try payload(sentAt: now.addingTimeInterval(-60))
        #expect(receiver.apply(context: [WatchSyncPayload.contextKey: older]) == .olderThanStored)
    }
}

/// The test host is the watch app itself: it must not activate a real session while tests run.
@MainActor
struct WatchSyncReceiverActivationTests {
    @Test func theSessionIsNotActivatedUnderTests() {
        #expect(!WatchSyncReceiver.isActive)
        let receiver = WatchSyncReceiver(store: WatchStore(history: SharedHistoryStore(
            defaults: UserDefaults(suiteName: "watch-activation-\(UUID().uuidString)")!)))
        receiver.activate()
        #expect(WCSession.default.delegate == nil)
    }
}
