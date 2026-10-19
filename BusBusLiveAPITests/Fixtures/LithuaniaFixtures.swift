import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Vilnius, Žirmūnai (0822, toward the centre) — trolleybuses 9, 12, 17, 20 and many buses.
    static let vilnius = LiveFixture(
        provider: PikasProvider.vilnius,
        stopQuery: "Žirmūnai",
        stopCode: "0822",
        lineShortName: "17",
        nearby: GeoPoint(lat: 54.7160, lon: 25.3051),
        timeZone: TimeZone(identifier: "Europe/Vilnius")!
    )

    /// Kaunas, Kęstučio g. (576, away from the centre) — the busiest stop in the routes file.
    static let kaunas = LiveFixture(
        provider: PikasProvider.kaunas,
        stopQuery: "Kęstučio",
        stopCode: "576",
        lineShortName: nil,
        nearby: GeoPoint(lat: 54.8955, lon: 23.9250),
        timeZone: TimeZone(identifier: "Europe/Vilnius")!
    )
}
