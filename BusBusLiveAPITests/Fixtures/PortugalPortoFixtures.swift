import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Porto, Trindade (TRD5) — nine lines toward the centre, 600 among them, all day.
    /// Held back (stcp.pt's robots.txt disallows /api), so not in `LiveFixtures.all`; run it
    /// with scripts/live-probe.sh. docs/research/worldwide-apis.md §6.6.
    static let stcp = LiveFixture(
        provider: STCPProvider(),
        stopQuery: "Trindade",
        stopCode: "TRD5",
        lineShortName: "600",
        nearby: GeoPoint(lat: 41.1525, lon: -8.6093),
        timeZone: TimeZone(identifier: "Europe/Lisbon")!
    )
}
