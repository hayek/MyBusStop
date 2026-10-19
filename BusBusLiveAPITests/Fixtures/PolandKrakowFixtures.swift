import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Kraków, Rondo Grunwaldzkie (stop 3338) — bus 179 among nineteen others, all day.
    /// docs/research/worldwide-apis.md §6.8.
    static let krakow = LiveFixture(
        provider: KrakowProvider(),
        stopQuery: "Rondo Grunwaldzkie",
        stopCode: "3338",
        lineShortName: "179",
        nearby: GeoPoint(lat: 50.0480, lon: 19.9300),
        timeZone: TimeZone(identifier: "Europe/Warsaw")!
    )
}
