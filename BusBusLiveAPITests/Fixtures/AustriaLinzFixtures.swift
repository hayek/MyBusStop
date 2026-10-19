import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Linz, Taubenmarkt (at:44:41263) — bus 26 through the centre, trams 1–4 alongside.
    /// docs/research/worldwide-apis.md §5.7.
    static let efaLinz = LiveFixture(
        provider: EFAProvider(.linz),
        stopQuery: "Linz Taubenmarkt",
        stopCode: "at:44:41263",
        lineShortName: "26",
        nearby: GeoPoint(lat: 48.3040, lon: 14.2867),
        timeZone: TimeZone(identifier: "Europe/Vienna")!
    )
}
