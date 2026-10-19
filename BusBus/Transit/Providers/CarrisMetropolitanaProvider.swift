import Foundation

/// Portugal — Carris Metropolitana, the bus network of the Lisbon metropolitan area outside the
/// city itself (api.carrismetropolitana.pt). Official, open-source, keyless; no published rate
/// limit. GTFS and API data are CC-BY-4.0. Vehicle fixes are ~15–30 s old.
///
/// The API has no name search and no proximity query, so both run on the full stop list
/// (`/v2/stops`, 12.7k stops: 6.8 MB of JSON, ~540 KB gzipped on the wire), downloaded once per
/// session together with `/v2/lines` (~40 KB gz) and `/municipalities` (<1 KB gz).
nonisolated struct CarrisMetropolitanaProvider: TransitProvider {
    let id = "carrismetropolitana"
    let displayName = "Carris Metropolitana (Lisbon area)"
    let attribution: String? = "Data: Carris Metropolitana (CC BY 4.0)"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .scheduledArrivals, .nearbyStops, .routeShape,
    ]
    let suggestedRefreshInterval: Duration = .seconds(20)

    var http = HTTPClient()

    private let base = "https://api.carrismetropolitana.pt"
    private static let store = CarrisStore()

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let network = try await network()
        if query.allSatisfy(\.isNumber) {
            // Stop numbers are six digits on the pole; accept them without the leading zero too.
            let padded = String(repeating: "0", count: max(0, 6 - query.count)) + query
            return [network.stopsByID[padded]].compactMap { $0 }.map(network.stop)
        }
        let tokens = CarrisNetwork.fold(query).split(separator: " ").map(String.init)
        let matches = network.stops.filter { entry in tokens.allSatisfy { entry.searchKey.contains($0) } }
        let folded = CarrisNetwork.fold(query)
        return matches
            .sorted { a, b in
                let ap = a.searchKey.hasPrefix(folded), bp = b.searchKey.hasPrefix(folded)
                return ap != bp ? ap : a.dto.long_name < b.dto.long_name
            }
            .prefix(50)
            .map(network.stop)
    }

    /// One line per pattern (a direction/variant) that the stop list says calls here. Each pattern
    /// is fetched (~10 KB gz) for its headsign and end stops, and kept for `routePattern`.
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let network = try await network()
        guard let entry = network.stopsByID[stop.code] else { throw TransitError.notFound("stop \(stop.code)") }
        let patterns = try await withThrowingTaskGroup(of: DTO.Pattern?.self) { group in
            for id in entry.dto.pattern_ids { group.addTask { try? await pattern(id) } }
            var result: [DTO.Pattern] = []
            for try await pattern in group { if let pattern { result.append(pattern) } }
            return result
        }
        return patterns
            .map { network.line(for: $0) }
            .sorted { ($0.shortName, $0.id) < ($1.shortName, $1.id) }
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let network = try await network()
        let pattern = try await pattern(line.id)
        let stops = pattern.path.sorted { $0.stop_sequence < $1.stop_sequence }.compactMap { node -> PatternStop? in
            guard let entry = network.stopsByID[node.stop_id] else { return nil }
            return PatternStop(stop: network.stop(entry), sequence: node.stop_sequence,
                               distanceAlongRoute: node.distance.map { $0 * 1_000 })   // published in km
        }
        guard !stops.isEmpty else { throw TransitError.notFound("stops for pattern \(line.id)") }
        // The version's shape id rides along, so the line's card asks for the shape alone.
        var line = line
        line.providerRefs["shape"] = pattern.shape_id
        return RoutePattern(line: line, stops: stops)
    }

    /// The GTFS shape of the pattern version running today: one call, by the `shape_id` the
    /// pattern reply names. The id's `[0277F]` prefix is the timetable plan, so a new plan is a new
    /// id; it doubles as the version.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        let id: String
        if let known = pattern.line.providerRefs["shape"] {
            id = known
        } else if let current = try await self.pattern(line.id).shape_id {
            id = current
        } else {
            throw TransitError.notFound("shape of pattern \(line.id)")
        }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_-."))) ?? id
        let shape = try await http.get(DTO.Shape.self, base, "/v2/shapes/\(encoded)")
        let points = shape.geojson.geometry.coordinates.compactMap { $0.count >= 2 ? GeoPoint(lat: $0[1], lon: $0[0]) : nil }
        guard points.count >= 2 else { throw TransitError.notFound("shape \(id)") }
        return RouteShape(points, version: id)
    }

    /// `/v2/vehicles` is the whole fleet (~900 buses, ~100 KB gz); its line filters are ignored,
    /// so it is fetched once per 10 s and shared by every line on the board.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let vehicles = try await Self.store.vehicles.value("all", ttl: .seconds(10)) {
            try await http.get([DTO.Vehicle].self, base, "/v2/vehicles")
        }
        return vehicles
            .filter { $0.pattern_id.map(CarrisNetwork.stripVersion) == line.id }
            .compactMap { vehicle in
                guard let lat = vehicle.lat, let lon = vehicle.lon else { return nil }
                return VehiclePosition(
                    location: GeoPoint(lat: lat, lon: lon),
                    recordedAt: vehicle.timestamp.map { Date(timeIntervalSince1970: $0 / 1_000) },
                    tripId: vehicle.trip_id,
                    plateNumber: vehicle.license_plate,
                    bearing: vehicle.bearing,
                    speedKmh: vehicle.speed,
                    isAccessible: vehicle.wheelchair_accessible
                )
            }
    }

    /// `/v2/arrivals/by_stop` returns the stop's whole service day, past trips included and in no
    /// particular order; it is shared across the lines polled at the same stop.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let all = try await Self.store.arrivals.value(stop.code, ttl: .seconds(10)) {
            try await http.get([DTO.Arrival].self, base, "/v2/arrivals/by_stop/\(stop.code)")
        }
        let cutoff = Date().addingTimeInterval(-60)
        return all
            .filter { $0.pattern_id.map(CarrisNetwork.stripVersion) == line.id && $0.observed_arrival_unix == nil }
            .compactMap { arrival -> Arrival? in
                guard let unix = arrival.estimated_arrival_unix ?? arrival.scheduled_arrival_unix else { return nil }
                let expected = Date(timeIntervalSince1970: unix)
                guard expected >= cutoff else { return nil }
                return Arrival(
                    expectedAt: expected,
                    scheduledAt: arrival.scheduled_arrival_unix.map { Date(timeIntervalSince1970: $0) },
                    isRealtime: arrival.estimated_arrival_unix != nil,
                    tripId: arrival.trip_id
                )
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// Computed from the cached stop list; lines carry only the number (no headsign) so no
    /// per-pattern calls are made — `lines(atStop:)` fills in the rest once a stop is picked.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let network = try await network()
        let latSpan = radiusMeters / 111_000
        let lonSpan = latSpan / max(cos(point.lat * .pi / 180), 0.01)
        return network.stops
            .filter { abs($0.dto.lat - point.lat) <= latSpan && abs($0.dto.lon - point.lon) <= lonSpan }
            .map { entry -> NearbyStop in
                let stop = network.stop(entry)
                return NearbyStop(stop: stop, distanceMeters: RouteGeometry.meters(point, stop.location),
                                  lines: entry.dto.pattern_ids.map { network.line(patternID: $0) })
            }
            .filter { $0.distanceMeters <= radiusMeters }
            .sorted { $0.distanceMeters < $1.distanceMeters }
            .prefix(30)
            .map { $0 }
    }

    // MARK: - Cached reference data

    private func network() async throws -> CarrisNetwork {
        try await Self.store.network.value("network", ttl: nil) { [http, base] in
            async let stops = http.get([DTO.Stop].self, base, "/v2/stops")
            async let lines = http.get([DTO.Line].self, base, "/v2/lines")
            async let municipalities = try? http.get([DTO.Municipality].self, base, "/municipalities")
            return try await CarrisNetwork(stops: stops, lines: lines, municipalities: municipalities ?? [])
        }
    }

    /// A pattern id can have several timetable versions; the one running today (Lisbon date) wins.
    private func pattern(_ id: String) async throws -> DTO.Pattern {
        try await Self.store.patterns.value(id, ttl: .seconds(6 * 3600)) { [http, base] in
            let versions = try await http.get([DTO.Pattern].self, base, "/v2/patterns/\(id)")
            let today = CarrisNetwork.lisbonDay(Date())
            let chosen = versions.first { $0.valid_on?.contains(today) ?? false }
                ?? versions.min { ($0.valid_on?.filter { $0 >= today }.min() ?? "9") < ($1.valid_on?.filter { $0 >= today }.min() ?? "9") }
            guard let chosen else { throw TransitError.notFound("pattern \(id)") }
            return chosen
        }
    }
}

// MARK: - Session cache

private actor CarrisStore {
    let network = Memo<CarrisNetwork>()
    let patterns = Memo<DTO.Pattern>()
    let vehicles = Memo<[DTO.Vehicle]>()
    let arrivals = Memo<[DTO.Arrival]>()
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

/// The stop and line lists, indexed for search, nearby and name lookups.
private nonisolated struct CarrisNetwork: Sendable {
    struct Entry: Sendable {
        var dto: DTO.Stop
        var searchKey: String
    }

    let stops: [Entry]
    let stopsByID: [String: Entry]
    let linesByID: [String: DTO.Line]
    let municipalities: [String: String]

    init(stops: [DTO.Stop], lines: [DTO.Line], municipalities: [DTO.Municipality]) {
        // Stops with no patterns are out of service; leave them out of search and nearby.
        let entries = stops.filter { !$0.pattern_ids.isEmpty }.map {
            Entry(dto: $0, searchKey: Self.fold([$0.long_name, $0.tts_name ?? ""].joined(separator: " ")))
        }
        self.stops = entries
        stopsByID = Dictionary(entries.map { ($0.dto.id, $0) }, uniquingKeysWith: { a, _ in a })
        linesByID = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.municipalities = Dictionary(municipalities.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    func stop(_ entry: Entry) -> TransitStop {
        TransitStop(code: entry.dto.id, name: entry.dto.long_name,
                    city: entry.dto.municipality_id.flatMap { municipalities[$0] },
                    location: GeoPoint(lat: entry.dto.lat, lon: entry.dto.lon))
    }

    /// "stop name, municipality"
    func place(_ stopID: String) -> String? {
        guard let entry = stopsByID[stopID] else { return nil }
        let stop = stop(entry)
        return [stop.name, stop.city].compactMap { $0 }.joined(separator: ", ")
    }

    func line(for pattern: DTO.Pattern) -> TransitLine {
        let path = pattern.path.sorted { $0.stop_sequence < $1.stop_sequence }
        var line = line(patternID: pattern.id)
        line.shortName = pattern.short_name ?? line.shortName
        line.headsign = pattern.headsign
        line.origin = path.first.flatMap { place($0.stop_id) }
        line.destination = path.last.flatMap { place($0.stop_id) }
        return line
    }

    /// Pattern ids are "<line>_<variant>_<direction>", e.g. "3535_0_2".
    func line(patternID: String) -> TransitLine {
        let lineID = String(patternID.split(separator: "_").first ?? Substring(patternID))
        return TransitLine(
            id: patternID,
            shortName: linesByID[lineID]?.short_name ?? lineID,
            agency: "Carris Metropolitana",
            providerRefs: ["lineId": lineID]
        )
    }

    /// Realtime payloads prefix ids with dataset versions: "[PCN1R][BNA17]2209_0_1" → "2209_0_1".
    static func stripVersion(_ id: String) -> String {
        var rest = Substring(id)
        while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") { rest = rest[rest.index(after: close)...] }
        return String(rest)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// GTFS service date ("yyyyMMdd") in Lisbon.
    static func lisbonDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Lisbon")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct Stop: Decodable, Sendable {
        var id: String
        var long_name: String
        var tts_name: String?
        var lat: Double
        var lon: Double
        var municipality_id: String?
        var pattern_ids: [String]
    }

    struct Line: Decodable, Sendable {
        var id: String
        var short_name: String?
        var long_name: String?
    }

    struct Municipality: Decodable, Sendable {
        var id: String
        var name: String
    }

    struct Pattern: Decodable, Sendable {
        struct Node: Decodable, Sendable {
            var stop_id: String
            var stop_sequence: Int
            /// Kilometres from the first stop.
            var distance: Double?
        }

        var id: String
        var line_id: String?
        var short_name: String?
        var headsign: String?
        var valid_on: [String]?
        /// "[0277F]2605_0_1": the timetable plan, then the GTFS shape.
        var shape_id: String?
        var path: [Node]
    }

    /// The same line comes twice, as GeoJSON and as GTFS `points`; only the GeoJSON is read.
    struct Shape: Decodable, Sendable {
        struct Feature: Decodable, Sendable { var geometry: LineString }
        /// `[lon, lat]` pairs.
        struct LineString: Decodable, Sendable { var coordinates: [[Double]] }
        var geojson: Feature
    }

    struct Vehicle: Decodable, Sendable {
        var lat: Double?
        var lon: Double?
        var bearing: Double?
        /// km/h (fleet maximum sits around 100).
        var speed: Double?
        /// Unix milliseconds.
        var timestamp: Double?
        var pattern_id: String?
        var trip_id: String?
        var license_plate: String?
        var wheelchair_accessible: Bool?
    }

    struct Arrival: Decodable, Sendable {
        var pattern_id: String?
        var trip_id: String?
        var scheduled_arrival_unix: Double?
        var estimated_arrival_unix: Double?
        /// Set once the bus has been seen passing the stop.
        var observed_arrival_unix: Double?
    }
}
