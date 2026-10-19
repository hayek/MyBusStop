import Testing
import Foundation
@testable import BusBus

struct WidgetSnapshotTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func arrival(_ line: String, in seconds: TimeInterval, realtime: Bool = true) -> WidgetArrival {
        WidgetArrival(lineID: line, expectedAt: now.addingTimeInterval(seconds), isRealtime: realtime, stopsAway: nil)
    }

    @Test func roundTripsThroughJSON() throws {
        let snapshot = WidgetSnapshot(setupID: "41122|18|41", fetchedAt: now,
                                      arrivals: [arrival("18", in: 240), arrival("41", in: 600, realtime: false)])
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }

    /// A bus that is due lingers briefly as NOW, then drops off; the rest stay in order.
    @Test func upcomingDropsBusesThatHaveGone() {
        let snapshot = WidgetSnapshot(setupID: "x", fetchedAt: now,
                                      arrivals: [arrival("41", in: 600), arrival("18", in: -20), arrival("7", in: -40)])
        #expect(snapshot.upcoming(at: now).map(\.lineID) == ["18", "41"])
        #expect(snapshot.upcoming(at: now.addingTimeInterval(60)).map(\.lineID) == ["41"])
    }

    /// The widget rounds exactly as the board does.
    @Test func countsDownLikeTheBoard() {
        let bus = arrival("18", in: 61).board
        #expect(bus.minutes(at: now) == 2)
        #expect(!bus.isImminent(at: now))
        #expect(bus.isImminent(at: now.addingTimeInterval(20)))
    }

    @Test func fileNamesEscapeTheIDSeparators() {
        let name = WidgetSnapshotStore.fileName(setupID: "41122|18/A|7:x")
        #expect(!name.contains("|") && !name.contains("/") && !name.contains(":"))
        #expect(name.hasSuffix(".json"))
        #expect(name != WidgetSnapshotStore.fileName(setupID: "41122|18|A|7:x"))
    }

    @Test func savesAndLoadsSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "snapshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)
        let first = WidgetSnapshot(setupID: "41122|18", fetchedAt: now, arrivals: [arrival("18", in: 240)])
        let second = WidgetSnapshot(setupID: "7|5/A", fetchedAt: now, arrivals: [])
        store.save(first)
        store.save(second)
        #expect(store.load(setupID: "41122|18") == first)
        #expect(store.load(setupID: "missing") == nil)
        #expect(store.load(setupID: "7|5/A") == second)
    }

    /// Stops removed from the history take their numbers with them.
    @Test func pruningKeepsOnlyTheHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "snapshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)
        for id in ["41122|18", "7|5/A", "gone|1"] {
            store.save(WidgetSnapshot(setupID: id, fetchedAt: now, arrivals: []))
        }
        store.prune(keeping: ["41122|18", "7|5/A"])
        #expect(store.load(setupID: "41122|18") != nil)
        #expect(store.load(setupID: "7|5/A") != nil)
        #expect(store.load(setupID: "gone|1") == nil)
    }

    /// Without the App Group container nothing is written and nothing breaks.
    @Test func noDirectoryIsANoOp() {
        let store = WidgetSnapshotStore(directory: nil)
        store.save(WidgetSnapshot(setupID: "x", fetchedAt: now, arrivals: []))
        #expect(store.load(setupID: "x") == nil)
    }
}
