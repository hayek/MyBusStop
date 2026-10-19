import Testing
import Foundation
@testable import BusBusWatch

/// The board's refresh loop, with the fetch stubbed: when it asks, what it keeps, what it saves.
@MainActor
struct WatchStopModelTests {
    struct Offline: Error {}

    /// A clock the test moves by hand.
    final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    }

    private let setup = NextBusEntry.sample(at: Date(timeIntervalSinceReferenceDate: 800_000_000)).setup!

    private func store() -> WidgetSnapshotStore {
        WidgetSnapshotStore(directory: FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)"))
    }

    private func snapshot(at date: Date) -> WidgetSnapshot {
        WidgetSnapshot(setupID: setup.id, fetchedAt: date,
                       arrivals: [WidgetArrival(lineID: "18", expectedAt: date.addingTimeInterval(300), isRealtime: true)])
    }

    @Test func withNoNumbersItFetchesOnceAndSaves() async {
        let clock = Clock(), snapshots = store()
        var calls = 0
        let model = WatchStopModel(setup: setup, snapshots: snapshots,
                                   fetch: { _, date in calls += 1; return self.snapshot(at: date) },
                                   reloadComplications: {}, now: { clock.now })
        await model.catchUp()
        #expect(calls == 1)
        #expect(model.snapshot?.fetchedAt == clock.now)
        #expect(snapshots.load(setupID: setup.id)?.fetchedAt == clock.now)
        #expect(model.fetching == .idle)
    }

    @Test func freshNumbersAreNotFetchedAgain() async {
        let clock = Clock(), snapshots = store()
        snapshots.save(snapshot(at: clock.now.addingTimeInterval(-30)))
        var calls = 0
        let model = WatchStopModel(setup: setup, snapshots: snapshots,
                                   fetch: { _, date in calls += 1; return self.snapshot(at: date) },
                                   reloadComplications: {}, now: { clock.now })
        await model.catchUp()
        #expect(calls == 0)
        #expect(model.snapshot != nil)
    }

    @Test func aFailedFetchKeepsTheLastGoodNumbers() async {
        let clock = Clock(), snapshots = store()
        let kept = snapshot(at: clock.now.addingTimeInterval(-5 * 60))
        snapshots.save(kept)
        let model = WatchStopModel(setup: setup, snapshots: snapshots, fetch: { _, _ in throw Offline() },
                                   reloadComplications: {}, now: { clock.now })
        await model.refresh()
        #expect(model.snapshot == kept)
        #expect(model.fetching == .failed)
    }

    @Test func complicationsAreRedrawnAtMostEveryThreeMinutes() async {
        let clock = Clock()
        var reloads = 0
        let model = WatchStopModel(setup: setup, snapshots: store(),
                                   fetch: { _, date in self.snapshot(at: date) },
                                   reloadComplications: { reloads += 1 }, now: { clock.now })
        await model.refresh()
        #expect(reloads == 1)
        clock.now += 60
        await model.refresh()
        #expect(reloads == 1)
        clock.now += 2 * 60
        await model.refresh()
        #expect(reloads == 2)
    }

    /// With the numbers run out, the board says what is happening: the watch is asking, it could
    /// not reach the feed, or only the iPhone can ask.
    @Test func theExpiredDetailFollowsWhatTheWatchMayDo() {
        #expect(WatchStopModel.expiredDetail(canFetch: false, fetching: .idle) == .openOnIPhone)
        #expect(WatchStopModel.expiredDetail(canFetch: false, fetching: .failed) == .openOnIPhone)
        #expect(WatchStopModel.expiredDetail(canFetch: true, fetching: .idle) == .connecting)
        #expect(WatchStopModel.expiredDetail(canFetch: true, fetching: .fetching) == .connecting)
        #expect(WatchStopModel.expiredDetail(canFetch: true, fetching: .failed) == .cantReachFeed)
    }

    /// A board's model is made once for its stop, however often the list redraws the destination.
    @Test func eachStopOnThePathKeepsOneModel() {
        var made = 0
        let boards = WatchBoardModels { setup in
            made += 1
            return WatchStopModel(setup: setup, snapshots: self.store(), fetch: { _, date in self.snapshot(at: date) },
                                  reloadComplications: {})
        }
        let first = boards.model(for: setup)
        #expect(boards.model(for: setup) === first)
        #expect(made == 1)
        boards.keep(only: [setup.id])
        #expect(boards.model(for: setup) === first)
        boards.keep(only: [])
        #expect(boards.model(for: setup) !== first)
        #expect(made == 2)
    }
}
