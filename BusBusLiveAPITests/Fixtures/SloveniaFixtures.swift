import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Ljubljana, Bavarski dvor (600011) — the city's main interchange, line 6 toward Črnuče.
    /// docs/research/worldwide-apis.md §6.11.
    static let lpp = LiveFixture(
        provider: LPPProvider(),
        stopQuery: "Bavarski dvor",
        stopCode: "600011",
        lineShortName: "6",
        nearby: GeoPoint(lat: 46.0569, lon: 14.5058),
        timeZone: TimeZone(identifier: "Europe/Ljubljana")!
    )
}
