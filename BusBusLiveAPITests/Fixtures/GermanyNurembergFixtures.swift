import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Nuremberg, Plärrer (VGN 704) — bus 36 toward Doku-Zentrum every 10 minutes, trams 4/6/10
    /// alongside. docs/research/worldwide-apis.md §5.7.
    static let vag = LiveFixture(
        provider: VAGProvider(),
        stopQuery: "Plärrer",
        stopCode: "704",
        lineShortName: "36",
        nearby: GeoPoint(lat: 49.4481, lon: 11.0648),
        timeZone: TimeZone(identifier: "Europe/Berlin")!
    )
}
