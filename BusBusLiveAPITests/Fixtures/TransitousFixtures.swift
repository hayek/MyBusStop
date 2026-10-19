import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Berlin, S+U Zoologischer Garten — M45 and a dozen other BVG buses, most with VBB realtime.
    /// Berlin is none of our regions: this is the worldwide fallback. docs/research/worldwide-apis.md §4.1.
    static let transitous = LiveFixture(
        provider: TransitousProvider(),
        stopQuery: "Zoologischer Garten",
        stopCode: "de-VBB_de:11000:900023201",
        lineShortName: "M45",
        nearby: GeoPoint(lat: 52.5067, lon: 13.3322),
        timeZone: TimeZone(identifier: "Europe/Berlin")!
    )
}
