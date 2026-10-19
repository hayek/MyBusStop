import Foundation

/// A place BusBus can serve, and the provider that serves it. This is the list the App Store
/// availability is cut from: a country ships only when at least one of its regions is here and
/// its provider passes the live checks in `BusBusLiveAPITests`.
/// Research behind every entry: docs/research/worldwide-apis.md.
nonisolated struct SupportedRegion: Identifiable, Hashable, Sendable {
    enum Fit: String, Sendable {
        /// Stops, lines, patterns, live vehicle positions and ETAs.
        case full
        /// Realtime ETAs at a stop, but no live vehicle positions.
        case arrivalsOnly
    }

    /// Stable id, "<ISO country>-<area>", e.g. "US-BOS".
    var id: String
    /// ISO 3166-1 alpha-2.
    var countryCode: String
    var name: String
    var providerID: String
    var fit: Fit
    /// Rough service area, used to suggest a region from the rider's location.
    var bounds: GeoBounds
    /// Still proving itself. The whole group can be switched off at once from the Firebase
    /// console (`experimental_providers_enabled`), without a build.
    var isExperimental: Bool = false
}

nonisolated struct GeoBounds: Hashable, Sendable {
    var minLat: Double
    var minLon: Double
    var maxLat: Double
    var maxLon: Double

    func contains(_ point: GeoPoint) -> Bool {
        (minLat...maxLat).contains(point.lat) && (minLon...maxLon).contains(point.lon)
    }
}

nonisolated enum SupportedRegions {
    static let all: [SupportedRegion] = [
        SupportedRegion(id: "IL", countryCode: "IL", name: "Israel", providerID: "bus.gov.il", fit: .full,
                        bounds: GeoBounds(minLat: 29.4, minLon: 34.2, maxLat: 33.4, maxLon: 35.9)),

        // Europe
        SupportedRegion(id: "NO", countryCode: "NO", name: "Norway", providerID: "entur", fit: .full,
                        bounds: GeoBounds(minLat: 57.9, minLon: 4.5, maxLat: 71.2, maxLon: 31.2)),
        SupportedRegion(id: "FI-TKU", countryCode: "FI", name: "Turku", providerID: "foli", fit: .full,
                        bounds: GeoBounds(minLat: 60.00, minLon: 21.30, maxLat: 60.76, maxLon: 23.53)),
        SupportedRegion(id: "FI-TRE", countryCode: "FI", name: "Tampere", providerID: "tampere", fit: .full,
                        bounds: GeoBounds(minLat: 61.12, minLon: 23.20, maxLat: 61.89, maxLon: 25.19)),
        SupportedRegion(id: "PT-LIS", countryCode: "PT", name: "Lisbon area", providerID: "carrismetropolitana", fit: .full,
                        bounds: GeoBounds(minLat: 38.40, minLon: -9.51, maxLat: 39.09, maxLon: -8.44)),
        SupportedRegion(id: "FR-RNS", countryCode: "FR", name: "Rennes", providerID: "star-rennes", fit: .full,
                        bounds: GeoBounds(minLat: 47.93, minLon: -1.96, maxLat: 48.31, maxLon: -1.46)),
        SupportedRegion(id: "PL-POZ", countryCode: "PL", name: "Poznań", providerID: "ztm-poznan", fit: .full,
                        bounds: GeoBounds(minLat: 52.15, minLon: 16.45, maxLat: 52.59, maxLon: 17.29)),
        SupportedRegion(id: "GB-LON", countryCode: "GB", name: "London", providerID: "tfl", fit: .arrivalsOnly,
                        bounds: GeoBounds(minLat: 51.28, minLon: -0.51, maxLat: 51.70, maxLon: 0.34)),
        SupportedRegion(id: "AT-VIE", countryCode: "AT", name: "Vienna", providerID: "wienerlinien", fit: .arrivalsOnly,
                        bounds: GeoBounds(minLat: 48.11, minLon: 16.18, maxLat: 48.33, maxLon: 16.58)),
        SupportedRegion(id: "AT-LNZ", countryCode: "AT", name: "Linz", providerID: "efa-linz", fit: .arrivalsOnly,
                        bounds: GeoBounds(minLat: 48.20, minLon: 14.18, maxLat: 48.38, maxLon: 14.42)),
        SupportedRegion(id: "PL-GDN", countryCode: "PL", name: "Gdańsk", providerID: "ztm-gdansk", fit: .full,
                        bounds: GeoBounds(minLat: 54.25, minLon: 18.40, maxLat: 54.60, maxLon: 18.95)),
        // Keyed: unavailable in a build without MOBILITEIT_LU_KEY (see APIKeys). The whole country.
        SupportedRegion(id: "LU", countryCode: "LU", name: "Luxembourg", providerID: "mobiliteit-lu", fit: .arrivalsOnly,
                        bounds: GeoBounds(minLat: 49.44, minLon: 5.73, maxLat: 50.19, maxLon: 6.53)),
        SupportedRegion(id: "BE-BRU", countryCode: "BE", name: "Brussels", providerID: "stib", fit: .full,
                        bounds: GeoBounds(minLat: 50.75, minLon: 4.24, maxLat: 50.94, maxLon: 4.53)),
        // Keyed: unavailable in a build without VBB_KEY (see APIKeys). Berlin and all of Brandenburg.
        SupportedRegion(id: "DE-BER", countryCode: "DE", name: "Berlin & Brandenburg", providerID: "vbb",
                        fit: .arrivalsOnly,
                        bounds: GeoBounds(minLat: 51.35, minLon: 11.25, maxLat: 53.57, maxLon: 14.78)),

        // North America
        SupportedRegion(id: "US-BOS", countryCode: "US", name: "Boston", providerID: "mbta", fit: .full,
                        bounds: GeoBounds(minLat: 42.0, minLon: -71.40, maxLat: 42.75, maxLon: -70.75)),
        // Keyed: unavailable in a build without MTA_BUSTIME_KEY (see APIKeys).
        SupportedRegion(id: "US-NYC", countryCode: "US", name: "New York City", providerID: "mta-bustime", fit: .full,
                        bounds: GeoBounds(minLat: 40.49, minLon: -74.26, maxLat: 40.92, maxLon: -73.69)),
        // Keyed: unavailable in a build without OBA_PUGETSOUND_KEY (see APIKeys).
        SupportedRegion(id: "US-SEA", countryCode: "US", name: "Seattle & Puget Sound", providerID: "oba-pugetsound", fit: .full,
                        bounds: GeoBounds(minLat: 46.90, minLon: -123.20, maxLat: 48.30, maxLon: -121.70)),
        // Keyed: unavailable in a build without OBA_TAMPA_KEY (see APIKeys). Hillsborough County.
        SupportedRegion(id: "US-TPA", countryCode: "US", name: "Tampa", providerID: "oba-tampa", fit: .full,
                        bounds: GeoBounds(minLat: 27.55, minLon: -82.70, maxLat: 28.20, maxLon: -82.05)),
        SupportedRegion(id: "US-MSP", countryCode: "US", name: "Minneapolis–St Paul", providerID: "metrotransit", fit: .full,
                        bounds: GeoBounds(minLat: 44.60, minLon: -93.85, maxLat: 45.35, maxLon: -92.80)),

        // Asia
        SupportedRegion(id: "HK-MTRB", countryCode: "HK", name: "Hong Kong — MTR Bus", providerID: "hk-mtrbus", fit: .full,
                        bounds: GeoBounds(minLat: 22.35, minLon: 113.90, maxLat: 22.48, maxLon: 114.19)),
        SupportedRegion(id: "HK-KMB", countryCode: "HK", name: "Hong Kong — KMB", providerID: "hk-kmb", fit: .arrivalsOnly,
                        bounds: GeoBounds(minLat: 22.23, minLon: 113.89, maxLat: 22.56, maxLon: 114.34)),
        SupportedRegion(id: "HK-CTB", countryCode: "HK", name: "Hong Kong — Citybus", providerID: "hk-citybus", fit: .arrivalsOnly,
                        bounds: GeoBounds(minLat: 22.19, minLon: 113.83, maxLat: 22.56, maxLon: 114.30)),
        SupportedRegion(id: "HK-GMB", countryCode: "HK", name: "Hong Kong — Green Minibus", providerID: "hk-gmb", fit: .arrivalsOnly,
                        bounds: GeoBounds(minLat: 22.15, minLon: 113.83, maxLat: 22.57, maxLon: 114.44)),
        SupportedRegion(id: "HK-NLB", countryCode: "HK", name: "Hong Kong — NLB (Lantau)", providerID: "hk-nlb", fit: .arrivalsOnly,
                        bounds: GeoBounds(minLat: 22.20, minLon: 113.83, maxLat: 22.35, maxLon: 114.06)),
        SupportedRegion(id: "JP-TYO", countryCode: "JP", name: "Tokyo", providerID: "odpt-toei", fit: .full,
                        bounds: GeoBounds(minLat: 35.52, minLon: 139.20, maxLat: 35.83, maxLon: 139.93)),

        // Oceania
        SupportedRegion(id: "AU-ADL", countryCode: "AU", name: "Adelaide", providerID: "adelaide-metro", fit: .full,
                        bounds: GeoBounds(minLat: -35.36, minLon: 138.43, maxLat: -34.50, maxLon: 138.95)),

        // Wave 3 — keyless and verified, but unofficial or fragile, so they sit behind the
        // experimental switch. Istanbul's setup downloads the whole route table (~2 MB gzipped).
        SupportedRegion(id: "TR-IST", countryCode: "TR", name: "Istanbul", providerID: "iett", fit: .full,
                        bounds: GeoBounds(minLat: 40.80, minLon: 28.00, maxLat: 41.60, maxLon: 29.95), isExperimental: true),
        SupportedRegion(id: "CA-TOR", countryCode: "CA", name: "Toronto", providerID: "umo-ttc", fit: .full,
                        bounds: GeoBounds(minLat: 43.58, minLon: -79.64, maxLat: 43.86, maxLon: -79.11), isExperimental: true),
        SupportedRegion(id: "EE-TLL", countryCode: "EE", name: "Tallinn", providerID: "tallinn", fit: .full,
                        bounds: GeoBounds(minLat: 59.35, minLon: 24.53, maxLat: 59.51, maxLon: 24.99), isExperimental: true),
        SupportedRegion(id: "LT-VNO", countryCode: "LT", name: "Vilnius", providerID: "vilnius", fit: .full,
                        bounds: GeoBounds(minLat: 54.56, minLon: 25.02, maxLat: 54.83, maxLon: 25.53), isExperimental: true),
        SupportedRegion(id: "LT-KUN", countryCode: "LT", name: "Kaunas", providerID: "kaunas", fit: .full,
                        bounds: GeoBounds(minLat: 54.82, minLon: 23.76, maxLat: 54.96, maxLon: 23.98), isExperimental: true),
        // MPK Kraków's unofficial TTSS web backend (no published terms); buses only, the tram TTSS is unreachable.
        SupportedRegion(id: "PL-KRK", countryCode: "PL", name: "Kraków", providerID: "mpk-krakow", fit: .full,
                        bounds: GeoBounds(minLat: 49.88, minLon: 19.55, maxLat: 50.27, maxLon: 20.38), isExperimental: true),
        SupportedRegion(id: "CH", countryCode: "CH", name: "Switzerland", providerID: "ch-opendata", fit: .arrivalsOnly,
                        bounds: GeoBounds(minLat: 45.8, minLon: 5.95, maxLat: 47.85, maxLon: 10.5), isExperimental: true),
        // An open licence (CC BY 4.0) on VAG's own portal, but no terms for the API behind it.
        SupportedRegion(id: "DE-NUE", countryCode: "DE", name: "Nuremberg", providerID: "vag-nuernberg", fit: .arrivalsOnly,
                        bounds: GeoBounds(minLat: 49.33, minLon: 10.88, maxLat: 49.63, maxLon: 11.22), isExperimental: true),
        // Official and keyless, but no licence published; bus positions need a key LPP gives on request.
        SupportedRegion(id: "SI-LJU", countryCode: "SI", name: "Ljubljana", providerID: "lpp-ljubljana", fit: .arrivalsOnly,
                        bounds: GeoBounds(minLat: 45.80, minLon: 14.10, maxLat: 46.20, maxLon: 14.89), isExperimental: true),
        // Stops, lines and ETAs from Bizkaibus's own web service, which publishes no terms; only
        // its vehicle feed is open data (CC BY 4.0).
        SupportedRegion(id: "ES-BIO", countryCode: "ES", name: "Bizkaia (Bizkaibus)", providerID: "bizkaibus", fit: .full,
                        bounds: GeoBounds(minLat: 42.95, minLon: -3.46, maxLat: 43.46, maxLon: -2.40), isExperimental: true),
        // Held back, adapters written: MVG (Munich) and efa-vrr (Rhine-Ruhr) forbid commercial use
        // without consent, efa-bw needs an NVBW agreement, SEPTA bars commercial use of its marks,
        // bustimes.org and STCP (Porto, stcp.pt) disallow /api in robots.txt — STCP's positions feed
        // has also been frozen since 2026-09-25 — and SL's keyless patterns are too thin.
    ]

    /// ISO codes of every country with at least one supported region — the App Store territory list.
    static var countryCodes: [String] {
        Array(Set(all.map(\.countryCode))).sorted()
    }

    static func regions(in countryCode: String) -> [SupportedRegion] {
        all.filter { $0.countryCode == countryCode }
    }

    /// Every region covering a point, most specific first (smallest bounding box, so a city beats
    /// its country). More than one means the rider can choose, e.g. KMB or MTR Bus in Hong Kong.
    static func regions(containing point: GeoPoint) -> [SupportedRegion] {
        all.filter { $0.bounds.contains(point) }
            .sorted { area($0.bounds) < area($1.bounds) }
    }

    static func region(containing point: GeoPoint) -> SupportedRegion? {
        regions(containing: point).first
    }

    static func region(providerID: String) -> SupportedRegion? {
        all.first { $0.providerID == providerID }
    }

    private static func area(_ b: GeoBounds) -> Double { (b.maxLat - b.minLat) * (b.maxLon - b.minLon) }
}
