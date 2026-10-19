import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Bilbao, Moyua plaza (Deutsche Bank) (4256) — Bizkaibus lines to Derio and Erandio; A3224
    /// runs all day.
    static let bizkaibus = LiveFixture(
        provider: BizkaibusProvider(),
        stopQuery: "Moyua",
        stopCode: "4256",
        lineShortName: "A3224",
        nearby: GeoPoint(lat: 43.2633, lon: -2.9350),
        timeZone: TimeZone(identifier: "Europe/Madrid")!
    )
}
