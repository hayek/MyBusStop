import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Istanbul, Karaköy (117423) — ~60 İETT lines, line 28 toward Edirnekapı. docs/research/worldwide-apis.md §6.10.
    static let iett = LiveFixture(
        provider: IETTProvider(),
        stopQuery: "Karaköy",
        stopCode: "117423",
        lineShortName: "28",
        nearby: GeoPoint(lat: 41.0224, lon: 28.9770),
        timeZone: TimeZone(identifier: "Europe/Istanbul")!
    )
}
