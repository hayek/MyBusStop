import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Toronto, Dufferin St at Bloor St West – Dufferin Station (2013) — route 29 Dufferin, one of the
    /// busiest bus routes in the city, all day. No proximity query on this feed, so no nearby point.
    static let ttc = LiveFixture(
        provider: UmoNextBusProvider(agency: .ttc),
        stopQuery: "Dufferin Station",
        stopCode: "2013",
        lineShortName: "29",
        nearby: nil,
        timeZone: TimeZone(identifier: "America/Toronto")!
    )
}
