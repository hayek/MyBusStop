import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Zürich, Bucheggplatz (8591101) — trolleybus 72 and buses 32/69, trams 11/14/15 alongside.
    /// docs/research/worldwide-apis.md §5.6.
    static let swiss = LiveFixture(
        provider: SwissTransportProvider(),
        stopQuery: "Zürich Bucheggplatz",
        stopCode: "8591101",
        lineShortName: "72",
        nearby: GeoPoint(lat: 47.3984, lon: 8.5333),
        timeZone: TimeZone(identifier: "Europe/Zurich")!
    )
}
