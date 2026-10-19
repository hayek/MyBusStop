import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Luxembourg, Gare Centrale routière (200405036) — city buses every few minutes; line 22 runs
    /// through the day. Needs `MOBILITEIT_LU_KEY`.
    static let luxembourg = LiveFixture(
        provider: HafasProvider(.luxembourg),
        stopQuery: "Gare Centrale routière",
        stopCode: "200405036",
        lineShortName: "22",
        nearby: GeoPoint(lat: 49.5995, lon: 6.1335),
        timeZone: TimeZone(identifier: "Europe/Luxembourg")!
    )
}
