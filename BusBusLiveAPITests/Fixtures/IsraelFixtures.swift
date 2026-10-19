import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Haifa, Allenby G (41122) — line 112 toward Hof HaCarmel. docs/research/transit-apis.md §3.1.
    static let busGovIL = LiveFixture(
        provider: BusGovILProvider(),
        stopQuery: "41122",
        stopCode: "41122",
        lineShortName: "112",
        nearby: GeoPoint(lat: 32.8166, lon: 34.9895),
        timeZone: TimeZone(identifier: "Asia/Jerusalem")!
    )
}
