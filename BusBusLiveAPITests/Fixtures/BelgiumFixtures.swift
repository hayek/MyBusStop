import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Brussels, Montgomery (0801) — trams 7 and 25 toward the city; the 7 runs all day.
    static let stib = LiveFixture(
        provider: STIBProvider(),
        stopQuery: "Montgomery",
        stopCode: "0801",
        lineShortName: "7",
        nearby: GeoPoint(lat: 50.8375, lon: 4.4075),
        timeZone: TimeZone(identifier: "Europe/Brussels")!
    )
}
