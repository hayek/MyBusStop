import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Stuttgart, Charlottenplatz (de:08111:6075) — bus 44 toward Westbahnhof, mid-route.
    /// docs/research/worldwide-apis.md §5.7.
    static let efaBW = LiveFixture(
        provider: EFAProvider(.badenWuerttemberg),
        stopQuery: "Stuttgart Charlottenplatz",
        stopCode: "de:08111:6075",
        lineShortName: "44",
        nearby: GeoPoint(lat: 48.7762, lon: 9.1829),
        timeZone: TimeZone(identifier: "Europe/Berlin")!
    )

    /// Essen, Hauptbahnhof (de:05113:9289) — bus 145 toward Heisingen, every 5–10 minutes.
    static let efaVRR = LiveFixture(
        provider: EFAProvider(.rheinRuhr),
        stopQuery: "Essen Hauptbahnhof",
        stopCode: "de:05113:9289",
        lineShortName: "145",
        nearby: GeoPoint(lat: 51.4497, lon: 7.0122),
        timeZone: TimeZone(identifier: "Europe/Berlin")!
    )

    /// Berlin, S+U Alexanderplatz (900100003) — bus 200 and the M-trams. Needs `VBB_KEY`.
    static let vbb = LiveFixture(
        provider: HafasProvider(.vbb),
        stopQuery: "Alexanderplatz",
        stopCode: "900100003",
        lineShortName: "200",
        nearby: GeoPoint(lat: 52.5219, lon: 13.4132),
        timeZone: TimeZone(identifier: "Europe/Berlin")!
    )

    /// Munich, Giselastraße (de:09162:80) — bus 54 toward Lorettoplatz.
    static let mvg = LiveFixture(
        provider: MVGProvider(),
        stopQuery: "Giselastraße",
        stopCode: "de:09162:80",
        lineShortName: "54",
        nearby: GeoPoint(lat: 48.1565, lon: 11.5840),
        timeZone: TimeZone(identifier: "Europe/Berlin")!
    )
}
