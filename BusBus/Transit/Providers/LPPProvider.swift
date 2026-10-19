import Foundation

/// Ljubljana, Slovenia — LPP (Ljubljanski potniški promet) open API, data.lpp.si/api, documented
/// at data.lpp.si/doc. Official and keyless for stops, lines and arrivals; no licence text or rate
/// limit is published, so the credit line only names the source and the region sits behind the
/// experimental switch. See docs/research/worldwide-apis.md §6.11.
///
/// ARRIVALS-ONLY: the vehicle endpoints (`bus/buses-on-route`, `bus/bus-details` and every
/// `gtfs/gtfs-rt*` feed) answer 401 "No permission for this API" without a key, which LPP issues on
/// request. Arrivals already carry each bus's `vehicle_id`, so a keyed build can pair them with
/// positions later; until one is verified, `vehicles(for:)` stays empty.
///
/// A "stop" is one side of the street, coded by its six-digit `ref_id` (600011 and 600012 are the
/// two Bavarski dvor platforms). A line is one `trip_id`: LPP's sub-route, a single direction and
/// variant ("6 → ČRNUČE"), which both the arrivals and the ordered stop list take. There is no name
/// search, so the full station list (~220 KB, ~47 KB gzipped) is fetched once per session and
/// searched on the phone. Stop names are Slovenian, as LPP publishes them; destinations come in the
/// capitals of LPP's own displays.
nonisolated struct LPPProvider: TransitProvider {
    let id = "lpp-ljubljana"
    let displayName = "LPP (Ljubljana)"
    /// No licence is published; the source is credited all the same, as for Tallinn.
    let attribution: String? = "Podatki: LPP d.o.o. (data.lpp.si)"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .realtimeArrivals, .scheduledArrivals, .nearbyStops, .routeShape,
    ]
    /// No stated limit; one arrivals call (~18 KB at the busiest stop) per poll.
    let suggestedRefreshInterval: Duration = .seconds(20)

    var http = HTTPClient()

    fileprivate static let base = "https://data.lpp.si/api"
    /// A line's sub-routes with their paths, for the line card.
    private static let routes = Memo<DTO.Routes>()

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let stations = try await LPPStations.shared.all(http)
        if query.count == 6, query.allSatisfy(\.isNumber) {
            return stations.first { $0.stop.code == query }.map { [$0.stop] } ?? []
        }
        let needle = LPPStations.fold(query)
        return stations
            .filter { $0.folded.contains(needle) }
            .sorted { a, b in
                let (ap, bp) = (a.folded.hasPrefix(needle), b.folded.hasPrefix(needle))
                if ap != bp { return ap }
                return a.stop.name == b.stop.name ? a.stop.code < b.stop.code
                    : a.stop.name.localizedStandardCompare(b.stop.name) == .orderedAscending
            }
            .prefix(40)
            .map(\.stop)
    }

    /// Every sub-route LPP lists at the stop, less the depot runs (`is_garage`, which repeat a
    /// regular trip's id) and the variants that end here — a bus that terminates at the stop is not
    /// one a rider can board.
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let response = try await http.get(DTO.RoutesOnStation.self, Self.base, "/station/routes-on-station",
                                          query: ["station-code": stop.code])
        let here = LPPStations.fold(stop.name)
        var seen = Set<String>()
        return response.data
            .filter { !$0.is_garage && LPPStations.fold($0.route_name) != here }
            .filter { seen.insert($0.trip_id.lowercased()).inserted }
            .sorted { a, b in
                a.route_number == b.route_number ? a.route_name < b.route_name
                    : a.route_number.localizedStandardCompare(b.route_number) == .orderedAscending
            }
            .map { entry in
                TransitLine(
                    id: entry.trip_id,
                    shortName: DTO.lineName(entry.route_number),
                    headsign: entry.route_name,
                    agency: "LPP",
                    origin: DTO.origin(of: entry.route_group_name),
                    destination: entry.route_name,
                    providerRefs: ["routeId": entry.route_id, "stationCode": stop.code]
                )
            }
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let response = try await http.get(DTO.StationsOnRoute.self, Self.base, "/route/stations-on-route",
                                          query: ["trip-id": line.id])
        let stops = response.data
            .sorted { $0.order_no < $1.order_no }
            .map { entry in
                PatternStop(stop: TransitStop(code: entry.station_code, name: entry.name, city: nil,
                                              location: GeoPoint(lat: entry.latitude, lon: entry.longitude)),
                            sequence: entry.order_no, distanceAlongRoute: nil)
            }
        guard stops.count >= 2 else { throw TransitError.notFound("stops for line \(line.id)") }
        return RoutePattern(line: line, stops: stops)
    }

    /// `route/routes?route-id=&shape=1` (documented at data.lpp.si/doc) returns every sub-route of
    /// the line with its GeoJSON path (lon,lat, in travel order); this one's is picked by `trip_id`.
    /// 8–14 KB gzipped. At a P+R terminus the stop stands ~70 m from where the path starts.
    /// A few paths come as a MultiLineString instead: pieces with gaps of up to ~200 m between them,
    /// some stored backwards (3G's terminal loop at Grosuplje). They are threaded from the first
    /// stop to the last the way EFA's pieces are. The reply serves every sub-route of the line, so
    /// it is kept ten minutes for the other direction's card.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        guard let route = line.providerRefs["routeId"] else {
            throw TransitError.unsupported("line \(line.id) has no LPP route id (was it loaded from another provider?)")
        }
        let response = try await Self.routes.value(route, ttl: .seconds(600)) { [http] in
            try await http.get(DTO.Routes.self, Self.base, "/route/routes", query: ["route-id": route, "shape": "1"])
        }
        let trip = line.id.lowercased()
        guard let pieces = response.data.first(where: { $0.trip_id.lowercased() == trip })?.geojson_shape?.pieces,
              !pieces.isEmpty else {
            throw TransitError.notFound("shape of LPP line \(line.id)")
        }
        guard pieces.count > 1 else { return RouteShape(pieces[0]) }
        return RouteShape(EFAShape.stitch(pieces, stops: pattern.stops.map(\.stop.location)))
    }

    /// Positions need a key LPP hands out on request (see the type's comment).
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }

    /// The stop's board, kept to this sub-route. Times are whole minutes from now (`eta_min`);
    /// `type` 1 is the timetable, while 0 (predicted), 2 (arriving) and 3 (on a detour) come from
    /// the bus itself. Entries carrying LPP's placeholder vehicle id are "ghost" arrivals with no
    /// bus behind them; the open-source Travana client hides them (github.com/franga2000/busomatik), and so
    /// does this.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let response = try await http.get(DTO.StationArrivals.self, Self.base, "/station/arrival",
                                          query: ["station-code": stop.code])
        let now = Date()
        let trip = line.id.lowercased()
        return response.data.arrivals
            .filter { $0.trip_id.lowercased() == trip && $0.vehicle_id != DTO.ghostVehicle }
            .map { entry in
                Arrival(expectedAt: now.addingTimeInterval(Double(max(entry.eta_min, 0)) * 60), scheduledAt: nil,
                        isRealtime: entry.type != 1, tripId: entry.vehicle_id, vehicleLocation: nil)
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// The server's own radius query. It lists only route numbers per stop, so the lines here are
    /// labels for the list; picking the stop asks `lines(atStop:)` for the real ones.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let response = try await http.get(DTO.Stations.self, Self.base, "/station/stations-in-range", query: [
            "latitude": String(point.lat), "longitude": String(point.lon), "radius": String(Int(radiusMeters)),
        ])
        return response.data
            .filter { !($0.route_groups_on_station ?? []).isEmpty }
            .map { entry in
                let stop = entry.stop
                let lines = (entry.route_groups_on_station ?? []).map { group in
                    TransitLine(id: "\(group)@\(entry.ref_id)", shortName: DTO.lineName(group), agency: "LPP",
                                providerRefs: ["stationCode": entry.ref_id])
                }
                return NearbyStop(stop: stop, distanceMeters: RouteGeometry.meters(point, stop.location), lines: lines)
            }
            .sorted { $0.distanceMeters < $1.distanceMeters }
    }
}

// MARK: - Station list (once per session)

/// Every active station, from `station/station-details` with no code. A failed load is forgotten
/// so the next call tries again.
private actor LPPStations {
    static let shared = LPPStations()

    struct Entry: Sendable {
        var stop: TransitStop
        var folded: String
    }

    private var loading: Task<[Entry], any Error>?

    func all(_ http: HTTPClient) async throws -> [Entry] {
        if let loading { return try await loading.value }
        let task = Task {
            try await http.get(DTO.Stations.self, LPPProvider.base, "/station/station-details").data
                .filter { !($0.route_groups_on_station ?? []).isEmpty }
                .map { Entry(stop: $0.stop, folded: Self.fold($0.name)) }
        }
        loading = task
        do { return try await task.value } catch {
            loading = nil
            throw error
        }
    }

    /// Case- and accent-insensitive, so "zelezna" finds "Železna" and "BEŽIGRAD" matches "Bežigrad".
    nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "sl_SI"))
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Coalesces concurrent loads of the same key and keeps the result for `ttl` (forever when nil).
/// Failures are not kept.
private actor Memo<Value: Sendable> {
    private var entries: [String: (at: ContinuousClock.Instant, task: Task<Value, any Error>)] = [:]

    func value(_ key: String, ttl: Duration?, _ load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let now = ContinuousClock.now
        if let entry = entries[key], ttl.map({ now - entry.at < $0 }) ?? true {
            return try await entry.task.value
        }
        if let ttl { entries = entries.filter { now - $0.value.at < ttl } }
        let task = Task { try await load() }
        entries[key] = (now, task)
        do {
            return try await task.value
        } catch {
            if entries[key]?.task == task { entries[key] = nil }
            throw error
        }
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct Stations: Decodable, Sendable { var data: [Station] }

    struct Station: Decodable, Sendable {
        var ref_id: String
        var name: String
        var latitude: Double
        var longitude: Double
        /// Route numbers without their suffix letters ("6", not "6B").
        var route_groups_on_station: [String]?

        /// Stops that share a name (the two sides of a street) are told apart by the lines they serve.
        var stop: TransitStop {
            let groups = (route_groups_on_station ?? []).map(DTO.lineName)
            return TransitStop(code: ref_id, name: name, city: groups.isEmpty ? nil : groups.joined(separator: ", "),
                               location: GeoPoint(lat: latitude, lon: longitude))
        }
    }

    struct RoutesOnStation: Decodable, Sendable { var data: [RouteOnStation] }

    struct RouteOnStation: Decodable, Sendable {
        var route_id: String
        var route_number: String
        var trip_id: String
        /// The destination, in capitals ("ČRNUČE"); "GARAŽA" on depot runs.
        var route_name: String
        /// "DOLGI MOST P+R - ČRNUČE".
        var route_group_name: String?
        var is_garage: Bool
    }

    struct StationsOnRoute: Decodable, Sendable { var data: [RouteStation] }

    struct RouteStation: Decodable, Sendable {
        var name: String
        var station_code: String
        var order_no: Int
        var latitude: Double
        var longitude: Double
    }

    struct Routes: Decodable, Sendable { var data: [Route] }

    struct Route: Decodable, Sendable {
        var trip_id: String
        var geojson_shape: Shape?
    }

    /// A GeoJSON LineString or MultiLineString, as its pieces.
    struct Shape: Decodable, Sendable {
        var pieces: [[GeoPoint]]

        private enum CodingKeys: String, CodingKey { case type, coordinates }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let lines: [[[Double]]]
            if try container.decodeIfPresent(String.self, forKey: .type) == "MultiLineString" {
                lines = try container.decode([[[Double]]].self, forKey: .coordinates)
            } else {
                lines = [try container.decode([[Double]].self, forKey: .coordinates)]
            }
            pieces = lines.map { $0.compactMap { $0.count >= 2 ? GeoPoint(lat: $0[1], lon: $0[0]) : nil } }
        }
    }

    struct StationArrivals: Decodable, Sendable {
        struct Payload: Decodable, Sendable { var arrivals: [Arrival] }
        var data: Payload
    }

    struct Arrival: Decodable, Sendable {
        var trip_id: String
        var vehicle_id: String?
        /// 0 predicted, 1 scheduled, 2 arriving, 3 on a detour.
        var type: Int
        var eta_min: Int
    }

    /// The vehicle id of arrivals no bus stands behind.
    static let ghostVehicle = "22222222-2222-2222-2222-222222222222"

    /// The documentation shows zero-padded numbers ("06B"); the live API does not. Either way, "6B".
    static func lineName(_ number: String) -> String {
        let trimmed = number.drop { $0 == "0" }
        return trimmed.isEmpty ? number : String(trimmed)
    }

    /// "DOLGI MOST P+R - ČRNUČE" → "DOLGI MOST P+R". Nil when the name has no " - " to split on.
    static func origin(of groupName: String?) -> String? {
        guard let groupName, let range = groupName.range(of: " - ") else { return nil }
        let origin = groupName[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        return origin.isEmpty ? nil : origin
    }
}
