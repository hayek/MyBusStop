import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Gdańsk, Dworzec Główny 07 (bollard 1016) — line 199 among a dozen others, all day.
    /// docs/research/worldwide-apis.md §6.8.
    static let gdansk = LiveFixture(
        provider: GdanskProvider(),
        stopQuery: "Dworzec Główny",
        stopCode: "1016",
        lineShortName: "199",
        nearby: GeoPoint(lat: 54.3553, lon: 18.6458),
        timeZone: TimeZone(identifier: "Europe/Warsaw")!
    )
}
