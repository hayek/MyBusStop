import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Odivelas, Lg Marcos Romão Reis Junior (070032) — ~45 patterns, service all day.
    static let carris = LiveFixture(
        provider: CarrisMetropolitanaProvider(),
        stopQuery: "Marcos Romao",
        stopCode: "070032",
        lineShortName: "2605",
        nearby: GeoPoint(lat: 38.8288, lon: -9.1669),
        timeZone: TimeZone(identifier: "Europe/Lisbon")!
    )
}
