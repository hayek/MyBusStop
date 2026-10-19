import Testing
import Foundation
@testable import BusBus

struct WidgetTimelineMathTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func arrival(in seconds: TimeInterval, line: String = "18") -> WidgetArrival {
        WidgetArrival(lineID: line, expectedAt: now.addingTimeInterval(seconds), isRealtime: true, stopsAway: nil)
    }

    @Test func startsNowAndStaysInOrder() {
        let dates = WidgetTimelineMath.entryDates(for: [arrival(in: 400), arrival(in: 130, line: "41")], now: now)
        #expect(dates.first == now)
        #expect(dates == dates.sorted())
        #expect(Set(dates).count == dates.count)
    }

    /// Every moment the figure changes has a picture: each whole minute before the bus, the NOW
    /// flip, and the moment it drops off.
    @Test func coversEveryChangeOfTheFigure() {
        let bus = arrival(in: 200)
        let dates = WidgetTimelineMath.entryDates(for: [bus], now: now)
        for offset in [-180.0, -120, -60, -WidgetTimelineMath.imminentLead, 0, WidgetSnapshot.lingerAfterDue] {
            #expect(dates.contains(bus.expectedAt.addingTimeInterval(offset)), "missing \(offset)")
        }
        // Between two pictures what the widget shows does not change: neither the figure nor NOW.
        for (start, end) in zip(dates, dates.dropFirst()) {
            let justBefore = end.addingTimeInterval(-0.002)
            #expect(bus.board.minutes(at: start) == bus.board.minutes(at: justBefore))
            #expect(bus.board.isImminent(at: start) == bus.board.isImminent(at: justBefore), "NOW flips inside \(start)")
        }
    }

    /// The picture drawn for the flip already says NOW, as the board does 45 seconds out.
    @Test func theFlipPictureSaysNow() throws {
        let bus = arrival(in: 200)
        let dates = WidgetTimelineMath.entryDates(for: [bus], now: now)
        let flip = try #require(dates.first { bus.board.isImminent(at: $0) })
        #expect(bus.expectedAt.timeIntervalSince(flip) < 45)
        #expect(bus.expectedAt.timeIntervalSince(flip) > 44)
        let before = try #require(dates.last { $0 < flip })
        #expect(!bus.board.isImminent(at: before))
    }

    /// A later arrival's minutes count from when it comes on screen: when the one `arrivalsShown`
    /// places ahead of it drops off.
    @Test func aLaterArrivalIsCoveredOnceItIsShown() {
        let first = arrival(in: 120), second = arrival(in: 300, line: "41"), third = arrival(in: 700, line: "7")
        let dates = WidgetTimelineMath.entryDates(for: [first, second, third], fetchedAt: now, now: now, arrivalsShown: 2)
        let onScreen = first.expectedAt.addingTimeInterval(WidgetSnapshot.lingerAfterDue)
        for offset in stride(from: 0.0, through: 480, by: 60) {
            let boundary = third.expectedAt.addingTimeInterval(-offset)
            guard boundary > onScreen else { continue }
            #expect(dates.contains(boundary), "missing the third bus at -\(offset)")
        }
        // Before it is on screen its minutes do not cost a picture.
        #expect(!dates.contains(third.expectedAt.addingTimeInterval(-600)))
    }

    /// WidgetKit keeps the last picture until it reloads, which it may put off for hours: the
    /// series ends on the moment the numbers stop being usable, never on a number.
    @Test func endsWhereTheNumbersStopBeingUsable() throws {
        let arrivals = (1...5).map { arrival(in: Double($0) * 40 * 60, line: "\($0)") }
        let dates = WidgetTimelineMath.entryDates(for: arrivals, fetchedAt: now, now: now)
        let last = try #require(dates.last)
        #expect(last == now.addingTimeInterval(WidgetSnapshot.usableFor))
        #expect(WidgetTimelineMath.liveness(fetchedAt: now, now: last) == .expired)
        #expect(dates.dropLast().allSatisfy { WidgetTimelineMath.liveness(fetchedAt: now, now: $0) != .expired })
    }

    /// An older snapshot runs out sooner.
    @Test func anOlderSnapshotEndsSooner() {
        let fetched = now.addingTimeInterval(-20 * 60)
        let dates = WidgetTimelineMath.entryDates(for: [arrival(in: 3600)], fetchedAt: fetched, now: now)
        #expect(dates.last == fetched.addingTimeInterval(WidgetSnapshot.usableFor))
        #expect(WidgetTimelineMath.entryDates(for: [arrival(in: 60)], fetchedAt: now.addingTimeInterval(-3600), now: now) == [now])
    }

    @Test func respectsTheHorizon() {
        let far = WidgetTimelineMath.entryDates(for: [arrival(in: 3 * 3600)], now: now, horizon: 1800)
        #expect(far.allSatisfy { $0 <= now.addingTimeInterval(1800) })
        #expect(far.last == now.addingTimeInterval(1800))
    }

    /// The cap keeps the earliest pictures and still ends the series: on the first moment it left
    /// out, so no picture outlives the figure it shows.
    @Test func theCapCannotDropTheEnd() {
        let arrivals = (0..<6).map { arrival(in: 1700 - Double($0) * 7, line: "\($0)") }
        let full = WidgetTimelineMath.entryDates(for: arrivals, fetchedAt: now, now: now, arrivalsShown: 6)
        let capped = WidgetTimelineMath.entryDates(for: arrivals, fetchedAt: now, now: now, maxEntries: 10, arrivalsShown: 6)
        #expect(full.count > 10)
        #expect(capped.count == 10)
        #expect(Array(capped.dropLast()) == Array(full.prefix(9)))
        #expect(capped.last == full[9])
    }

    @Test func marksWhenTheDotGoesGrey() {
        let fetched = now.addingTimeInterval(-60)
        let dates = WidgetTimelineMath.entryDates(for: [], fetchedAt: fetched, now: now)
        #expect(dates.contains(fetched.addingTimeInterval(WidgetSnapshot.freshFor)))
    }

    @Test func reloadsShortlyBeforeTheNextBusWithinLimits() {
        #expect(WidgetTimelineMath.reloadDate(for: [arrival(in: 10 * 60)], now: now) == now.addingTimeInterval(8 * 60))
        #expect(WidgetTimelineMath.reloadDate(for: [arrival(in: 60)], now: now) == now.addingTimeInterval(5 * 60))
        #expect(WidgetTimelineMath.reloadDate(for: [arrival(in: 3600)], now: now) == now.addingTimeInterval(15 * 60))
        #expect(WidgetTimelineMath.reloadDate(for: [], now: now) == now.addingTimeInterval(15 * 60))
    }

    @Test func livenessThresholds() {
        #expect(WidgetTimelineMath.liveness(fetchedAt: now, now: now.addingTimeInterval(WidgetSnapshot.freshFor - 1)) == .live)
        let stale = now.addingTimeInterval(WidgetSnapshot.freshFor)
        #expect(WidgetTimelineMath.liveness(fetchedAt: now, now: stale) == .stale(asOf: now))
        #expect(WidgetTimelineMath.liveness(fetchedAt: now, now: now.addingTimeInterval(WidgetSnapshot.usableFor)) == .expired)
    }

    /// The watch's Smart Stack score: nothing without a bus, a low constant when it is far off,
    /// and a climb to 100 over its last fifteen minutes.
    @Test func relevanceRisesAsTheBusNears() {
        #expect(WidgetTimelineMath.relevanceScore(secondsToNext: nil) == nil)
        #expect(WidgetTimelineMath.relevanceScore(secondsToNext: 40 * 60) == 20)
        let far = WidgetTimelineMath.relevanceScore(secondsToNext: 14 * 60)!
        let near = WidgetTimelineMath.relevanceScore(secondsToNext: 2 * 60)!
        let now = WidgetTimelineMath.relevanceScore(secondsToNext: 0)!
        #expect(far > 20 && far < near && near < now && now == 100)
        #expect(WidgetTimelineMath.relevanceScore(secondsToNext: -20) == 100)
    }
}
