import Foundation

/// US, Philadelphia — SEPTA's keyless public API (www3.septa.org/api). Buses only (GTFS route
/// types 3 and 11: bus and trackless trolley); metro, trolley and Regional Rail are left out.
/// See docs/research/worldwide-apis.md §7.6.
///
/// - `Routes/` lists every route with its GTFS type; `v2/stops/?route_id=` gives a route's stops per
///   direction in travel order (one representative pattern per direction). Stop ids are the public
///   numbers on the stop signs.
/// - There is no stop search, and no "routes at this stop": both come from an index of every bus
///   route's stops, fetched once per session (~155 calls, ~3.5 MB, 10–20 s over the network).
///   Some routes (47M, 35, 62, 78 …) answer `v2/stops` with `[]` and so are not offered.
/// - `v2/trips/?route_id=` is the live GPS (`TransitView` in v2 form): position, heading, trip,
///   delay and a Unix `timestamp`; trips without a fix come back with null coordinates.
/// - Minutes come from the legacy `BusSchedules` endpoint, which is the timetable only (no
///   realtime ETA exists, and its trip ids do not join the live ones). It sits behind a load
///   balancer where some backends answer HTTP 501 with the *next day's* first trips; only HTTP 200
///   answers were ever right, so several are asked at once and the first 200 wins.
///
/// No rate limit is published. Licence: the SEPTA developer agreement grants a "non-exclusive,
/// limited and revocable right" but says "Licensee may not use SEPTA's trademarks and copyrighted
/// materials for any commercial or profit-making use" — written confirmation is still owed.
nonisolated struct SEPTAProvider: TransitProvider {
    let id = "septa"
    let displayName = "SEPTA (Philadelphia)"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .scheduledArrivals, .nearbyStops,
    ]
    /// Vehicle fixes are 1–20 s old; a poll is one ~9 KB vehicles call plus the schedule attempts.
    let suggestedRefreshInterval: Duration = .seconds(20)

    var http = HTTPClient()

    private let base = "https://www3.septa.org/api"
    private static let busRouteTypes: Set<String> = ["3", "11"]
    private static let timeZone = TimeZone(identifier: "America/New_York")!
    /// `BusSchedules` asks per wave, and waves: about a third land on a backend that answers 200,
    /// so three waves of four all miss well under 1% of the time. Each answer is ~1–2 KB.
    private static let scheduleAttempts = 4
    private static let scheduleWaves = 3
    /// The load balancer pins a client to one backend with an `AWSELB` cookie, which would pin a
    /// wrong one for good; this session keeps no cookies so every ask is dealt afresh.
    private static let scheduleSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    // MARK: - Stops

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let index = try await stopIndex()
        if query.allSatisfy(\.isNumber) {
            return index.stops[query].map { [$0] } ?? []
        }
        return Self.match(query, in: Array(index.stops.values))
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let index = try await stopIndex()
        let serving = (index.servedBy[stop.code] ?? []).compactMap { key in index.patterns[key].map { (key, $0) } }
        // A pattern that only ends here is no use to someone waiting, unless nothing else stops here.
        let through = serving.filter { $0.1.last?.stop.code != stop.code }
        return (through.isEmpty ? serving : through).map { key, stops in
            line(routeID: key.route, route: index.routes[key.route], direction: key.direction, stops: stops)
        }
    }

    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let index = try await stopIndex()
        let near = index.stops.values
            .map { ($0, RouteGeometry.meters(point, $0.location)) }
            .filter { $0.1 <= radiusMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(15)
        var result: [NearbyStop] = []
        for (stop, distance) in near {
            let served = try await lines(atStop: stop)
            if !served.isEmpty { result.append(NearbyStop(stop: stop, distanceMeters: distance, lines: served)) }
        }
        return result
    }

    /// One route call (cached for the session), so a saved board does not need the whole index.
    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let ref = Ref(line)
        let patterns = try await SEPTACache.shared.stops(route: ref.route) { try await routeStops(ref.route) }
        guard let stops = patterns[ref.direction], stops.count >= 2 else {
            throw TransitError.notFound("stops of route \(ref.route) direction \(ref.direction)")
        }
        return RoutePattern(line: line, stops: stops)
    }

    // MARK: - Live

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let ref = Ref(line)
        let trips = try await http.get([DTO.Trip].self, base, "/v2/trips/", query: ["route_id": ref.route])
        return trips.compactMap { trip in
            guard trip.routeId == ref.route, trip.directionId.map(String.init) == ref.direction,
                  let lat = trip.lat.flatMap(Double.init), let lon = trip.lon.flatMap(Double.init) else { return nil }
            return VehiclePosition(
                location: GeoPoint(lat: lat, lon: lon),
                // Trips without a fix carry seconds-of-day (63240) here instead of a Unix time.
                recordedAt: trip.timestamp.flatMap { $0 > 1_000_000_000 ? Date(timeIntervalSince1970: $0) : nil },
                tripId: trip.tripId,
                plateNumber: trip.vehicleId.flatMap { $0.isEmpty || $0 == "None" ? nil : $0 },
                bearing: trip.heading
            )
        }
    }

    /// Timetable departures of the line at the stop (see the type comment for why several asks).
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let ref = Ref(line)
        let query = ["stop_id": stop.code, "req2": ref.route, "req6": "10"]
        let client = HTTPClient(session: Self.scheduleSession, timeout: 10)
        var schedule: [String: [DTO.ScheduledTrip]]?
        for _ in 0..<Self.scheduleWaves where schedule == nil {
            schedule = await withTaskGroup(of: [String: [DTO.ScheduledTrip]]?.self) { group in
                for _ in 0..<Self.scheduleAttempts {
                    group.addTask {
                        try? await client.get([String: [DTO.ScheduledTrip]].self, base, "/BusSchedules/index.php", query: query)
                    }
                }
                for await answer in group {
                    if let answer { group.cancelAll(); return answer }
                }
                return nil
            }
        }
        guard let schedule else { throw TransitError.badResponse("BusSchedules for stop \(stop.code) route \(ref.route)") }
        return (schedule[ref.route] ?? [])
            .compactMap { trip -> Arrival? in
                guard trip.direction == ref.direction, let time = trip.dateCalender.flatMap(Self.parseDate) else { return nil }
                return Arrival(expectedAt: time, scheduledAt: time, isRealtime: false, tripId: trip.tripId)
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    // MARK: - Helpers

    private struct Ref {
        var route: String
        var direction: String

        init(_ line: TransitLine) {
            let parts = line.id.split(separator: ":", maxSplits: 1).map(String.init)
            route = line.providerRefs["route"] ?? parts.first ?? line.shortName
            direction = line.providerRefs["direction"] ?? (parts.count > 1 ? parts[1] : "0")
        }
    }

    private func line(routeID: String, route: DTO.Route?, direction: String, stops: [PatternStop]) -> TransitLine {
        let last = stops.last?.stop.name
        return TransitLine(
            id: "\(routeID):\(direction)",
            shortName: route?.routeShortName ?? routeID,
            headsign: last,
            agency: "SEPTA",
            origin: stops.first?.stop.name,
            destination: last,
            providerRefs: ["route": routeID, "direction": direction]
        )
    }

    /// A route's stops per direction ("0"/"1"), in sequence order.
    private func routeStops(_ route: String) async throws -> [String: [PatternStop]] {
        let rows = try await http.get([DTO.RouteStop].self, base, "/v2/stops/", query: ["route_id": route])
        var byDirection: [String: [PatternStop]] = [:]
        for row in rows.sorted(by: { $0.stopSequence < $1.stopSequence }) {
            byDirection[String(row.directionId), default: []].append(
                PatternStop(stop: row.stop, sequence: row.stopSequence, distanceAlongRoute: nil))
        }
        return byDirection
    }

    private func stopIndex() async throws -> SEPTAStopIndex {
        try await SEPTACache.shared.index {
            let routes = try await http.get([DTO.Route].self, base, "/Routes/")
                .filter { Self.busRouteTypes.contains($0.routeType) }
            var index = SEPTAStopIndex()
            index.routes = Dictionary(routes.map { ($0.routeId, $0) }, uniquingKeysWith: { first, _ in first })
            // Eight at a time: the per-call latency (~1 s) dominates, not the bytes.
            try await withThrowingTaskGroup(of: (String, [String: [PatternStop]]).self) { group in
                var pending = routes.map(\.routeId)[...]
                let load = { @Sendable (route: String) in
                    (route, try await SEPTACache.shared.stops(route: route) { try await routeStops(route) })
                }
                for route in pending.prefix(8) { group.addTask { try await load(route) } }
                pending = pending.dropFirst(8)
                for try await (route, directions) in group {
                    for (direction, stops) in directions where stops.count >= 2 {
                        let key = SEPTAStopIndex.Key(route: route, direction: direction)
                        index.patterns[key] = stops
                        for pattern in stops {
                            index.stops[pattern.stop.code] = index.stops[pattern.stop.code] ?? pattern.stop
                            index.servedBy[pattern.stop.code, default: []].append(key)
                        }
                    }
                    if let route = pending.popFirst() { group.addTask { try await load(route) } }
                }
            }
            for code in index.servedBy.keys {
                index.servedBy[code]?.sort { ($0.route.count, $0.route, $0.direction) < ($1.route.count, $1.route, $1.direction) }
            }
            return index
        }
    }

    /// "09/22/26 08:41 am", Philadelphia local time.
    private static func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM/dd/yy hh:mm a"
        return formatter.date(from: string.uppercased())
    }

    /// Case- and accent-insensitive "every word appears in the name", exact and prefix matches first.
    private static func match(_ query: String, in stops: [TransitStop], limit: Int = 40) -> [TransitStop] {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let needle = fold(query).replacingOccurrences(of: " and ", with: " & ")
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return stops
            .compactMap { stop -> (TransitStop, Int)? in
                let name = fold(stop.name)
                guard words.allSatisfy(name.contains) else { return nil }
                return (stop, name == needle ? 0 : name.hasPrefix(needle) ? 1 : 2)
            }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.name < $1.0.name }
            .prefix(limit)
            .map(\.0)
    }
}

/// Every bus stop and which route directions serve it, built from all bus routes' `v2/stops`.
private nonisolated struct SEPTAStopIndex: Sendable {
    struct Key: Hashable, Sendable { var route: String; var direction: String }
    var routes: [String: DTO.Route] = [:]
    var stops: [String: TransitStop] = [:]
    var servedBy: [String: [Key]] = [:]
    var patterns: [Key: [PatternStop]] = [:]
}

/// Session caches: per-route stop lists (~20–60 KB each) and the full index (~3.5 MB of JSON in,
/// ~13k stops kept).
private actor SEPTACache {
    static let shared = SEPTACache()

    private var index: Task<SEPTAStopIndex, any Error>?
    private var routes: [String: Task<[String: [PatternStop]], any Error>] = [:]

    func index(load: @escaping @Sendable () async throws -> SEPTAStopIndex) async throws -> SEPTAStopIndex {
        let task = index ?? Task { try await load() }
        index = task
        do { return try await task.value } catch { index = nil; throw error }
    }

    func stops(route: String, load: @escaping @Sendable () async throws -> [String: [PatternStop]]) async throws -> [String: [PatternStop]] {
        let task = routes[route] ?? Task { try await load() }
        routes[route] = task
        do { return try await task.value } catch { routes[route] = nil; throw error }
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct Route: Decodable, Sendable {
        var routeId: String
        var routeShortName: String?
        var routeType: String

        enum CodingKeys: String, CodingKey {
            case routeId = "route_id", routeShortName = "route_short_name", routeType = "route_type"
        }
    }

    struct RouteStop: Decodable, Sendable {
        var directionId: Int
        var stopId: String
        var stopName: String
        var stopSequence: Int
        var stopLat: Double
        var stopLon: Double

        enum CodingKeys: String, CodingKey {
            case directionId = "direction_id", stopId = "stop_id", stopName = "stop_name"
            case stopSequence = "stop_sequence", stopLat = "stop_lat", stopLon = "stop_lon"
        }

        var stop: TransitStop {
            TransitStop(code: stopId, name: stopName, city: nil, location: GeoPoint(lat: stopLat, lon: stopLon))
        }
    }

    /// One trip of `v2/trips`. Coordinates are strings, and null when the bus has no fix.
    struct Trip: Decodable, Sendable {
        var routeId: String
        var tripId: String?
        var directionId: Int?
        var vehicleId: String?
        var lat: String?
        var lon: String?
        var heading: Double?
        var timestamp: Double?

        enum CodingKeys: String, CodingKey {
            case routeId = "route_id", tripId = "trip_id", directionId = "direction_id"
            case vehicleId = "vehicle_id", lat, lon, heading, timestamp
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            routeId = try c.decode(String.self, forKey: .routeId)
            tripId = try? c.decodeIfPresent(String.self, forKey: .tripId)
            directionId = try? c.decodeIfPresent(Int.self, forKey: .directionId)
            vehicleId = try? c.decodeIfPresent(String.self, forKey: .vehicleId)
            lat = try? c.decodeIfPresent(String.self, forKey: .lat)
            lon = try? c.decodeIfPresent(String.self, forKey: .lon)
            // A number on buses, a numeric string on rail.
            heading = (try? c.decodeIfPresent(Double.self, forKey: .heading))
                ?? (try? c.decodeIfPresent(String.self, forKey: .heading)).flatMap { $0.flatMap(Double.init) }
            timestamp = try? c.decodeIfPresent(Double.self, forKey: .timestamp)
        }
    }

    struct ScheduledTrip: Decodable, Sendable {
        var tripId: String?
        var direction: String
        var dateCalender: String?

        enum CodingKeys: String, CodingKey {
            case tripId = "trip_id", direction = "Direction", dateCalender = "DateCalender"
        }
    }
}
