import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Tokyo, Kinshichō Station pole 2 (錦糸町駅前 2番のりば) — Toei 都07 toward Monzen-Nakachō,
    /// every few minutes from 06:00 to 23:00.
    static let toei = LiveFixture(
        provider: ToeiBusProvider(),
        stopQuery: "錦糸町駅前",
        stopCode: "KinshichoStation.442.2",
        lineShortName: "都07",
        nearby: GeoPoint(lat: 35.6960, lon: 139.8141),
        timeZone: TimeZone(identifier: "Asia/Tokyo")!
    )
}
