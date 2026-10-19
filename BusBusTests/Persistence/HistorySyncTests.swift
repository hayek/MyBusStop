import Testing
import Foundation
@testable import BusBus

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

private func setup(_ code: String, used: Double = 0, modified: Double? = nil, pinned: Bool = false) -> SavedSetup {
    let line = TransitLine(id: "1", shortName: "1", headsign: nil, agency: nil, origin: nil, destination: nil,
                           isAccessible: nil, brandColorIndex: nil)
    return SavedSetup(stop: TransitStop(code: code, name: "STOP \(code)", city: nil, location: GeoPoint(lat: 0, lon: 0)),
                      lines: [line], lastUsedAt: at(used), pinned: pinned, modifiedAt: modified.map(at))
}

private func codes(_ history: SyncedHistory) -> [String] { history.entries.map(\.stop.code) }

struct HistorySyncTests {

    @Test func entriesFromBothSidesAreKept() {
        let merged = HistorySync.merge(local: SyncedHistory(entries: [setup("a", used: 1)]),
                                       remote: SyncedHistory(entries: [setup("b", used: 2)]), now: at(10))
        #expect(codes(merged) == ["b", "a"])
    }

    /// Pinned on the phone, unpinned later on the TV: unpinned wins, wherever it is merged.
    @Test func theLaterChangeToAnEntryWins() {
        let phone = SyncedHistory(entries: [setup("a", used: 1, modified: 5, pinned: true)])
        let tv = SyncedHistory(entries: [setup("a", used: 1, modified: 8, pinned: false)])
        #expect(HistorySync.merge(local: phone, remote: tv, now: at(10)).entries.first?.pinned == false)
        #expect(HistorySync.merge(local: tv, remote: phone, now: at(10)).entries.first?.pinned == false)
    }

    @Test func theLaterUseIsKeptWhicheverCopyWins() {
        let local = SyncedHistory(entries: [setup("a", used: 9, modified: 1)])
        let remote = SyncedHistory(entries: [setup("a", used: 2, modified: 5, pinned: true)])
        let entry = HistorySync.merge(local: local, remote: remote, now: at(10)).entries.first
        #expect(entry?.pinned == true)
        #expect(entry?.lastUsedAt == at(9))
    }

    @Test func aRemovalBeatsAnOlderCopy() {
        let tv = SyncedHistory(entries: [setup("a", used: 1, modified: 1), setup("b", used: 2)])
        let phone = SyncedHistory(entries: [setup("b", used: 2)], tombstones: [setup("a").id: at(3)])
        let merged = HistorySync.merge(local: tv, remote: phone, now: at(10))
        #expect(codes(merged) == ["b"])
        #expect(merged.tombstones[setup("a").id] == at(3))
    }

    /// Chosen again after it was removed: the rider wants it back.
    @Test func aUseAfterTheRemovalBringsTheEntryBack() {
        let tv = SyncedHistory(entries: [setup("a", used: 6, modified: 6)])
        let phone = SyncedHistory(tombstones: [setup("a").id: at(3)])
        let merged = HistorySync.merge(local: tv, remote: phone, now: at(10))
        #expect(codes(merged) == ["a"])
        #expect(merged.tombstones.isEmpty)
    }

    @Test func theLaterOfTwoRemovalsIsKept() {
        let id = setup("a").id
        let merged = HistorySync.merge(local: SyncedHistory(tombstones: [id: at(3)]),
                                       remote: SyncedHistory(tombstones: [id: at(7)]), now: at(10))
        #expect(merged.tombstones[id] == at(7))
    }

    @Test func oldRemovalsAreForgotten() {
        let old = start
        let now = start.addingTimeInterval(HistorySync.tombstoneLifetime + 1)
        let merged = HistorySync.merge(local: SyncedHistory(tombstones: ["gone": old]), remote: SyncedHistory(), now: now)
        #expect(merged.tombstones.isEmpty)
    }

    @Test func theCapAppliesToTheMergedListAndKeepsPins() {
        let local = SyncedHistory(entries: (0..<8).map { setup("l\($0)", used: Double($0)) })
        var remoteEntries = (0..<8).map { setup("r\($0)", used: Double($0) + 0.5) }
        remoteEntries[0].pinned = true
        let merged = HistorySync.merge(local: local, remote: SyncedHistory(entries: remoteEntries), now: at(100))
        #expect(merged.entries.count == SavedSetups.limit)
        #expect(merged.entries.first?.stop.code == "r0")
        #expect(merged.entries.contains { $0.stop.code == "l7" })
        #expect(!merged.entries.contains { $0.stop.code == "l0" })
    }

    /// What `CloudHistory` relies on to stop two devices sending the same list back and forth.
    @Test func mergingAgainChangesNothing() {
        let local = SyncedHistory(entries: [setup("a", used: 1), setup("b", used: 4, pinned: true)],
                                  tombstones: ["c": at(2)])
        let remote = SyncedHistory(entries: [setup("d", used: 3), setup("a", used: 5, modified: 5)])
        let once = HistorySync.merge(local: local, remote: remote, now: at(10))
        #expect(HistorySync.merge(local: once, remote: once, now: at(10)) == once)
        #expect(HistorySync.merge(local: once, remote: remote, now: at(10)) == once)
        #expect(HistorySync.merge(local: local, remote: once, now: at(10)) == once)
    }

    /// Saved before the history synced: no `modifiedAt` in the JSON, so the last use stands in.
    @Test func anEntryWithoutAChangeDateDecodesWithItsLastUse() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(setup("a", used: 4, modified: 9)))
                                    as? [String: Any])
        json["modifiedAt"] = nil
        let decoded = try JSONDecoder().decode(SavedSetup.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.modifiedAt == at(4))
    }

    @Test func pinningStampsTheChange() {
        let pinned = SavedSetups.togglingPin(id: setup("a").id, in: [setup("a", used: 1)], at: at(7))
        #expect(pinned.first?.modifiedAt == at(7))
    }
}

/// A dictionary standing in for iCloud's key-value store.
@MainActor private final class MemoryCloudStore: CloudDataStore {
    var values: [String: Data] = [:]
    var writes = 0
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ data: Data?, forKey key: String) {
        writes += 1
        values[key] = data
    }
    func synchronize() -> Bool { true }
}

@MainActor
struct CloudHistoryTests {
    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "cloud-\(UUID().uuidString)")!)
    }

    private func line(_ id: String) -> TransitLine {
        TransitLine(id: id, shortName: id, headsign: nil, agency: nil, origin: nil, destination: nil,
                    isAccessible: nil, brandColorIndex: nil)
    }

    private func stop(_ code: String) -> TransitStop {
        TransitStop(code: code, name: "STOP \(code)", city: nil, location: GeoPoint(lat: 0, lon: 0))
    }

    /// Two devices on one iCloud store: a stop saved on one appears on the other, and a removal
    /// on the other reaches the first.
    @Test func stopsAndRemovalsTravelBetweenDevices() {
        let cloud = MemoryCloudStore()
        let phone = makeStore(), tv = makeStore()
        let phoneSync = CloudHistory(store: cloud), tvSync = CloudHistory(store: cloud)
        phoneSync.attach(phone)
        tvSync.attach(tv)

        phone.apply(stop: stop("41122"), lines: [line("18")], providerID: "mock")
        tvSync.pull()
        #expect(tv.savedSetups.map(\.stop.code) == ["41122"])

        tv.removeSetup(tv.savedSetups[0].id)
        phoneSync.pull()
        #expect(phone.savedSetups.isEmpty)
    }

    /// Two windows of one Mac, each with its own store: a change in either reaches iCloud and the
    /// other, and closing one leaves the other syncing.
    @Test func everyWindowsStoreStaysInStep() {
        let cloud = MemoryCloudStore()
        let sync = CloudHistory(store: cloud)
        let first = makeStore()
        var second: SettingsStore? = makeStore()
        sync.attach(first)
        sync.attach(second!)

        second!.apply(stop: stop("41122"), lines: [line("18")], providerID: "mock")
        #expect(first.savedSetups.map(\.stop.code) == ["41122"])

        first.removeSetup(first.savedSetups[0].id)
        #expect(second!.savedSetups.isEmpty)

        second = nil
        first.apply(stop: stop("50000"), lines: [line("7")], providerID: "mock")
        let stored = try? JSONDecoder().decode(SyncedHistory.self, from: cloud.values[CloudHistory.key] ?? Data())
        #expect(stored?.entries.map(\.stop.code) == ["50000"])
    }

    @Test func aNewDeviceWithNothingWritesNothing() {
        let cloud = MemoryCloudStore()
        CloudHistory(store: cloud).attach(makeStore())
        #expect(cloud.writes == 0)
    }

    @Test func takingBackWhatWasSentWritesNothing() {
        let cloud = MemoryCloudStore()
        let phone = makeStore()
        let sync = CloudHistory(store: cloud)
        sync.attach(phone)
        phone.apply(stop: stop("41122"), lines: [line("18")], providerID: "mock")
        let writes = cloud.writes
        sync.pull()
        sync.pull()
        #expect(cloud.writes == writes)
    }

    /// A newer build's format is left for that build rather than overwritten.
    @Test func anUnreadableCloudCopyIsLeftAlone() {
        let cloud = MemoryCloudStore()
        cloud.values[CloudHistory.key] = Data("not json".utf8)
        let phone = makeStore()
        CloudHistory(store: cloud).attach(phone)
        phone.apply(stop: stop("41122"), lines: [line("18")], providerID: "mock")
        #expect(cloud.values[CloudHistory.key] == Data("not json".utf8))
        #expect(phone.savedSetups.count == 1)
    }

    @Test func removingAStopLeavesATombstone() {
        let store = makeStore()
        store.apply(stop: stop("41122"), lines: [line("18")], providerID: "mock")
        let id = store.savedSetups[0].id
        store.removeSetup(id, at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(store.historyTombstones[id] == Date(timeIntervalSince1970: 1_800_000_000))
    }
}
