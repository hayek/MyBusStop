import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Adelaide, Stop V2 King William St (16287) in the city centre — a dozen routes heading south,
    /// 206 among the most frequent, all day.
    static let adelaide = LiveFixture(
        provider: AdelaideMetroProvider(),
        stopQuery: "V2 King William",
        stopCode: "16287",
        lineShortName: "206",
        nearby: GeoPoint(lat: -34.9261, lon: 138.5996),
        timeZone: TimeZone(identifier: "Australia/Adelaide")!
    )
}
