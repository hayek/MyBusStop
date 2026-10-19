import Testing
import Foundation
@testable import BusBus

/// Overnight NexTrip lists no departures, so a stop's lines come from the timetable's index: the
/// same lines the departures would have made, after any the departures did name.
struct MetroTransitStopIndexTests {

    private let index = MetroTransitStopIndex(data: Data("""
    {"lines":[
      {"route":"901","direction":1,"directionText":"SB","shortName":"Blue","headsign":"Mall of America","agency":0},
      {"route":"5","direction":0,"directionText":"NB","shortName":"5","headsign":"Brooklyn Ctr Tc","agency":0}],
     "stops":{"52300":[1,0],"51424":[0]}}
    """.utf8))

    @Test func aStopListsEveryLineTheTimetableStopsThere() {
        #expect(index.lines(atStop: "52300").map(\.id) == ["5-0", "901-1"])
    }

    @Test func anIndexedLineIsTheOneTheDeparturesMake() throws {
        let blue = try #require(index.lines(atStop: "51424").first)
        #expect(blue.id == "901-1")
        #expect(blue.shortName == "Blue")
        #expect(blue.headsign == "Mall of America")
        #expect(blue.agency == "Metro Transit")
        #expect(blue.providerRefs == ["route": "901", "direction": "1", "directionText": "SB"])
    }

    @Test func anUnknownStopHasNoLines() {
        #expect(index.lines(atStop: "99999").isEmpty)
    }

    @Test func aMissingOrBrokenFileIsAnEmptyIndex() {
        #expect(MetroTransitStopIndex(url: nil).lines(atStop: "52300").isEmpty)
        #expect(MetroTransitStopIndex(data: Data("not json".utf8)).lines(atStop: "52300").isEmpty)
    }

    @Test func departuresComeFirstAndEachLineOnce() {
        let live = [TransitLine(id: "5-0", shortName: "5", headsign: "Brooklyn Center"),
                    TransitLine(id: "5-0", shortName: "5", headsign: "Brooklyn Center")]
        let merged = MetroTransitProvider.merge(live: live, scheduled: index.lines(atStop: "52300"))
        #expect(merged.map(\.id) == ["5-0", "901-1"])
        // The live departure's own words win over the index's.
        #expect(merged.first?.headsign == "Brooklyn Center")
    }

    @Test func theAppShipsTheIndex() {
        #expect(!MetroTransitStopIndex.shared.lines(atStop: "52300").isEmpty)
    }
}
