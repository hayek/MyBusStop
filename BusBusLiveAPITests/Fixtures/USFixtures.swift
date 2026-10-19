import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Boston, Nubian busway (64) — route 1 toward Harvard; a hub served by a dozen routes all day.
    static let mbta = LiveFixture(
        provider: MBTAProvider(),
        stopQuery: "Nubian",
        stopCode: "64",
        lineShortName: "1",
        nearby: GeoPoint(lat: 42.3297, lon: -71.0838),
        timeZone: TimeZone(identifier: "America/New_York")!
    )

    /// Minneapolis, Chicago & Lake Station (52300) — route 5 northbound (D Line shares the stop).
    static let metroTransit = LiveFixture(
        provider: MetroTransitProvider(),
        stopQuery: "Chicago & Lake",
        stopCode: "52300",
        lineShortName: "5",
        nearby: GeoPoint(lat: 44.9496, lon: -93.2626),
        timeZone: TimeZone(identifier: "America/Chicago")!
    )
}
