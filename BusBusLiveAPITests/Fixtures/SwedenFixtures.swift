import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Stockholm, Slussen (site 9192) — the Värmdö bus terminal; line 474 toward Hemmesta/Mölnvik.
    /// docs/research/worldwide-apis.md §5.3.
    static let sl = LiveFixture(
        provider: SLProvider(),
        stopQuery: "Slussen",
        stopCode: "9192",
        lineShortName: "474",
        nearby: GeoPoint(lat: 59.3197, lon: 18.0724),
        timeZone: TimeZone(identifier: "Europe/Stockholm")!
    )
}
