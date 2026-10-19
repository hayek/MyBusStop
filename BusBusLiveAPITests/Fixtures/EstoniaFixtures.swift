import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Tallinn, Estonia (21201-1, SiriID 1627) in the city centre — buses 2, 9 and 46 toward the east.
    static let tallinn = LiveFixture(
        provider: PikasProvider.tallinn,
        stopQuery: "Estonia",
        stopCode: "21201-1",
        lineShortName: "9",
        nearby: GeoPoint(lat: 59.4346, lon: 24.7524),
        timeZone: TimeZone(identifier: "Europe/Tallinn")!
    )
}
