import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Manchester, Oxford Road Station (Stop B, 1800SB04911) — southbound on the Oxford Road
    /// corridor, route 43 toward Manchester Airport. Outside London on purpose: London is TfL's.
    /// docs/research/worldwide-apis.md §6.2.
    static let bustimes = LiveFixture(
        provider: BustimesProvider(),
        stopQuery: "1800SB04911",
        stopCode: "1800SB04911",
        lineShortName: "43",
        nearby: GeoPoint(lat: 53.4738, lon: -2.2400),
        timeZone: TimeZone(identifier: "Europe/London")!
    )
}
