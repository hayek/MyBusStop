import Testing
import Foundation
import CoreGraphics
import SwiftUI
@testable import BusBus

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func line(_ id: String) -> TransitLine {
    TransitLine(id: id, shortName: id, headsign: nil, agency: nil, origin: nil, destination: nil,
                isAccessible: nil, brandColorIndex: nil)
}

private func setup(_ code: String, lines: [String] = ["18", "41"], used minutes: Double = 0,
                   pinned: Bool = false) -> SavedSetup {
    SavedSetup(stop: TransitStop(code: code, name: "STOP \(code)", city: nil, location: GeoPoint(lat: 0, lon: 0)),
               lines: lines.map(line), lastUsedAt: now.addingTimeInterval(minutes * 60), pinned: pinned)
}

private func arrival(_ lineID: String, inMinutes minutes: Double) -> WidgetArrival {
    WidgetArrival(lineID: lineID, expectedAt: now.addingTimeInterval(minutes * 60), isRealtime: true, stopsAway: nil)
}

struct StopGlanceTests {

    @Test func stopsComePinnedFirstThenMostRecent() {
        let history = [setup("old", used: -9), setup("new", used: -1), setup("pinned", used: -20, pinned: true)]
        let glances = StopGlances.build(history: history, snapshot: { _ in nil }, now: now)
        #expect(glances.map(\.setup.stop.code) == ["pinned", "new", "old"])
    }

    @Test func eachLineShowsItsNextTwoBuses() {
        let stop = setup("a")
        let snapshot = WidgetSnapshot(setupID: stop.id, fetchedAt: now.addingTimeInterval(-60), arrivals: [
            arrival("18", inMinutes: 4), arrival("41", inMinutes: 11), arrival("18", inMinutes: 12),
            arrival("18", inMinutes: 20),
        ])
        let glance = StopGlances.build(history: [stop], snapshot: { $0 == stop.id ? snapshot : nil }, now: now)[0]
        #expect(glance.hasNumbers)
        #expect(glance.lines.map(\.line.id) == ["18", "41"])
        #expect(glance.lines[0].next.map(\.minutes) == [4, 12])
        #expect(glance.lines[1].next.map(\.minutes) == [11])
    }

    /// Past what a widget would still count down from, the card says nothing rather than guess.
    @Test func numbersTooOldAreLeftOff() {
        let stop = setup("a")
        let old = WidgetSnapshot(setupID: stop.id, fetchedAt: now.addingTimeInterval(-WidgetSnapshot.usableFor - 1),
                                 arrivals: [arrival("18", inMinutes: 4)])
        let glance = StopGlances.build(history: [stop], snapshot: { _ in old }, now: now)[0]
        #expect(!glance.hasNumbers)
        #expect(glance.lines.allSatisfy { $0.next.isEmpty })
    }

    @Test func aCardOpensItsStopsBoard() {
        let stop = setup("a")
        let glance = StopGlances.build(history: [stop], snapshot: { _ in nil }, now: now)[0]
        #expect(WidgetDeepLink.setupID(from: glance.deepLink) == stop.id)
    }

    @Test func onlyMissingOrMinuteOldNumbersAreRefetched() {
        let fresh = setup("fresh"), stale = setup("stale"), missing = setup("missing")
        let snapshots = [
            fresh.id: WidgetSnapshot(setupID: fresh.id, fetchedAt: now.addingTimeInterval(-30), arrivals: []),
            stale.id: WidgetSnapshot(setupID: stale.id, fetchedAt: now.addingTimeInterval(-90), arrivals: []),
        ]
        let needed = StopGlances.needingFetch(history: [fresh, stale, missing], snapshot: { snapshots[$0] }, now: now)
        #expect(needed.map(\.stop.code) == ["stale", "missing"])
    }

    @Test(.appLanguage("en")) func cardTimesShareAUnitOrSayEach() {
        #expect(TVStopCard.times([]) == "—")
        #expect(TVStopCard.times([Countdown(minutes: 4), Countdown(minutes: 12)]) == "4 · 12 MIN")
        #expect(TVStopCard.times([Countdown(minutes: 0), Countdown(minutes: 12)]) == "NOW · 12 MIN")
        #expect(TVStopCard.times([Countdown(minutes: 40), Countdown(minutes: 65)]) == "40 MIN · 1:05 HR")
    }
}

struct TVStopOrderTests {

    @Test func flippingWrapsAtBothEnds() {
        let history = [setup("a", used: -1), setup("b", used: -2), setup("c", used: -3)]
        #expect(TVStopOrder.neighbour(of: history[0].id, step: 1, in: history)?.stop.code == "b")
        #expect(TVStopOrder.neighbour(of: history[2].id, step: 1, in: history)?.stop.code == "a")
        #expect(TVStopOrder.neighbour(of: history[0].id, step: -1, in: history)?.stop.code == "c")
    }

    /// Opening a stop makes it the most recent; the order flipped through must not follow that.
    @Test func flippingKeepsTheOrderItIsGiven() {
        let order = [setup("a", used: -9), setup("b", used: -1), setup("c", used: -5)]
        #expect(TVStopOrder.neighbour(of: order[0].id, step: 1, in: order)?.stop.code == "b")
        #expect(TVStopOrder.neighbour(of: order[1].id, step: 1, in: order)?.stop.code == "c")
    }

    @Test func aLoneStopHasNoNeighbour() {
        #expect(TVStopOrder.neighbour(of: setup("a").id, step: 1, in: [setup("a")]) == nil)
        #expect(TVStopOrder.neighbour(of: "gone", step: 1, in: [setup("a"), setup("b")]) == nil)
    }

    /// Select on the remote steps through the buses, then lets go.
    @Test func selectStepsThroughTheBusesThenLetsGo() {
        let buses = ["b1", "b2", "b1", "b3"]
        #expect(TVStopOrder.nextBus(after: nil, in: buses) == "b1")
        #expect(TVStopOrder.nextBus(after: "b1", in: buses) == "b2")
        #expect(TVStopOrder.nextBus(after: "b2", in: buses) == "b3")
        #expect(TVStopOrder.nextBus(after: "b3", in: buses) == nil)
        #expect(TVStopOrder.nextBus(after: "gone", in: buses) == "b1")
        #expect(TVStopOrder.nextBus(after: nil, in: []) == nil)
    }
}

struct TVLayoutTests {

    /// A 1080p TV inside tvOS's overscan-safe area is the landscape artboard, larger.
    @Test func aTelevisionIsTheLandscapeBoard() {
        let layout = BoardLayout.resolve(size: CGSize(width: 1920, height: 1080), lineCount: 3,
                                         horizontal: .regular, vertical: .regular,
                                         safeArea: BoardLayout.SafeArea(leading: 80, trailing: 80, top: 60, bottom: 60))
        #expect(layout.mode == .landscape)
        #expect(layout.scale > 1.3)
        #expect(layout.scale <= BoardLayout.maximumScale)
        #expect(!layout.isCompact)
    }
}
