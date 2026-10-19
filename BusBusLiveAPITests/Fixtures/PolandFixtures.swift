import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Poznań, Rondo Kaponiera bollard 73 (RKAP73) — bus 169 toward Łużycka, all day every ~10–20 min.
    static let poznan = LiveFixture(
        provider: PoznanProvider(),
        stopQuery: "Rondo Kaponiera",
        stopCode: "RKAP73",
        lineShortName: "169",
        nearby: GeoPoint(lat: 52.4078, lon: 16.9125),
        timeZone: TimeZone(identifier: "Europe/Warsaw")!
    )
}
