import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Philadelphia, 7th St & Spring Garden St (736) — route 47 northbound, a frequent all-day route
    /// (every ~10 minutes, owl service overnight).
    static let septa = LiveFixture(
        provider: SEPTAProvider(),
        stopQuery: "7th St & Spring Garden",
        stopCode: "736",
        lineShortName: "47",
        nearby: GeoPoint(lat: 39.9613, lon: -75.1498),
        timeZone: TimeZone(identifier: "America/New_York")!
    )
}
