import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Vienna, Pilgramgasse U (RBL 669) — bus 13A toward Hauptbahnhof, mid-route.
    /// docs/research/worldwide-apis.md §5.8.
    static let wienerLinien = LiveFixture(
        provider: WienerLinienProvider(),
        stopQuery: "Pilgramgasse",
        stopCode: "669",
        lineShortName: "13A",
        nearby: GeoPoint(lat: 48.1929, lon: 16.3545),
        timeZone: TimeZone(identifier: "Europe/Vienna")!
    )
}
