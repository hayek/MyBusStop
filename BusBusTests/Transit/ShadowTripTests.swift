import Testing
import Foundation
@testable import BusBus

/// bus.gov.il can carry one bus under two trips — a late slot and the next one — each with its own
/// live time and its own position a little apart (line 3 at HaMeginim/HaHagana Square, Haifa,
/// 1 Oct 2026). Positions here are metres along the route, carried in the latitude.
struct ShadowTripTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func arrival(_ minutes: Double, at along: Double?, trip: String?, realtime: Bool = true) -> Arrival {
        Arrival(expectedAt: now.addingTimeInterval(minutes * 60), scheduledAt: nil, isRealtime: realtime,
                tripId: trip, vehicleLocation: along.map { GeoPoint(lat: $0, lon: 0) })
    }

    private func bus(_ along: Double) -> TrackedBus {
        TrackedBus(id: "", vehicle: VehiclePosition(location: GeoPoint(lat: along, lon: 0)),
                   distanceAlongRoute: along, offRoute: 0, routeFraction: 0, isNext: false)
    }

    private func merge(_ arrivals: [Arrival], _ buses: [TrackedBus]) -> (arrivals: [Arrival], buses: [TrackedBus]) {
        BusProgressService.mergingShadowTrips(arrivals: arrivals, buses: buses, along: { $0.lat })
    }

    /// What the feed sent at 14:22:30: two live trips a minute apart on positions 103 m apart, and
    /// a vehicle at each of those positions.
    @Test func oneBusUnderTwoTripsIsOneArrivalAndOneBus() {
        let merged = merge([arrival(2, at: 10_658, trip: "10378547"), arrival(3, at: 10_555, trip: "10378932"),
                            arrival(29, at: 4_152, trip: "10379046")],
                           [bus(3_926), bus(4_207), bus(10_555), bus(10_658), bus(13_632)])
        #expect(merged.arrivals.map(\.tripId) == ["10378547", "10379046"])
        #expect(merged.buses.map(\.distanceAlongRoute) == [3_926, 4_207, 10_658, 13_632])
    }

    @Test func busesFarApartAreTwoBuses() {
        let merged = merge([arrival(2, at: 10_658, trip: "a"), arrival(3, at: 9_900, trip: "b")],
                           [bus(9_900), bus(10_658)])
        #expect(merged.arrivals.count == 2)
        #expect(merged.buses.count == 2)
    }

    @Test func timesFarApartAreTwoBuses() {
        let merged = merge([arrival(2, at: 10_658, trip: "a"), arrival(9, at: 10_600, trip: "b")],
                           [bus(10_600), bus(10_658)])
        #expect(merged.arrivals.count == 2)
    }

    /// A timetable slot says nothing about where a bus is.
    @Test func scheduledSlotsAreLeftAlone() {
        let merged = merge([arrival(2, at: 10_658, trip: "a"), arrival(3, at: nil, trip: nil, realtime: false)],
                           [bus(10_658)])
        #expect(merged.arrivals.count == 2)
    }

    /// When the feed draws the bus only once, there is no second position to drop.
    @Test func aSingleDrawnBusIsKept() {
        let merged = merge([arrival(2, at: 10_658, trip: "a"), arrival(3, at: 10_555, trip: "b")],
                           [bus(10_640)])
        #expect(merged.arrivals.count == 1)
        #expect(merged.buses.count == 1)
    }
}
