import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Turku, Kauppatori A2 (1902) — line 1 toward the airport, every 15 min all day.
    static let foli = LiveFixture(
        provider: FoliProvider(),
        stopQuery: "Kauppatori",
        stopCode: "1902",
        lineShortName: "1",
        nearby: GeoPoint(lat: 60.4515, lon: 22.2665),
        timeZone: TimeZone(identifier: "Europe/Helsinki")!
    )

    /// Tampere, Keskustori F (0012) — through stop of buses 4, 7 and 10 in the city centre.
    static let tampere = LiveFixture(
        provider: TampereProvider(),
        stopQuery: "Keskustori",
        stopCode: "0012",
        lineShortName: "4",
        nearby: GeoPoint(lat: 61.4975, lon: 23.7615),
        timeZone: TimeZone(identifier: "Europe/Helsinki")!
    )
}
