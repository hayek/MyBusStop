import Foundation

/// Portugal — STCP, the Porto bus operator, through the JSON its own website (stcp.pt) calls.
/// UNOFFICIAL: an internal API with no published terms, SLA or rate limit, and `robots.txt` asks
/// crawlers to stay out of `/api`. It may change or close at any time. Keyless.
/// See docs/research/worldwide-apis.md §6.6.
///
/// A *line* here is one route in one direction (`direction_id` 0/1), as the site's stop page
/// lists them. The realtime board gives no direction field, but its `trip_id` starts
/// "<route>_<variant>_<direction + 1>" ("600_0_2|307|D1|T8|N11"), which is what picks the
/// direction out. Every call is per stop or per route, a few KB each; nothing is bulk-cached.
///
/// Positions: Porto Digital's FIWARE broker carries the STCP fleet as NGSI v2 `Vehicle`
/// entities, filterable by route and direction (~1 KB a line). The adapter reads them, but
/// `.vehiclePositions` stays off: the STCP entities stopped updating on 2026-09-25 08:25 UTC
/// while the broker's other entities stay live. Turn it on once the feed moves again.
nonisolated struct STCPProvider: TransitProvider {
    let id = "stcp-porto"
    let displayName = "STCP (Porto)"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .realtimeArrivals, .nearbyStops,
    ]
    let suggestedRefreshInterval: Duration = .seconds(30)

    var http = HTTPClient()

    private let base = "https://stcp.pt/api"
    private let broker = "https://broker.fiware.urbanplatform.portodigital.pt/v2"
    private static let store = STCPStore()

    /// The server matches a substring of the stop name or code, accents folded ("bolhao" finds
    /// BOLHÃO), and answers at most 12. Several words are not matched as such, so they are sent
    /// as the longest one and the rest checked here.
    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let tokens = STCPText.fold(query).split(separator: " ").map(String.init)
        guard tokens.count > 1, let longest = tokens.max(by: { $0.count < $1.count }) else {
            return try await http.get(DTO.StopList.self, base, "/stops/search", query: ["q": query, "limit": "50"]).stops.map(\.stop)
        }
        let response = try await http.get(DTO.StopList.self, base, "/stops/search", query: ["q": longest, "limit": "50"])
        return response.stops
            .filter { stop in tokens.allSatisfy { STCPText.fold("\(stop.name) \(stop.id)").contains($0) } }
            .map(\.stop)
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let routes = try await http.get(DTO.StopRoutes.self, base, "/stops/\(Self.escaped(stop.code))/routes")
        return (routes.dropdown_routes ?? [])
            .map(\.line)
            .sorted { ($0.shortName.count, $0.shortName, $0.id) < ($1.shortName.count, $1.shortName, $1.id) }
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let ref = try LineRef(line)
        let response = try await Self.store.patterns.value(line.id, ttl: .seconds(6 * 3600)) { [http, base] in
            try await http.get(DTO.PatternResponse.self, base, "/route/\(Self.escaped(ref.routeID))/stops/direction",
                               query: ["direction_id": ref.direction])
        }
        let stops = response.stops
            .sorted { $0.stop_sequence < $1.stop_sequence }
            .map { PatternStop(stop: $0.stop, sequence: $0.stop_sequence, distanceAlongRoute: nil) }
        guard !stops.isEmpty else { throw TransitError.notFound("stops for route \(ref.routeID) direction \(ref.direction)") }
        return RoutePattern(line: line, stops: stops)
    }

    /// FIWARE `Vehicle` entities of the route and direction. The broker keeps the last fix of a
    /// bus that has stopped reporting, so anything older than three minutes is left out.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let ref = try LineRef(line)
        let vehicles = try await http.get([DTO.Vehicle].self, broker, "/entities", query: [
            "type": "Vehicle",
            "q": "vehicleType==bus;annotations=='stcp:route:\(ref.routeID)';annotations=='stcp:sentido:\(ref.direction)'",
            "attrs": "location,bearing,observationDateTime,annotations,fleetVehicleId",
            "options": "keyValues",
            "limit": "100",
        ])
        let cutoff = Date().addingTimeInterval(-180)
        return vehicles.compactMap { vehicle in
            guard let point = vehicle.location?.coordinates, point.count == 2,
                  let recorded = vehicle.observationDateTime.flatMap(STCPText.date), recorded >= cutoff else { return nil }
            return VehiclePosition(
                location: GeoPoint(lat: point[1], lon: point[0]),
                recordedAt: recorded,
                tripId: vehicle.annotations?.first { $0.hasPrefix("stcp:nr_viagem:") }.map { String($0.dropFirst(15)) },
                plateNumber: vehicle.fleetVehicleId,
                bearing: vehicle.bearing
            )
        }
    }

    /// The stop's board covers every line there and is shared across them for 10 s. Each entry
    /// carries a prediction and `delay_minutes` (late is positive), from which the timetable time
    /// is put back; `scheduled_arrival_time` itself is always null. A board whose `data_source`
    /// is not "realtime" is the timetable alone.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let ref = try LineRef(line)
        let board = try await Self.store.boards.value(stop.code, ttl: .seconds(10)) { [http, base] in
            try await http.get(DTO.Board.self, base, "/stops/\(Self.escaped(stop.code))/realtime")
        }
        let isRealtime = board.data_source == "realtime"
        let cutoff = Date().addingTimeInterval(-60)
        return (board.arrivals ?? [])
            .filter { $0.route_short_name == line.shortName && ($0.direction.map { $0 == ref.direction } ?? true) }
            .compactMap { arrival -> Arrival? in
                guard let expected = arrival.estimated_arrival_time.flatMap(STCPText.date), expected >= cutoff else { return nil }
                let scheduled = arrival.scheduled_arrival_time.flatMap(STCPText.date)
                    ?? arrival.delay_minutes.map { expected.addingTimeInterval(-$0 * 60) }
                return Arrival(
                    expectedAt: expected,
                    scheduledAt: isRealtime ? scheduled : expected,
                    isRealtime: isRealtime,
                    tripId: arrival.trip_id
                )
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// Distances come from the server (metres). Its lines carry the route only, not the
    /// direction — `lines(atStop:)` fills that in once a stop is picked.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let response = try await http.get(DTO.StopList.self, base, "/stops/nearby", query: [
            "lat": String(point.lat), "lng": String(point.lon), "radius": String(Int(radiusMeters)),
        ])
        return response.stops
            .map { entry in
                let stop = entry.stop
                return NearbyStop(stop: stop, distanceMeters: entry.distance ?? RouteGeometry.meters(point, stop.location),
                                  lines: (entry.routes ?? []).map(\.line))
            }
            .filter { $0.distanceMeters <= radiusMeters }
            .sorted { $0.distanceMeters < $1.distanceMeters }
            .prefix(30)
            .map { $0 }
    }

    // MARK: - Helpers

    private struct LineRef {
        var routeID: String
        var direction: String

        init(_ line: TransitLine) throws {
            guard let routeID = line.providerRefs["routeId"], let direction = line.providerRefs["direction"] else {
                throw TransitError.unsupported("line \(line.id) has no STCP route/direction (was it loaded from another provider?)")
            }
            (self.routeID, self.direction) = (routeID, direction)
        }
    }

    /// Stop and route ids are letters and digits ("BLRB1", "11M"), but they are path segments.
    private static func escaped(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? id
    }
}

// MARK: - Session cache

private actor STCPStore {
    let patterns = Memo<DTO.PatternResponse>()
    let boards = Memo<DTO.Board>()
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

private nonisolated enum STCPText {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// "2026-09-28T14:49:00+01:00" (stcp.pt) or "2026-09-25T08:24:53.00Z" (FIWARE).
    static func date(_ string: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }

    /// Night lines' headsigns end in an asterisk ("AV. ALIADOS*"), a footnote the site never explains.
    static func headsign(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: CharacterSet(charactersIn: "* ").union(.whitespaces))
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    /// `/stops/search` and `/stops/nearby` share this shape; only nearby sets `distance`.
    struct StopList: Decodable, Sendable {
        var stops: [Stop]
    }

    struct Stop: Decodable, Sendable {
        var id: String
        var name: String
        var latitude: Double
        var longitude: Double
        /// Metres from the query point.
        var distance: Double?
        var routes: [Route]?

        var stop: TransitStop {
            TransitStop(code: id, name: name, location: GeoPoint(lat: latitude, lon: longitude))
        }
    }

    struct Route: Decodable, Sendable {
        var id: String
        var number: String?

        var line: TransitLine {
            TransitLine(id: id, shortName: number ?? id, agency: "STCP", providerRefs: ["routeId": id])
        }
    }

    struct StopRoutes: Decodable, Sendable {
        var dropdown_routes: [DirectedRoute]?
    }

    struct DirectedRoute: Decodable, Sendable {
        var route_id: String
        var direction_id: Int
        var route_short_name: String?
        var trip_headsign: String?

        var line: TransitLine {
            TransitLine(
                id: "\(route_id)_\(direction_id)",
                shortName: route_short_name ?? route_id,
                headsign: STCPText.headsign(trip_headsign),
                agency: "STCP",
                providerRefs: ["routeId": route_id, "direction": String(direction_id)]
            )
        }
    }

    struct PatternResponse: Decodable, Sendable {
        var stops: [PatternNode]
    }

    struct PatternNode: Decodable, Sendable {
        var stop_id: String
        var stop_name: String
        var stop_lat: Double
        var stop_lon: Double
        var stop_sequence: Int

        var stop: TransitStop {
            TransitStop(code: stop_id, name: stop_name, location: GeoPoint(lat: stop_lat, lon: stop_lon))
        }
    }

    struct Board: Decodable, Sendable {
        var arrivals: [BoardArrival]?
        /// "realtime" when the predictions are live.
        var data_source: String?
    }

    struct BoardArrival: Decodable, Sendable {
        var route_short_name: String?
        var trip_headsign: String?
        var estimated_arrival_time: String?
        var scheduled_arrival_time: String?
        /// Minutes late (negative when early), to a tenth.
        var delay_minutes: Double?
        var trip_id: String?

        /// "600_0_2|307|D1|T8|N11" → "1": the third part is `direction_id` + 1.
        var direction: String? {
            guard let head = trip_id?.split(separator: "|").first else { return nil }
            let parts = head.split(separator: "_")
            guard parts.count >= 3, let value = Int(parts[2]), value >= 1 else { return nil }
            return String(value - 1)
        }
    }

    /// NGSI v2 `Vehicle` in `keyValues` form.
    struct Vehicle: Decodable, Sendable {
        struct Point: Decodable, Sendable {
            /// [lon, lat]
            var coordinates: [Double]
        }

        var location: Point?
        var bearing: Double?
        var observationDateTime: String?
        /// "stcp:route:200", "stcp:sentido:1", "stcp:nr_viagem:<trip id>", …
        var annotations: [String]?
        var fleetVehicleId: String?
    }
}
