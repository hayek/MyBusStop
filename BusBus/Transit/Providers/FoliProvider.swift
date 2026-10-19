import Foundation

/// Turku region, Finland — Föli's open data at data.foli.fi (City of Turku). Keyless, no stated rate
/// limit. Live data is SIRI-style JSON (`/siri/vm` for vehicles, `/siri/sm/{stop}` for departures);
/// timetables are a GTFS feed exposed as JSON under `/gtfs/v0/{dataset}/…`.
///
/// Licence CC BY 4.0, and the attribution wording is fixed by the publisher:
/// "Source: Turku region public transport operational and timetable data. Data maintained by City of
/// Turku. Downloaded from data.foli.fi under CC BY 4.0."
///
/// Every live record carries `__routeref` and `__directionid`, the GTFS `route_id` and `direction_id`
/// of its trip, so a line here is one GTFS route in one direction and live data is matched on those
/// two rather than on the public line number (which the `…A`/`…T` variants share with their base line).
nonisolated struct FoliProvider: TransitProvider {
    let id = "foli"
    let displayName = "Föli (Turku)"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .scheduledArrivals, .nearbyStops, .routeShape,
    ]
    /// There is no per-line vehicle query: every poll of `/siri/vm` is the whole fleet (~260 KB
    /// gzipped, ~200 vehicles), so this stays at the slow end of the board's band.
    let suggestedRefreshInterval: Duration = .seconds(30)

    let attribution: String? = "Source: Turku region public transport operational and timetable data. Data maintained by City of Turku. Downloaded from data.foli.fi under CC BY 4.0."
    static let timeZone = TimeZone(identifier: "Europe/Helsinki")!

    var http = HTTPClient()

    private static let base = "https://data.foli.fi"
    private static let store = FoliStore()

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let stops = try await Self.store.stops(http)
        if let exact = stops[query] { return [exact.stop(id: query)] }
        let needle = Self.fold(query)
        return stops
            .filter { Self.fold($0.value.stop_name).contains(needle) }
            .map { $0.value.stop(id: $0.key) }
            .sorted { ($0.name, $0.code) < ($1.name, $1.code) }
            .prefix(50)
            .map { $0 }
    }

    /// Built from the stop's full timetable (`stop_times/stop/{id}`, ~7 KB for a busy stop) joined to
    /// the cached trip list, so every route+direction that ever calls here is listed — not only the
    /// ones with a bus due in the next hour, which is all `/siri/sm` would show.
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let version = try await Self.store.version(http)
        async let tripsTask = Self.store.trips(http)
        async let routesTask = Self.store.routes(http)
        let times = try await http.get([DTO.StopTimeAtStop].self, Self.base, "/gtfs/v0/\(version)/stop_times/stop/\(stop.code)")
        let (trips, routes) = try await (tripsTask, routesTask)

        // A trip that only sets down here (its terminus) is not one the rider can board.
        let boarding = times.filter { $0.pickup_type != 1 }
        let calls = boarding.isEmpty ? times : boarding

        var groups: [String: [DTO.Trip]] = [:]
        for call in calls {
            guard let trip = trips[call.trip_id] else { continue }
            groups["\(trip.route_id)/\(trip.direction_id ?? 0)", default: []].append(trip)
        }
        return groups.values
            .compactMap { trips in
                guard let first = trips.first, let route = routes[first.route_id] else { return nil }
                return Self.line(route: route, trips: trips)
            }
            .sorted { a, b in
                a.shortName == b.shortName ? a.id < b.id : a.shortName.localizedStandardCompare(b.shortName) == .orderedAscending
            }
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let version = try await Self.store.version(http)
        let stops = try await Self.store.stops(http)
        var times: [DTO.StopTimeOfTrip] = []
        var line = line
        if let trip = line.providerRefs["tripId"] {
            times = (try? await http.get([DTO.StopTimeOfTrip].self, Self.base, "/gtfs/v0/\(version)/stop_times/trip/\(trip)")) ?? []
        }
        if times.isEmpty {
            // The saved trip belongs to an older dataset; pick a fresh one of the same route,
            // direction and (when known) shape.
            let (route, direction) = try Self.refs(line)
            let trips = try await http.get([DTO.Trip].self, Self.base, "/gtfs/v0/\(version)/trips/route/\(route)")
                .filter { ($0.direction_id ?? 0) == direction }
            let shape = line.providerRefs["shapeId"]
            guard let trip = trips.first(where: { $0.shape_id == shape }) ?? trips.first else {
                throw TransitError.notFound("trips of Föli route \(route) direction \(direction)")
            }
            times = try await http.get([DTO.StopTimeOfTrip].self, Self.base, "/gtfs/v0/\(version)/stop_times/trip/\(trip.trip_id)")
            // The shape drawn has to be this trip's own.
            line.providerRefs["shapeId"] = trip.shape_id
        }
        let patternStops = times
            .sorted { $0.stop_sequence < $1.stop_sequence }
            .compactMap { time -> PatternStop? in
                guard let stop = stops[time.stop_id] else { return nil }
                return PatternStop(stop: stop.stop(id: time.stop_id), sequence: time.stop_sequence,
                                   distanceAlongRoute: time.shape_dist_traveled)
            }
        guard !patternStops.isEmpty else { throw TransitError.notFound("stops of Föli line \(line.id)") }
        return RoutePattern(line: line, stops: patternStops)
    }

    /// The GTFS shape of the trip the pattern was built from (`shapes/{shape_id}`, one point every
    /// ~20 m: 90–240 KB, 23–60 KB gzipped). Variants are separate shapes, so it is the pattern's
    /// own and needs no trimming.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        guard let shape = pattern.line.providerRefs["shapeId"] ?? line.providerRefs["shapeId"] else {
            throw TransitError.notFound("shape of Föli line \(line.id)")
        }
        let version = try await Self.store.version(http)
        let points = try await http.get([DTO.ShapePoint].self, Self.base, "/gtfs/v0/\(version)/shapes/\(shape)")
        return RouteShape(points.map { GeoPoint(lat: $0.lat, lon: $0.lon) }, version: "\(version)/\(shape)")
    }

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let (route, direction) = try Self.refs(line)
        let response = try await http.get(DTO.VehicleMonitoring.self, Self.base, "/siri/vm")
        let now = response.servertime ?? Int(Date().timeIntervalSince1970)
        return (response.result?.vehicles ?? [:]).values
            .filter { $0.__routeref == route && $0.__directionid == String(direction) }
            // A bus parked at its first stop keeps its last record long after it went quiet;
            // `validuntiltime` says when the publisher itself stops vouching for it.
            .filter { ($0.validuntiltime ?? .max) >= now && $0.monitored != false }
            .compactMap { v -> VehiclePosition? in
                guard let lat = v.latitude, let lon = v.longitude else { return nil }
                return VehiclePosition(
                    location: GeoPoint(lat: lat, lon: lon),
                    recordedAt: v.recordedattime.map(Self.date),
                    tripId: v.__tripref,
                    // Föli's fleet number, not a plate — the board only needs a stable identity.
                    plateNumber: v.vehicleref,
                    bearing: v.bearing,
                    aimedDeparture: v.originaimeddeparturetime.map(Self.date)
                )
            }
    }

    /// `/siri/sm/{stop}` lists the next ~20 departures of every line at the stop, live or not.
    /// `monitored` is also true for trips that have not left their first stop yet, whose "expected"
    /// time is just the timetable (and whose coordinates, when present, are of the bus finishing its
    /// previous run elsewhere). So a departure counts as real-time only once its trip has started.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let (route, direction) = try Self.refs(line)
        let response = try await http.get(DTO.StopMonitoring.self, Self.base, "/siri/sm/\(stop.code)")
        // When the SIRI back end is down the reply is `"status":"NO_SIRI_DATA"` with an empty result
        // (documented at data.foli.fi/doc/siri/v0/sm) — an outage, not a stop with no buses due.
        if let status = response.status, status != "OK" {
            throw TransitError.badResponse("Föli stop monitoring status \(status)")
        }
        let now = response.servertime ?? Int(Date().timeIntervalSince1970)
        return (response.result ?? [])
            .filter { $0.__routeref == route && $0.__directionid == String(direction) }
            .compactMap { call -> Arrival? in
                guard let expected = call.expectedarrivaltime ?? call.expecteddeparturetime ?? call.aimedarrivaltime else { return nil }
                let live = call.monitored == true && (call.originaimeddeparturetime ?? .max) <= now
                return Arrival(
                    expectedAt: Self.date(expected),
                    scheduledAt: (call.aimedarrivaltime ?? call.aimeddeparturetime).map(Self.date),
                    isRealtime: live,
                    tripId: call.__tripref,
                    vehicleLocation: live ? call.latitude.flatMap { lat in call.longitude.map { GeoPoint(lat: lat, lon: $0) } } : nil
                )
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// There is no proximity query, so this filters the cached stop list and then asks each of the
    /// nearest stops for its lines (one small request each, capped at 12 stops).
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let stops = try await Self.store.stops(http)
        let near = stops
            .map { $0.value.stop(id: $0.key) }
            .map { ($0, RouteGeometry.meters(point, $0.location)) }
            .filter { $0.1 <= radiusMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(12)
        return try await withThrowingTaskGroup(of: (Int, NearbyStop).self) { group in
            for (index, (stop, distance)) in near.enumerated() {
                group.addTask {
                    (index, NearbyStop(stop: stop, distanceMeters: distance, lines: try await lines(atStop: stop)))
                }
            }
            var results: [(Int, NearbyStop)] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1).filter { !$0.lines.isEmpty }
        }
    }

    // MARK: - Helpers

    private static func line(route: DTO.Route, trips: [DTO.Trip]) -> TransitLine {
        // The most travelled shape through this stop stands for the direction; its commonest
        // headsign names it ("Satama", "Lentoasema").
        let shape = mostCommon(trips.map { $0.shape_id ?? "" })
        let representative = trips.first { ($0.shape_id ?? "") == shape } ?? trips[0]
        let headsign = mostCommon(trips.compactMap(\.trip_headsign).filter { !$0.isEmpty })
        let direction = representative.direction_id ?? 0
        var refs = ["routeId": route.route_id, "direction": String(direction), "tripId": representative.trip_id]
        refs["shapeId"] = representative.shape_id
        return TransitLine(
            id: "\(route.route_id)/\(direction)",
            shortName: route.route_short_name,
            headsign: headsign,
            agency: "Föli",
            origin: nil,
            destination: headsign,
            isAccessible: representative.wheelchair_accessible.flatMap { $0 == 1 ? true : $0 == 2 ? false : nil },
            providerRefs: refs
        )
    }

    private static func refs(_ line: TransitLine) throws -> (route: String, direction: Int) {
        let parts = line.id.split(separator: "/")
        let route = line.providerRefs["routeId"] ?? parts.first.map(String.init)
        let direction = line.providerRefs["direction"].flatMap(Int.init) ?? parts.dropFirst().first.flatMap { Int($0) }
        guard let route, let direction else {
            throw TransitError.unsupported("line \(line.id) is not a Föli route/direction (was it loaded from another provider?)")
        }
        return (route, direction)
    }

    private static func mostCommon(_ values: [String]) -> String? {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fi_FI"))
    }

    /// Live times are Unix epoch seconds.
    private static func date(_ epoch: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(epoch)) }
}

// MARK: - Session cache

/// The static half of the feed, fetched once per session: the dataset name (`/gtfs/v0/`, 0.2 KB),
/// all stops (~225 KB, ~3,600 stops), all trips (~190 KB gzipped, ~12,000 trips) and routes (~4 KB).
/// A failed load is forgotten so the next call retries.
private actor FoliStore {
    private var versionTask: Task<String, any Error>?
    private var stopsTask: Task<[String: DTO.Stop], any Error>?
    private var tripsTask: Task<[String: DTO.Trip], any Error>?
    private var routesTask: Task<[String: DTO.Route], any Error>?

    private static let base = "https://data.foli.fi"

    func version(_ http: HTTPClient) async throws -> String {
        let task = versionTask ?? Task { try await http.get(DTO.Datasets.self, Self.base, "/gtfs/v0/").latest }
        versionTask = task
        do { return try await task.value } catch { versionTask = nil; throw error }
    }

    func stops(_ http: HTTPClient) async throws -> [String: DTO.Stop] {
        let version = try await version(http)
        let task = stopsTask ?? Task { try await http.get([String: DTO.Stop].self, Self.base, "/gtfs/v0/\(version)/stops") }
        stopsTask = task
        do { return try await task.value } catch { stopsTask = nil; throw error }
    }

    func trips(_ http: HTTPClient) async throws -> [String: DTO.Trip] {
        let version = try await version(http)
        let task = tripsTask ?? Task {
            let trips = try await http.get([DTO.Trip].self, Self.base, "/gtfs/v0/\(version)/trips/all")
            return Dictionary(trips.map { ($0.trip_id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        tripsTask = task
        do { return try await task.value } catch { tripsTask = nil; throw error }
    }

    func routes(_ http: HTTPClient) async throws -> [String: DTO.Route] {
        let version = try await version(http)
        let task = routesTask ?? Task {
            let routes = try await http.get([DTO.Route].self, Self.base, "/gtfs/v0/\(version)/routes")
            return Dictionary(routes.map { ($0.route_id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        routesTask = task
        do { return try await task.value } catch { routesTask = nil; throw error }
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct Datasets: Decodable, Sendable { var latest: String }

    struct Stop: Decodable, Sendable {
        var stop_code: String?
        var stop_name: String
        var stop_lat: Double
        var stop_lon: Double

        /// `stop_id` is the key of the stops object and equals the public stop number on the pole.
        func stop(id: String) -> TransitStop {
            TransitStop(code: id, name: stop_name, city: nil, location: GeoPoint(lat: stop_lat, lon: stop_lon))
        }
    }

    struct Route: Decodable, Sendable {
        var route_id: String
        var route_short_name: String
        var route_long_name: String?
    }

    struct Trip: Decodable, Sendable {
        var route_id: String
        var trip_id: String
        var trip_headsign: String?
        var direction_id: Int?
        var shape_id: String?
        var wheelchair_accessible: Int?
    }

    struct StopTimeAtStop: Decodable, Sendable {
        var trip_id: String
        var pickup_type: Int?
    }

    struct StopTimeOfTrip: Decodable, Sendable {
        var stop_id: String
        var stop_sequence: Int
        var shape_dist_traveled: Double?
    }

    struct ShapePoint: Decodable, Sendable {
        var lat: Double
        var lon: Double
    }

    struct VehicleMonitoring: Decodable, Sendable {
        struct Result: Decodable, Sendable { var vehicles: [String: Vehicle]? }
        var servertime: Int?
        var result: Result?
    }

    struct Vehicle: Decodable, Sendable {
        var recordedattime: Int?
        var validuntiltime: Int?
        var monitored: Bool?
        var latitude: Double?
        var longitude: Double?
        var bearing: Double?
        var vehicleref: String?
        var originaimeddeparturetime: Int?
        var __tripref: String?
        var __routeref: String?
        var __directionid: String?
    }

    struct StopMonitoring: Decodable, Sendable {
        /// "OK", or "NO_SIRI_DATA" / "PENDING" when the live feed is not producing.
        var status: String?
        var servertime: Int?
        var result: [Call]?
    }

    struct Call: Decodable, Sendable {
        var monitored: Bool?
        var latitude: Double?
        var longitude: Double?
        var originaimeddeparturetime: Int?
        var aimedarrivaltime: Int?
        var expectedarrivaltime: Int?
        var aimeddeparturetime: Int?
        var expecteddeparturetime: Int?
        var __tripref: String?
        var __routeref: String?
        var __directionid: String?
    }
}
