import Foundation

// Provider-agnostic transit domain model.
// Every 3rd-party adapter maps its own responses into these types; nothing above
// the provider layer should know which service the data came from.

nonisolated struct GeoPoint: Hashable, Sendable, Codable {
    var lat: Double
    var lon: Double
}

nonisolated struct TransitStop: Identifiable, Hashable, Sendable, Codable {
    /// Public stop code printed on the sign (Israel: 5-digit `stop_code`). Stable across days.
    var code: String
    var name: String
    var city: String?
    var location: GeoPoint
    /// Street address, when the provider publishes one ("דרך אלנבי 166", "Mount Auburn Street &
    /// DeWolfe Street"). In the provider's own language: it is the operator's record of where the
    /// pole stands, and outranks a geocoder's guess whatever language the app is in.
    var address: String? = nil

    var id: String { code }
}

nonisolated extension TransitStop {
    /// An address from the pieces a provider publishes, with blanks dropped; nil when nothing is left.
    static func address(_ parts: [String?], separator: String = " ") -> String? {
        let kept = parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: separator)
    }
}

/// One direction/variant of a line — the unit a rider actually waits for
/// ("112 toward Hof HaCarmel"). Israel: SIRI `line_ref` / bus.gov.il `routeId`.
nonisolated struct TransitLine: Identifiable, Hashable, Sendable, Codable {
    var id: String
    var shortName: String
    var headsign: String?
    var agency: String?
    /// First and last stop of the line, as "stop name, city" (from the route's long name or stop list).
    var origin: String?
    var destination: String?
    /// Line-level accessibility flag, when the provider publishes one.
    var isAccessible: Bool?
    /// The palette index this line is published in, when the operator has one. Israel's feeds do
    /// not, so it is usually nil and the colour is derived from the line id instead.
    var brandColorIndex: Int?
    /// Provider-specific extras an adapter needs to call back (e.g. bus.gov.il `routeDesc`).
    var providerRefs: [String: String] = [:]

    /// Where the line goes, as every list names it: the destination, else the headsign.
    var destinationLabel: String? { destination ?? headsign }
}

nonisolated struct PatternStop: Hashable, Sendable, Codable {
    var stop: TransitStop
    var sequence: Int
    /// Metres from the start of the route, when the provider publishes it (GTFS `shape_dist_traveled`).
    var distanceAlongRoute: Double?
}

/// Ordered stops of a line (one direction).
nonisolated struct RoutePattern: Hashable, Sendable, Codable {
    var line: TransitLine
    var stops: [PatternStop]

    var firstStop: TransitStop? { stops.first?.stop }
    var lastStop: TransitStop? { stops.last?.stop }
}

nonisolated struct VehiclePosition: Hashable, Sendable {
    var location: GeoPoint
    /// When the GPS fix was recorded; nil when the provider doesn't say (bus.gov.il).
    var recordedAt: Date?
    /// Metres along the route when the provider computes it (Stride); otherwise derived by snapping.
    var distanceAlongRoute: Double?
    var tripId: String?
    /// Israel: SIRI `vehicle_ref` is the licence plate number.
    var plateNumber: String?
    var bearing: Double?
    var speedKmh: Double?
    /// Planned departure from the first stop (SIRI OriginAimedDepartureTime).
    var aimedDeparture: Date?
    /// When the bus actually left the first stop (derived from its first GPS samples).
    var actualDeparture: Date?
    var isAccessible: Bool?
}

nonisolated struct Arrival: Hashable, Sendable {
    var expectedAt: Date
    var scheduledAt: Date?
    var isRealtime: Bool
    var tripId: String?
    /// Some providers attach the bus position to the prediction.
    var vehicleLocation: GeoPoint?

    /// Signed lateness, when the provider publishes both a timetable and a prediction. The vehicle
    /// feed carries no delay of its own, so this is the only honest source for "running late".
    var delay: TimeInterval? { scheduledAt.map { expectedAt.timeIntervalSince($0) } }
}

/// A stop near the rider, with the lines that serve it — the NEARBY list of the setup screen.
nonisolated struct NearbyStop: Identifiable, Hashable, Codable, Sendable {
    var stop: TransitStop
    var distanceMeters: Double
    var lines: [TransitLine]

    var id: String { stop.code }
}

nonisolated struct ProviderCapabilities: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let stopSearchByName = ProviderCapabilities(rawValue: 1 << 0)
    static let stopSearchByCode = ProviderCapabilities(rawValue: 1 << 1)
    static let linesAtStop = ProviderCapabilities(rawValue: 1 << 2)
    static let routePattern = ProviderCapabilities(rawValue: 1 << 3)
    static let vehiclePositions = ProviderCapabilities(rawValue: 1 << 4)
    static let realtimeArrivals = ProviderCapabilities(rawValue: 1 << 5)
    static let scheduledArrivals = ProviderCapabilities(rawValue: 1 << 6)
    static let nearbyStops = ProviderCapabilities(rawValue: 1 << 7)
    /// `routeShape(for:pattern:)` returns the line's real path (docs/research/route-shapes.md).
    static let routeShape = ProviderCapabilities(rawValue: 1 << 8)
}

nonisolated enum TransitError: LocalizedError, Sendable {
    case unsupported(String)
    case notFound(String)
    case badResponse(String)
    /// The provider needs an API key and this build has none (see `APIKeys`).
    case missingAPIKey(String)
    /// Nothing to answer right now, though there may be later (no departure tonight to find a
    /// trip by): ask again next time instead of remembering the answer.
    case tryLater(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let what): "Not supported by this provider: \(what)"
        case .notFound(let what): "Not found: \(what)"
        case .badResponse(let what): "Bad response: \(what)"
        case .missingAPIKey(let name): "No API key configured: \(name)"
        case .tryLater(let what): "Not available right now: \(what)"
        }
    }
}
