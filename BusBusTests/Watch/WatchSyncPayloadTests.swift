import Testing
import Foundation
@testable import BusBus

/// What the phone sends the watch: whole, capped, and only numbers still worth showing.
struct WatchSyncPayloadTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func line(_ id: String) -> TransitLine {
        TransitLine(id: id, shortName: id, headsign: "CENTRAL STATION", agency: "Dan", origin: "Bat Yam, Herzl",
                    destination: "Tel Aviv, Central Station", isAccessible: true, brandColorIndex: nil,
                    providerRefs: ["routeDesc": "\(id)-1-#", "operatorRef": "5", "direction": "1"])
    }

    private func setup(_ code: String, lines: [String] = ["18"], usedSecondsAgo: TimeInterval = 0,
                       pinned: Bool = false) -> SavedSetup {
        SavedSetup(stop: TransitStop(code: code, name: "STOP \(code)", city: "Tel Aviv",
                                     location: GeoPoint(lat: 32.06, lon: 34.77)),
                   lines: lines.map(line), lastUsedAt: now.addingTimeInterval(-usedSecondsAgo), pinned: pinned,
                   providerID: "busgovil")
    }

    private func snapshot(for setup: SavedSetup, age: TimeInterval, arrivals count: Int = 3) -> WidgetSnapshot {
        let arrivals = (0..<count).map { index in
            WidgetArrival(lineID: setup.lineIDs[index % setup.lineIDs.count],
                          expectedAt: now.addingTimeInterval(Double(index + 1) * 180), isRealtime: true,
                          stopsAway: index + 1, progressToNext: 0.5, busID: "bus-\(index)")
        }
        return WidgetSnapshot(setupID: setup.id, fetchedAt: now.addingTimeInterval(-age), arrivals: arrivals)
    }

    private func make(_ history: [SavedSetup], snapshots: [WidgetSnapshot] = [],
                      disabled: Set<String>? = ["mta-bustime"]) -> WatchSyncPayload {
        let byID = Dictionary(snapshots.map { ($0.setupID, $0) }, uniquingKeysWith: { first, _ in first })
        return WatchSyncPayload.make(history: history, palette: ["18": 0, "41": 3], appearance: .dark, language: "he",
                                     disabledProviders: disabled, snapshot: { byID[$0] }, now: now)
    }

    @Test func roundTripsThroughItsEncoding() throws {
        let entry = setup("21470", lines: ["18", "41"])
        let payload = make([entry], snapshots: [snapshot(for: entry, age: 30)])
        let decoded = try #require(WatchSyncPayload.decode(payload.encoded()))
        #expect(decoded == payload)
        #expect(decoded.version == WatchSyncPayload.currentVersion)
        #expect(decoded.disabledProviders == ["mta-bustime"])
        #expect(decoded.language == "he")
        #expect(decoded.appearance == .dark)
    }

    /// A payload from a newer phone build is not guessed at.
    @Test func anotherVersionIsNotRead() throws {
        var payload = make([setup("1")])
        payload.version = 2
        #expect(WatchSyncPayload.decode(try payload.encoded()) == nil)
        #expect(WatchSyncPayload.decode(Data("not json".utf8)) == nil)
    }

    @Test func historyIsCappedAndPinnedFirst() {
        let unpinned = (0..<10).map { setup("\($0)", usedSecondsAgo: Double($0) * 60) }
        let pinned = setup("pinned", usedSecondsAgo: 3600, pinned: true)
        let payload = make(unpinned + [pinned])
        #expect(payload.history.count == SavedSetups.limit)
        #expect(payload.history.first == pinned)
        #expect(payload.history.dropFirst().map(\.stop.code) == ["0", "1", "2", "3", "4", "5", "6"])
    }

    /// Numbers past `WidgetSnapshot.usableFor` would show nothing on the watch; a snapshot of a
    /// setup the history no longer has would never be shown at all.
    @Test func onlyUsableSnapshotsOfTheHistoryAreSent() {
        let fresh = setup("fresh"), old = setup("old"), gone = setup("gone")
        let payload = make([fresh, old], snapshots: [snapshot(for: fresh, age: 60),
                                                     snapshot(for: old, age: WidgetSnapshot.usableFor + 1),
                                                     snapshot(for: gone, age: 60)])
        #expect(payload.snapshots.map(\.setupID) == [fresh.id])
    }

    @Test func switchesNotYetMirroredStayNil() {
        #expect(make([setup("1")], disabled: nil).disabledProviders == nil)
        #expect(make([setup("1")], disabled: ["b", "a"]).disabledProviders == ["a", "b"])
    }

    /// The application context is for small state: a full history with numbers for every entry
    /// stays well inside the documented cap, so a new field cannot outgrow it unnoticed.
    @Test func aFullPayloadStaysSmall() throws {
        let history = (0..<SavedSetups.limit).map { setup("2147\($0)", lines: ["18", "41", "7"], usedSecondsAgo: Double($0)) }
        let payload = make(history, snapshots: history.map { snapshot(for: $0, age: 20, arrivals: 12) })
        #expect(payload.history.count == SavedSetups.limit)
        #expect(payload.snapshots.count == SavedSetups.limit)
        #expect(try payload.encoded().count < WatchSyncPayload.encodedSizeCap)
    }
}
