import Testing
import Foundation
import WidgetKit
@testable import BusBus

/// The widget's pictures, built from the history and the last numbers known.
struct NextBusTimelineTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func setup(_ code: String, lines: [String], pinned: Bool = false) -> SavedSetup {
        SavedSetup(stop: TransitStop(code: code, name: "Stop \(code)", location: GeoPoint(lat: 0, lon: 0)),
                   lines: lines.map {
                       TransitLine(id: $0, shortName: $0, headsign: nil, agency: nil, origin: nil, destination: nil,
                                   isAccessible: nil, brandColorIndex: nil)
                   },
                   lastUsedAt: now, pinned: pinned)
    }

    private var history: [SavedSetup] {
        [setup("1", lines: ["18"], pinned: true), setup("2", lines: ["41"]), setup("3", lines: ["7"])]
    }

    private func arrival(_ line: String, in seconds: TimeInterval) -> WidgetArrival {
        WidgetArrival(lineID: line, expectedAt: now.addingTimeInterval(seconds), isRealtime: true, stopsAway: nil)
    }

    private func entries(history: [SavedSetup]? = nil, chosen: String?, snapshot: WidgetSnapshot?,
                         layout: WidgetLayout = WidgetLayout(arrivalsShown: 2)) -> [NextBusEntry] {
        NextBusTimeline.entries(history: history ?? self.history, chosenID: chosen,
                                snapshot: snapshot, layout: layout,
                                palette: [:], appearance: .system, now: now)
    }

    @Test func anEmptyHistoryAsksForAStop() {
        let result = entries(history: [], chosen: nil, snapshot: nil)
        #expect(result.count == 1)
        #expect(result[0].state == .noHistory)
        #expect(WidgetMessage(result[0]) == .noHistory)
    }

    /// A widget set to an entry since removed says so, rather than showing another stop.
    @Test func aRemovedEntryIsMissing() {
        let result = entries(chosen: "gone|18", snapshot: nil)
        #expect(result.map(\.state) == [.notConfigured])
        #expect(result[0].setup == nil)
        #expect(WidgetMessage(result[0]) == .notConfigured)
    }

    @Test func noSnapshotMeansNoNumbers() {
        let result = entries(chosen: nil, snapshot: nil)
        #expect(result.count == 1)
        #expect(result[0].setup?.id == history[0].id)
        #expect(WidgetMessage(result[0]) == .expired)
    }

    /// Someone else's numbers are never drawn under this stop's name.
    @Test func aSnapshotForAnotherStopIsIgnored() {
        let snapshot = WidgetSnapshot(setupID: history[1].id, fetchedAt: now, arrivals: [arrival("41", in: 300)])
        let result = entries(chosen: history[0].id, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].arrivals.isEmpty)
    }

    /// Counting down: live, then grey with the time, and it ends on "open the app", never a number.
    @Test func countsDownThenGoesStaleThenExpires() throws {
        let snapshot = WidgetSnapshot(setupID: history[0].id, fetchedAt: now,
                                      arrivals: (1...6).map { arrival("18", in: Double($0) * 8 * 60) })
        let result = entries(chosen: history[0].id, snapshot: snapshot)
        #expect(result.first?.date == now)
        #expect(result.first?.liveness == .live)
        #expect(result.first.flatMap(WidgetMessage.init) == nil)
        #expect(result.contains { $0.liveness == .stale(asOf: now) && !$0.arrivals.isEmpty })
        let last = try #require(result.last)
        #expect(last.liveness == .expired)
        #expect(last.arrivals.isEmpty)
        #expect(WidgetMessage(last) == .expired)
        #expect(result.dropLast().allSatisfy { !$0.arrivals.isEmpty })
    }

    /// Cut short by the cap, the timeline still ends on "open the app".
    @Test func aCappedTimelineStillEnds() throws {
        let arrivals = (0..<8).map { arrival("\($0)", in: 1700 - Double($0) * 7) }
        let snapshot = WidgetSnapshot(setupID: history[0].id, fetchedAt: now, arrivals: arrivals)
        let result = entries(chosen: history[0].id, snapshot: snapshot, layout: WidgetLayout(arrivalsShown: 8))
        #expect(result.count <= 120)
        let last = try #require(result.last)
        #expect(last.date < now.addingTimeInterval(WidgetSnapshot.usableFor))
        #expect(WidgetMessage(last) == .expired)
    }

    /// Once every bus the feed named has gone, there are surely more on the way: the widget says
    /// to look rather than that none are due.
    @Test func runningOutOfKnownBusesIsNotNoBusesDue() throws {
        let snapshot = WidgetSnapshot(setupID: history[0].id, fetchedAt: now, arrivals: [arrival("18", in: 120)])
        let result = entries(chosen: history[0].id, snapshot: snapshot)
        let after = try #require(result.first { $0.date >= now.addingTimeInterval(120 + WidgetSnapshot.lingerAfterDue) })
        #expect(WidgetMessage(after) == .expired)
    }

    /// Only a feed that really answered with nothing is "no buses due".
    @Test func anEmptyAnswerIsNoBusesDue() {
        let snapshot = WidgetSnapshot(setupID: history[0].id, fetchedAt: now, arrivals: [])
        let result = entries(chosen: history[0].id, snapshot: snapshot)
        #expect(WidgetMessage(result[0]) == .noBusesDue)
        #expect(WidgetMessage(result[result.count - 1]) == .expired)
    }

    /// Numbers fetched a while ago show with the time they are from.
    @Test func anOlderSnapshotStartsStale() {
        let fetched = now.addingTimeInterval(-15 * 60)
        let snapshot = WidgetSnapshot(setupID: history[0].id, fetchedAt: fetched, arrivals: [arrival("18", in: 600)])
        let result = entries(chosen: history[0].id, snapshot: snapshot)
        #expect(result[0].liveness == .stale(asOf: fetched))
        #expect(result.last?.date == fetched.addingTimeInterval(WidgetSnapshot.usableFor))
    }

    @Test func eachSizeListsWhatItHasRoomFor() {
        func layout(_ family: WidgetFamily, _ content: LargeWidgetContent, map: Bool = true) -> WidgetLayout {
            WidgetLayout.for(family, content: content, hasMap: map)
        }
        #expect(layout(.systemSmall, .map) == WidgetLayout(arrivalsShown: 2))
        #expect(layout(.systemMedium, .laterBuses) == WidgetLayout(arrivalsShown: 2))
        #expect(layout(.systemLarge, .map) == WidgetLayout(content: .map, arrivalsShown: 2))
        #expect(layout(.systemLarge, .laterBuses)
                == WidgetLayout(content: .laterBuses, arrivalsShown: 2 + WidgetLayout.largeLaterRows))
        #expect(layout(.systemExtraLarge, .map)
                == WidgetLayout(content: .map, arrivalsShown: 2 + WidgetLayout.extraLargeMapLaterRows))
        #expect(layout(.systemExtraLarge, .laterBuses)
                == WidgetLayout(content: .laterBuses, arrivalsShown: 2 + WidgetLayout.extraLargeLaterRows))
        #expect(layout(.systemExtraLargePortrait, .map) == WidgetLayout(content: .map, arrivalsShown: 2))
        #expect(layout(.systemExtraLargePortrait, .laterBuses)
                == WidgetLayout(content: .laterBuses, arrivalsShown: 2 + WidgetLayout.extraLargePortraitLaterRows))
    }

    /// A stop never opened on the board since has no routes to draw: its later buses instead.
    @Test func aMapWithNoRoutesFallsBackToTheLaterBuses() {
        #expect(WidgetLayout.for(.systemLarge, content: .map, hasMap: false)
                == WidgetLayout(content: .laterBuses, arrivalsShown: 2 + WidgetLayout.largeLaterRows))
        #expect(WidgetLayout.for(.systemExtraLarge, content: .map, hasMap: false).content == .laterBuses)
        #expect(WidgetLayout.for(.systemExtraLargePortrait, content: .map, hasMap: false)
                == WidgetLayout(content: .laterBuses, arrivalsShown: 2 + WidgetLayout.extraLargePortraitLaterRows))
        #expect(WidgetLayout.for(.systemExtraLarge, content: .laterBuses, hasMap: true).content == .laterBuses)
    }

    /// A widget set to "Other stops" before it went reads back as the map, the default; the picker
    /// no longer offers it.
    @Test func theRemovedOtherStopsChoiceOpensOnTheMap() throws {
        #expect(LargeWidgetContent(rawValue: "otherStops") == .map)
        #expect(LargeWidgetContent(rawValue: "laterBuses") == .laterBuses)
        #expect(LargeWidgetContent(rawValue: "nonsense") == nil)
        #expect(LargeWidgetContent.allCases == [.map, .laterBuses])
        let decoded = try JSONDecoder().decode([LargeWidgetContent].self, from: Data(#"["otherStops","map"]"#.utf8))
        #expect(decoded == [.map, .map])
    }

    /// The watch's board draws only the picture for now, every second: the one-entry builder must be
    /// the timeline's first entry, whatever the numbers.
    @Test func theEntryForNowIsTheTimelinesFirst() {
        let id = history[0].id
        let snapshots: [WidgetSnapshot?] = [
            nil,
            WidgetSnapshot(setupID: id, fetchedAt: now, arrivals: (1...6).map { arrival("18", in: Double($0) * 8 * 60) }),
            WidgetSnapshot(setupID: id, fetchedAt: now.addingTimeInterval(-15 * 60), arrivals: [arrival("18", in: 600)]),
            WidgetSnapshot(setupID: id, fetchedAt: now.addingTimeInterval(-2 * 3600), arrivals: [arrival("18", in: 600)]),
            WidgetSnapshot(setupID: id, fetchedAt: now.addingTimeInterval(-5 * 60), arrivals: [arrival("18", in: -600)]),
            WidgetSnapshot(setupID: id, fetchedAt: now, arrivals: []),
            WidgetSnapshot(setupID: history[1].id, fetchedAt: now, arrivals: [arrival("41", in: 300)]),
        ]
        for snapshot in snapshots {
            for layout in [WidgetLayout(arrivalsShown: 2), WidgetLayout(arrivalsShown: 6)] {
                let one = NextBusTimeline.entry(history: history, chosenID: id, snapshot: snapshot, layout: layout,
                                                palette: ["18": 2], appearance: .dark, now: now)
                let all = NextBusTimeline.entries(history: history, chosenID: id, snapshot: snapshot, layout: layout,
                                                  palette: ["18": 2], appearance: .dark, now: now)
                #expect(one == all[0])
            }
        }
        for (history, chosen) in [([SavedSetup](), nil as String?), (history, "gone|18")] {
            let one = NextBusTimeline.entry(history: history, chosenID: chosen, snapshot: nil,
                                            layout: WidgetLayout(arrivalsShown: 2), palette: [:], appearance: .system, now: now)
            #expect(one == entries(history: history, chosen: chosen, snapshot: nil)[0])
        }
    }

    /// The Smart Stack only raises a stop with numbers to count down: never a message.
    @Test func onlyALiveBoardIsRelevant() {
        let id = history[0].id
        let live = entries(chosen: id, snapshot: WidgetSnapshot(setupID: id, fetchedAt: now, arrivals: [arrival("18", in: 120)]))[0]
        #expect(live.relevanceScore != nil)
        let old = WidgetSnapshot(setupID: id, fetchedAt: now.addingTimeInterval(-2 * 3600), arrivals: [arrival("18", in: 120)])
        #expect(entries(chosen: id, snapshot: old)[0].liveness == .expired)
        #expect(entries(chosen: id, snapshot: old)[0].relevanceScore == nil)
        #expect(entries(chosen: id, snapshot: nil)[0].relevanceScore == nil)
        #expect(entries(chosen: id, snapshot: WidgetSnapshot(setupID: id, fetchedAt: now, arrivals: []))[0].relevanceScore == nil)
        #expect(entries(history: [], chosen: nil, snapshot: nil)[0].relevanceScore == nil)
        // A board entry marked expired is never raised, even if it still carries arrivals.
        var expired = live
        expired.liveness = .expired
        #expect(expired.relevanceScore == nil)
        var message = live
        message.state = .notConfigured
        #expect(message.relevanceScore == nil)
    }
}
