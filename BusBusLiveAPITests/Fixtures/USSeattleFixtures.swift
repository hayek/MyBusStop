import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Seattle, Aurora Ave N & N 85th St (7160) — RapidRide E Line toward Downtown, which runs all
    /// night. Needs `OBA_PUGETSOUND_KEY`. docs/research/worldwide-apis.md §7.1.
    static let pugetSound = LiveFixture(
        provider: OneBusAwayProvider(.pugetSound),
        stopQuery: "7160",
        stopCode: "7160",
        lineShortName: "E Line",
        nearby: GeoPoint(lat: 47.6899, lon: -122.3447),
        timeZone: TimeZone(identifier: "America/Los_Angeles")!
    )

    /// Tampa, Marion St @ Zack St (4234), downtown — HART routes 8, 9 and 360. Needs
    /// `OBA_TAMPA_KEY`.
    static let tampa = LiveFixture(
        provider: OneBusAwayProvider(.tampa),
        stopQuery: "4234",
        stopCode: "4234",
        nearby: GeoPoint(lat: 27.9506, lon: -82.4572),
        timeZone: TimeZone(identifier: "America/New_York")!
    )
}
