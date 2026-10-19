import Testing
import Foundation
@testable import BusBus

/// The watch writes a synced payload under the very keys the phone writes, so the widget code
/// reads it unchanged.
struct WatchSyncApplyTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "watch-sync-\(UUID().uuidString)")!
    }

    private func directory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)")
    }

    private func applier() -> WatchSyncApply {
        WatchSyncApply(defaults: suite(), snapshots: WidgetSnapshotStore(directory: directory("snapshots")),
                       routes: WidgetRouteStore(directory: directory("routes")))
    }

    private func setup(_ code: String) -> SavedSetup {
        SavedSetup(stop: TransitStop(code: code, name: "STOP \(code)", city: nil, location: GeoPoint(lat: 32, lon: 34)),
                   lines: [TransitLine(id: "18", shortName: "18", headsign: nil, agency: nil, origin: nil,
                                       destination: nil, isAccessible: nil, brandColorIndex: nil)],
                   lastUsedAt: now)
    }

    private func snapshot(_ setup: SavedSetup, fetchedAgo age: TimeInterval) -> WidgetSnapshot {
        WidgetSnapshot(setupID: setup.id, fetchedAt: now.addingTimeInterval(-age),
                       arrivals: [WidgetArrival(lineID: "18", expectedAt: now.addingTimeInterval(240 - age),
                                                isRealtime: true, stopsAway: 3)])
    }

    private func payload(_ history: [SavedSetup], snapshots: [WidgetSnapshot] = [], sentAt: Date? = nil,
                         language: String? = "he", disabled: [String]? = ["mta-bustime"]) -> WatchSyncPayload {
        WatchSyncPayload(sentAt: sentAt ?? now, history: history, palette: ["18": 4], appearance: .light,
                         language: language, disabledProviders: disabled, snapshots: snapshots)
    }

    @Test func writesWhatTheWidgetCodeReads() {
        let apply = applier()
        let entry = setup("21470")
        #expect(apply.apply(payload([entry])) == .applied)
        let store = SharedHistoryStore(defaults: apply.defaults)
        #expect(store.load() == [entry])
        #expect(store.savedAt() == now)
        #expect(store.paletteAssignments() == ["18": 4])
        #expect(store.appearance() == .light)
        #expect(store.disabledProviders() == ["mta-bustime"])
        #expect(apply.defaults.string(forKey: SharedKeys.language) == "he")
    }

    /// Following the device on the phone, or switches not yet mirrored there, clear the keys.
    @Test func nilValuesRemoveTheirKeys() {
        let apply = applier()
        apply.apply(payload([setup("1")]))
        apply.apply(payload([setup("1")], sentAt: now.addingTimeInterval(60), language: nil, disabled: nil))
        #expect(apply.defaults.object(forKey: SharedKeys.language) == nil)
        #expect(apply.defaults.object(forKey: SharedKeys.disabledProviders) == nil)
        #expect(SharedHistoryStore(defaults: apply.defaults).disabledProviders() == nil)
    }

    /// The watch's own fetch may be newer than what the phone last saw; it is kept.
    @Test func onlyNewerSnapshotsReplaceStoredOnes() {
        let apply = applier()
        let first = setup("1"), second = setup("2")
        let watchOwn = snapshot(first, fetchedAgo: 10)
        let watchOld = snapshot(second, fetchedAgo: 300)
        apply.snapshots.save(watchOwn)
        apply.snapshots.save(watchOld)
        let phoneOld = snapshot(first, fetchedAgo: 120), phoneNew = snapshot(second, fetchedAgo: 20)
        apply.apply(payload([first, second], snapshots: [phoneOld, phoneNew]))
        #expect(apply.snapshots.load(setupID: first.id) == watchOwn)
        #expect(apply.snapshots.load(setupID: second.id) == phoneNew)
    }

    @Test func anOlderPayloadChangesNothing() {
        let apply = applier()
        let current = setup("current")
        apply.apply(payload([current]))
        let stale = payload([setup("stale")], snapshots: [snapshot(setup("stale"), fetchedAgo: 0)],
                            sentAt: now.addingTimeInterval(-60), language: "de")
        #expect(apply.apply(stale) == .olderThanStored)
        #expect(SharedHistoryStore(defaults: apply.defaults).load() == [current])
        #expect(apply.defaults.string(forKey: SharedKeys.language) == "he")
        #expect(apply.snapshots.load(setupID: setup("stale").id) == nil)
    }

    @Test func removedSetupsArePruned() throws {
        let apply = applier()
        let kept = setup("kept"), removed = setup("removed")
        apply.snapshots.save(snapshot(removed, fetchedAgo: 0))
        apply.routes.save(WidgetRoutes(setupID: removed.id, lines: ["18": [MapStopInput(code: "1", name: "A")]]))
        apply.routes.save(WidgetRoutes(setupID: kept.id, lines: ["18": [MapStopInput(code: "1", name: "A")]]))
        apply.apply(payload([kept], snapshots: [snapshot(kept, fetchedAgo: 0)]))
        #expect(apply.snapshots.load(setupID: removed.id) == nil)
        #expect(apply.routes.load(setupID: removed.id) == nil)
        #expect(apply.snapshots.load(setupID: kept.id) != nil)
        #expect(apply.routes.load(setupID: kept.id) != nil)
    }

    @Test func contextDataIsDecodedFirst() throws {
        let apply = applier()
        #expect(apply.apply(contextData: Data("garbage".utf8)) == .unreadable)
        #expect(SharedHistoryStore(defaults: apply.defaults).stored() == nil)
        #expect(apply.apply(contextData: try payload([setup("1")]).encoded()) == .applied)
        #expect(SharedHistoryStore(defaults: apply.defaults).load().map(\.stop.code) == ["1"])
    }

    @Test func writeMirrorWritesTheFourKeysTogether() {
        let defaults = suite()
        let store = SharedHistoryStore(defaults: defaults)
        store.writeMirror(palette: ["41": 2], appearance: .dark, language: "fi", disabledProviders: ["x"])
        #expect(store.paletteAssignments() == ["41": 2])
        #expect(store.appearance() == .dark)
        #expect(defaults.string(forKey: SharedKeys.language) == "fi")
        #expect(store.disabledProviders() == ["x"])
    }
}
