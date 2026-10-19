import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Bergen, Olav Kyrres gate (NSR:StopPlace:30853) — Skyss line 4, which feeds live vehicle
    /// positions (Ruter/Oslo does not). docs/research/worldwide-apis.md §5.1.
    static let entur = LiveFixture(
        provider: EnturProvider(),
        stopQuery: "Olav Kyrres gate",
        stopCode: "NSR:StopPlace:30853",
        lineShortName: "4",
        nearby: GeoPoint(lat: 60.3917, lon: 5.3246),
        timeZone: TimeZone(identifier: "Europe/Oslo")!
    )
}
