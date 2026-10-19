import Testing
import Foundation
@testable import BusBus

/// The names analytics reports are split by. They are read in the Firebase console long after
/// they were written, so a renamed case must not quietly change what a report counts.
struct AnalyticsNamesTests {

    @Test func stillLookingIsNotLogged() {
        #expect(SetupViewModel.analyticsName(for: .locating) == nil)
    }

    @Test func eachNearbyEndingHasItsOwnName() {
        #expect(SetupViewModel.analyticsName(for: .needsPermission) == "needs_permission")
        #expect(SetupViewModel.analyticsName(for: .ready(count: 12, radiusMeters: 500)) == "stops")
        #expect(SetupViewModel.analyticsName(for: .ready(count: 0, radiusMeters: 1000)) == "no_stops")
        #expect(SetupViewModel.analyticsName(for: .denied) == "denied")
        #expect(SetupViewModel.analyticsName(for: .restricted) == "restricted")
        #expect(SetupViewModel.analyticsName(for: .unavailable) == "unavailable")
        #expect(SetupViewModel.analyticsName(for: .outsideCoverage) == "outside_coverage")
    }

    @Test func aLineCardIsCountedOnceItsRouteSettles() {
        #expect(LineCard.analyticsName(for: .loading) == nil)
        #expect(LineCard.analyticsName(for: .drawn(RouteShape([GeoPoint(lat: 0, lon: 0), GeoPoint(lat: 1, lon: 1)]))) == "drawn")
        #expect(LineCard.analyticsName(for: .unsupported) == "unsupported")
        #expect(LineCard.analyticsName(for: .rejected) == "rejected")
        #expect(LineCard.analyticsName(for: .failed) == "failed")
        #expect(LineCard.analyticsName(for: .noStops) == "no_stops")
    }

    @Test func aLineCardClosedWhileLoadingIsStillCounted() {
        #expect(LineCard.analyticsName(for: .loading, isClosing: true) == "dismissed")
        // Closed after it settled: what it settled on.
        #expect(LineCard.analyticsName(for: .rejected, isClosing: true) == "rejected")
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func arrival(realtime: Bool) -> BoardArrival {
        BoardArrival(id: UUID().uuidString, lineID: "41", expectedAt: now.addingTimeInterval(300), isRealtime: realtime)
    }

    @Test func anEmptyBoardHasNoBuses() {
        #expect(BoardViewModel.analyticsOutcome([]) == "no_buses")
    }

    @Test func oneRealtimeMinuteMakesTheBoardLive() {
        #expect(BoardViewModel.analyticsOutcome([arrival(realtime: false), arrival(realtime: true)]) == "live")
    }

    @Test func onlyTimetableMinutesAreScheduled() {
        #expect(BoardViewModel.analyticsOutcome([arrival(realtime: false)]) == "scheduled")
    }
}
