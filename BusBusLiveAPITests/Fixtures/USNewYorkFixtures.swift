import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Manhattan, 1 AV/E 86 ST (401715) — M15 and M15-SBS uptown, a bus every few minutes all day.
    /// Searched by its sign number: name search goes through Apple's geocoder, whose throttling is
    /// not MTA's to answer for. Needs `MTA_BUSTIME_KEY`. docs/research/worldwide-apis.md §7.3.
    static let mtaBusTime = LiveFixture(
        provider: MTABusTimeProvider(),
        stopQuery: "401715",
        stopCode: "401715",
        lineShortName: "M15",
        nearby: GeoPoint(lat: 40.7768, lon: -73.9494),
        timeZone: TimeZone(identifier: "America/New_York")!
    )
}
