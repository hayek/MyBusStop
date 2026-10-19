import Foundation

/// Germany, Munich — MVG's website backend (www.mvg.de/api/bgw-pt/v3), keyless and unofficial.
/// See docs/research/worldwide-apis.md §5.7.
///
/// Terms (MVG imprint, verbatim): "Unsere Systeme dienen der direkten Kundeninteraktion. Die
/// Verarbeitung unserer Inhalte oder Daten durch Dritte erfordert unsere ausdrückliche Zustimmung.
/// Für private, nicht-kommerzielle Zwecke, wird eine gemäßigte Nutzung ohne unsere ausdrückliche
/// Zustimmung geduldet." — so every call here is one the rider's own screen needs, and nothing is
/// crawled.
///
/// ARRIVALS-ONLY: departures carry live times but there are no vehicle positions.
///
/// MVG's API has no directions and no stop sequences. Its departures do carry the line id of the
/// regional EFA planner ("swm:03054:G:H:016"), so the lines serving a stop and each line's ordered
/// stops come from MVV's EFA (`EFAProvider.Instance.munich`), and MVG supplies stop search, nearby
/// stops and the live departures. Stops are DHIDs ("de:09162:80"), the same in both systems.
nonisolated struct MVGProvider: TransitProvider {
    let id = "mvg"
    let displayName = "MVG (Munich)"
    let attribution: String? = "Daten: Münchner Verkehrsgesellschaft (MVG) / MVV"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .linesAtStop, .routePattern,
        .realtimeArrivals, .scheduledArrivals, .nearbyStops,
    ]
    /// "Moderate use" is what MVG tolerates; one departures call per poll.
    let suggestedRefreshInterval: Duration = .seconds(30)

    var http = HTTPClient()
    var efa = EFAProvider(.munich)

    private let base = "https://www.mvg.de/api/bgw-pt/v3"
    /// MVG's transport types a bus board is for. Rail replacement is a `sev` flag on a BUS, not a
    /// type of its own: asking for "SEV" is answered with HTTP 400.
    private static let surfaceTypes: Set<String> = ["BUS", "TRAM", "REGIONAL_BUS"]

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let stations = try await http.get([DTO.Station].self, base, "/locations",
                                          query: ["query": query, "locationTypes": "STATION"])
        return stations.filter(Self.isSurface).compactMap(\.stop)
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        try await efa.lines(atStop: stop)
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        try await efa.routePattern(for: line)
    }

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }

    /// The endpoint cannot filter by line, so one page of surface departures (about an hour at a busy
    /// stop) is fetched and the line picked out of it.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let departures = try await http.get(
            [DTO.Departure].self, base, "/departures",
            query: ["globalId": stop.code, "limit": "60", "transportTypes": Self.surfaceTypes.sorted().joined(separator: ",")]
        )
        let cutoff = Date().addingTimeInterval(-60)
        return departures
            .filter { $0.lineId == line.id && $0.cancelled != true }
            .compactMap { departure -> Arrival? in
                let planned = departure.plannedDepartureTime.map(DTO.date)
                guard let expected = departure.realtimeDepartureTime.map(DTO.date) ?? planned,
                      expected >= cutoff else { return nil }
                return Arrival(expectedAt: expected, scheduledAt: planned,
                               isRealtime: departure.realtime == true, tripId: departure.tripId)
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// MVG's nearby search gives stations with distances; their lines come from MVV's EFA, one call
    /// per stop for the closest few.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let stations = try await http.get(
            [DTO.Station].self, base, "/stations/nearby",
            query: ["latitude": String(point.lat), "longitude": String(point.lon)]
        )
        let stops = stations
            .filter(Self.isSurface)
            .compactMap { station -> (TransitStop, Double)? in
                guard let stop = station.stop else { return nil }
                let distance = station.distanceInMeters ?? RouteGeometry.meters(point, stop.location)
                return distance <= radiusMeters ? (stop, distance) : nil
            }
            .sorted { $0.1 < $1.1 }
            .prefix(8)
        return await withTaskGroup(of: NearbyStop?.self) { group in
            for (stop, distance) in stops {
                group.addTask {
                    guard let lines = try? await efa.lines(atStop: stop), !lines.isEmpty else { return nil }
                    return NearbyStop(stop: stop, distanceMeters: distance, lines: lines)
                }
            }
            var result: [NearbyStop] = []
            for await stop in group { if let stop { result.append(stop) } }
            return result.sorted { $0.distanceMeters < $1.distanceMeters }
        }
    }

    private static func isSurface(_ station: DTO.Station) -> Bool {
        guard let types = station.transportTypes else { return true }
        return !surfaceTypes.isDisjoint(with: types)
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct Station: Decodable, Sendable {
        var globalId: String?
        var name: String?
        var place: String?
        var latitude: Double?
        var longitude: Double?
        var transportTypes: [String]?
        var distanceInMeters: Double?

        var stop: TransitStop? {
            guard let globalId, let latitude, let longitude else { return nil }
            return TransitStop(code: globalId, name: name ?? globalId, city: place,
                               location: GeoPoint(lat: latitude, lon: longitude))
        }
    }

    struct Departure: Decodable, Sendable {
        /// Milliseconds since 1970.
        var plannedDepartureTime: Double?
        /// Equal to the planned time when `realtime` is false.
        var realtimeDepartureTime: Double?
        var realtime: Bool?
        var cancelled: Bool?
        var lineId: String?
        var tripId: String?
    }

    static func date(_ milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
