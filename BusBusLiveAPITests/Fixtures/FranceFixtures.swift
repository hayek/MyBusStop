import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Rennes, République (1242) — C1 toward Chantepie, plus 11, E4 and N1; service all day.
    static let starRennes = LiveFixture(
        provider: STARRennesProvider(),
        stopQuery: "République",
        stopCode: "1242",
        lineShortName: "C1",
        nearby: GeoPoint(lat: 48.1098, lon: -1.6795),
        timeZone: TimeZone(identifier: "Europe/Paris")!
    )
}
