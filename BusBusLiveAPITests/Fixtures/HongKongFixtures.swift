import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

nonisolated extension LiveFixture {
    /// Tai Po Market Station bus terminus — K12 to Eightland Garden every ~6 min, plus K17/K18.
    /// docs/research/worldwide-apis.md §8.1.
    static let mtrBus = LiveFixture(
        provider: MTRBusProvider(),
        stopQuery: "Tai Po Market Station",
        stopCode: "K12-U010",
        lineShortName: "K12",
        nearby: GeoPoint(lat: 22.4444, lon: 114.1695),
        timeZone: TimeZone(identifier: "Asia/Hong_Kong")!
    )

    /// Prince Edward Station, Flower Market (MK751) on Prince Edward Road West — 15 KMB lines, 1A
    /// toward Star Ferry. Searched by the signpost code in its name.
    static let kmb = LiveFixture(
        provider: KMBProvider(),
        stopQuery: "MK751",
        stopCode: "F7CAA2D4FF9D61F7",
        lineShortName: "1A",
        nearby: GeoPoint(lat: 22.3241, lon: 114.1699),
        timeZone: TimeZone(identifier: "Asia/Hong_Kong")!
    )

    /// Admiralty - Queensway Plaza (003845) on route 1 toward Happy Valley, every ~10 min all day.
    /// Citybus search is route-first (no stop list exists), so the query is the route number.
    static let citybus = LiveFixture(
        provider: CitybusProvider(),
        stopQuery: "1",
        stopCode: "003845",
        lineShortName: "1",
        nearby: nil,
        timeZone: TimeZone(identifier: "Asia/Hong_Kong")!
    )

    /// Pedder Street, near Central Station Exit D1 (20000024) on HKI route 1 toward Central, every
    /// 5–10 min from 06:45 to midnight; seven other HKI routes call there. GMB search is route-first
    /// (no stop list exists), so the query is the route code — it also loads the unrelated NT 1.
    static let gmb = LiveFixture(
        provider: GMBProvider(),
        stopQuery: "1",
        stopCode: "20000024",
        lineShortName: "1",
        nearby: nil,
        timeZone: TimeZone(identifier: "Asia/Hong_Kong")!
    )

    /// Tung Chung Station Bus Terminus (278), the start of 3M to Mui Wo (every ~20–30 min, all day) and
    /// of 11/11A into South Lantau.
    static let nlb = LiveFixture(
        provider: NLBProvider(),
        stopQuery: "Tung Chung Station",
        stopCode: "278",
        lineShortName: "3M",
        nearby: GeoPoint(lat: 22.2893, lon: 113.9405),
        timeZone: TimeZone(identifier: "Asia/Hong_Kong")!
    )
}
