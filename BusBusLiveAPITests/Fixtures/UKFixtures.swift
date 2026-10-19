import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// London, Oxford Circus Station (Stop RC, 490000173RC) — route 88 toward Parliament Hill Fields.
    /// docs/research/worldwide-apis.md §6.1.
    static let tfl = LiveFixture(
        provider: TfLProvider(),
        stopQuery: "Oxford Circus",
        stopCode: "490000173RC",
        lineShortName: "88",
        nearby: GeoPoint(lat: 51.5150, lon: -0.1420),
        timeZone: TimeZone(identifier: "Europe/London")!
    )
}
