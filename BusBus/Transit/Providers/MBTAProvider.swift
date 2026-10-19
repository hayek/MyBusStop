import Foundation

/// US, Boston — MBTA V3 API (api-v3.mbta.com), official, JSON:API.
/// Keyless use is capped at 20 requests/minute per IP (`x-ratelimit-*` headers; a free key lifts it
/// to 1000/min), so every method here is a single request and the board's poll — vehicles plus
/// predictions — costs two. Stop ids are the public stop numbers printed on the signs.
/// Licence: MassDOT Developers License Agreement — the app must credit MassDOT as the data provider.
/// Bus only: stops and lines are filtered to `route_type` 3.
nonisolated struct MBTAProvider: TransitProvider {
    let id = "mbta"
    let displayName = "MBTA (Boston)"
    let attribution: String? = "Data provided by MassDOT"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .scheduledArrivals, .nearbyStops, .routeShape,
    ]
    /// Two calls per poll against a 20/min budget that setup screens share.
    let suggestedRefreshInterval: Duration = .seconds(30)

    var http = HTTPClient()

    private let base = "https://api-v3.mbta.com"
    private static let busRouteType = 3
    private static let timeZone = TimeZone(identifier: "America/New_York")!

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        if query.allSatisfy(\.isNumber),
           let direct = try? await http.get(DTO.Document<DTO.Resource>.self, base, "/stops/\(query)",
                                            query: ["fields[stop]": "name,latitude,longitude,municipality,address,on_street,at_street"]),
           let stop = direct.data.stop {
            return [stop]
        }
        // The API has no text search, so names are matched against every bus stop, fetched once.
        let all = try await MBTAStopIndex.shared.stops {
            let response = try await http.get(
                DTO.Document<[DTO.Resource]>.self, base, "/stops",
                query: ["filter[route_type]": String(Self.busRouteType),
                        "fields[stop]": "name,latitude,longitude,municipality,address,on_street,at_street"]
            )
            return response.data.compactMap(\.stop)
        }
        return StopNameSearch.match(query, in: all)
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        try await servingLines(stopIDs: [stop.code])[stop.code] ?? []
    }

    /// `/stops` answers a radius query (in degrees) nearest-first but says nothing about routes, so
    /// the lines come from one `/route_patterns` call covering every stop found: two requests total.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let response = try await http.get(
            DTO.Document<[DTO.Resource]>.self, base, "/stops",
            query: ["filter[latitude]": String(point.lat),
                    "filter[longitude]": String(point.lon),
                    "filter[radius]": String(radiusMeters / 111_320),
                    "filter[route_type]": String(Self.busRouteType),
                    "fields[stop]": "name,latitude,longitude,municipality,address,on_street,at_street",
                    "page[limit]": "15"]
        )
        let stops = response.data.compactMap(\.stop)
        guard !stops.isEmpty else { return [] }
        let lines = try await servingLines(stopIDs: stops.map(\.code))
        return stops
            .compactMap { stop in
                guard let served = lines[stop.code], !served.isEmpty else { return nil }
                return NearbyStop(stop: stop, distanceMeters: RouteGeometry.meters(point, stop.location), lines: served)
            }
            .sorted { $0.distanceMeters < $1.distanceMeters }
    }

    /// A line is one MBTA route pattern (`1-_-0`); its representative trip carries the stop order.
    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        try await pattern(for: line, withShape: false).pattern
    }

    /// The same call with the representative trip's shape included: about half a KB more gzipped
    /// and no request of its own. One trip, so its stops and its shape always belong together.
    /// A trip without a shape gives an empty one, kept so the card does not ask again.
    func routePatternWithShape(for line: TransitLine) async throws -> (pattern: RoutePattern, shape: RouteShape?) {
        try await pattern(for: line, withShape: true)
    }

    /// Only asked for when the pattern was cached without its shape; the same single call.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        guard let shape = try await self.pattern(for: line, withShape: true).shape, !shape.isEmpty else {
            throw TransitError.notFound("shape of route pattern \(line.id)")
        }
        return shape
    }

    private func pattern(for line: TransitLine, withShape: Bool) async throws -> (pattern: RoutePattern, shape: RouteShape?) {
        var query = ["include": "representative_trip.stops",
                     "fields[route_pattern]": "direction_id",
                     "fields[trip]": "headsign,stops",
                     "fields[stop]": "name,latitude,longitude,municipality,address,on_street,at_street"]
        if withShape {
            query["include"] = "representative_trip.stops,representative_trip.shape"
            query["fields[trip]"] = "headsign,stops,shape"
            query["fields[shape]"] = "polyline"
        }
        let response = try await http.get(DTO.Document<DTO.Resource>.self, base, "/route_patterns/\(line.id)", query: query)
        let included = DTO.index(response.included)
        guard let tripID = response.data.relationships?["representative_trip"]?.ids.first,
              let trip = included["trip:\(tripID)"],
              let stopIDs = trip.relationships?["stops"]?.ids, !stopIDs.isEmpty else {
            throw TransitError.notFound("stops for route pattern \(line.id)")
        }
        let stops = stopIDs.compactMap { included["stop:\($0)"]?.stop }
        let pattern = RoutePattern(
            line: line,
            stops: stops.enumerated().map { PatternStop(stop: $1, sequence: $0 + 1, distanceAlongRoute: nil) }
        )
        // GTFS shape ids (`010154`) change with each rating, so the id is the shape's version.
        let shapeID = trip.relationships?["shape"]?.ids.first
        guard withShape else { return (pattern, nil) }
        let points = shapeID
            .flatMap { included["shape:\($0)"]?.attributes?.polyline }
            .flatMap { try? Polyline.decode($0, precision: 5) }
        return (pattern, RouteShape(points ?? [], version: shapeID))
    }

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let ref = Ref(line)
        let response = try await http.get(
            DTO.Document<[DTO.Resource]>.self, base, "/vehicles",
            query: ["filter[route]": ref.route, "filter[direction_id]": ref.direction,
                    "fields[vehicle]": "latitude,longitude,bearing,speed,updated_at,label"]
        )
        return response.data.compactMap { vehicle in
            guard let a = vehicle.attributes, let lat = a.latitude, let lon = a.longitude else { return nil }
            return VehiclePosition(
                location: GeoPoint(lat: lat, lon: lon),
                recordedAt: a.updatedAt.flatMap(DTO.parseDate),
                tripId: vehicle.relationships?["trip"]?.ids.first,
                plateNumber: a.label,
                bearing: a.bearing,
                speedKmh: a.speed.map { $0 * 3.6 }   // metres per second on the wire
            )
        }
    }

    /// Predictions carry their timetable slot via `include=schedule`. When there are none (late at
    /// night, or a route without live data) one more call falls back to the timetable itself.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let ref = Ref(line)
        let response = try await http.get(
            DTO.Document<[DTO.Resource]>.self, base, "/predictions",
            query: ["filter[stop]": stop.code, "filter[route]": ref.route, "filter[direction_id]": ref.direction,
                    "include": "schedule,vehicle",
                    "fields[prediction]": "arrival_time,departure_time,schedule_relationship",
                    "fields[schedule]": "arrival_time,departure_time",
                    "fields[vehicle]": "latitude,longitude"]
        )
        let included = DTO.index(response.included)
        let predicted = response.data.compactMap { prediction -> (Arrival, boardable: Bool)? in
            guard let a = prediction.attributes, !["CANCELLED", "SKIPPED"].contains(a.scheduleRelationship ?? ""),
                  let expected = a.time else { return nil }
            let schedule = prediction.relationships?["schedule"]?.ids.first.flatMap { included["schedule:\($0)"] }
            let vehicle = prediction.relationships?["vehicle"]?.ids.first.flatMap { included["vehicle:\($0)"] }
            return (Arrival(
                expectedAt: expected,
                scheduledAt: schedule?.attributes?.time,
                isRealtime: true,
                tripId: prediction.relationships?["trip"]?.ids.first,
                vehicleLocation: vehicle?.attributes.flatMap { a in
                    a.latitude.flatMap { lat in a.longitude.map { GeoPoint(lat: lat, lon: $0) } }
                }
            ), a.departureTime != nil)
        }
        if !predicted.isEmpty { return Self.boarding(predicted) }
        return try await scheduled(ref, at: stop)
    }

    /// MBTA gives a departure time only where riders can board, so a visit with none is a trip
    /// that ends here (a short-turn) or sets down only. The official app hides those on a stop's
    /// board; they are kept only when nothing else calls, which is a terminus board.
    private static func boarding(_ visits: [(Arrival, boardable: Bool)]) -> [Arrival] {
        let boardable = visits.filter(\.boardable)
        return (boardable.isEmpty ? visits : boardable).map(\.0).sorted { $0.expectedAt < $1.expectedAt }
    }

    // MARK: - Helpers

    private func scheduled(_ ref: Ref, at stop: TransitStop) async throws -> [Arrival] {
        let day = ServiceDay(now: Date(), timeZone: Self.timeZone)
        let response = try await http.get(
            DTO.Document<[DTO.Resource]>.self, base, "/schedules",
            query: ["filter[stop]": stop.code, "filter[route]": ref.route, "filter[direction_id]": ref.direction,
                    "filter[date]": day.date, "filter[min_time]": day.minTime,
                    "fields[schedule]": "arrival_time,departure_time",
                    "sort": "departure_time", "page[limit]": "10"]
        )
        return Self.boarding(response.data.compactMap { schedule -> (Arrival, boardable: Bool)? in
            guard let a = schedule.attributes, let time = a.time else { return nil }
            return (Arrival(expectedAt: time, scheduledAt: time, isRealtime: false,
                            tripId: schedule.relationships?["trip"]?.ids.first), a.departureTime != nil)
        })
    }

    /// Bus lines per direction at each of the given stops, from a single `/route_patterns` call.
    /// Each (route, direction) keeps its most typical pattern that actually stops there; patterns
    /// that only *end* at the stop are dropped unless nothing else serves it (a terminus).
    private func servingLines(stopIDs: [String]) async throws -> [String: [TransitLine]] {
        let response = try await http.get(
            DTO.Document<[DTO.Resource]>.self, base, "/route_patterns",
            query: ["filter[stop]": stopIDs.joined(separator: ","),
                    "include": "route,representative_trip.stops",
                    "fields[route_pattern]": "direction_id,typicality,sort_order",
                    "fields[route]": "short_name,long_name,type",
                    "fields[trip]": "headsign,stops",
                    "fields[stop]": "name"]
        )
        let included = DTO.index(response.included)

        nonisolated struct Candidate { var pattern: DTO.Resource; var line: TransitLine; var stopIDs: [String] }
        let candidates: [Candidate] = response.data.compactMap { pattern in
            guard let a = pattern.attributes, let direction = a.directionId, (a.typicality ?? 1) < 5,
                  let routeID = pattern.relationships?["route"]?.ids.first,
                  let route = included["route:\(routeID)"]?.attributes, route.routeType == Self.busRouteType,
                  let tripID = pattern.relationships?["representative_trip"]?.ids.first,
                  let trip = included["trip:\(tripID)"] else { return nil }
            let tripStops = trip.relationships?["stops"]?.ids ?? []
            let names = tripStops.map { included["stop:\($0)"]?.attributes?.name }
            let short = [route.shortName, route.longName].compactMap { $0 }.first { !$0.isEmpty } ?? routeID
            let line = TransitLine(
                id: pattern.id,
                shortName: short,
                headsign: trip.attributes?.headsign,
                agency: "MBTA",
                origin: names.first ?? nil,
                destination: names.last ?? nil,
                providerRefs: ["route": routeID, "direction": String(direction), "trip": tripID]
            )
            return Candidate(pattern: pattern, line: line, stopIDs: tripStops)
        }

        var result: [String: [TransitLine]] = [:]
        for stopID in stopIDs {
            let serving = candidates.filter { $0.stopIDs.contains(stopID) }
            let boarding = serving.filter { $0.stopIDs.last != stopID || $0.stopIDs.dropLast().contains(stopID) }
            var best: [String: Candidate] = [:]
            for candidate in (boarding.isEmpty ? serving : boarding) {
                let key = "\(candidate.line.providerRefs["route"] ?? "")|\(candidate.line.providerRefs["direction"] ?? "")"
                if let current = best[key], Self.rank(current.pattern) <= Self.rank(candidate.pattern) { continue }
                best[key] = candidate
            }
            result[stopID] = best.values.sorted { Self.rank($0.pattern) < Self.rank($1.pattern) }.map(\.line)
        }
        return result
    }

    /// Most typical first, then MBTA's own ordering (which follows route number).
    private static func rank(_ pattern: DTO.Resource) -> Rank {
        Rank(typicality: pattern.attributes?.typicality ?? 9, sortOrder: pattern.attributes?.sortOrder ?? .max)
    }

    private nonisolated struct Rank: Comparable {
        var typicality: Int
        var sortOrder: Int
        static func < (a: Rank, b: Rank) -> Bool { (a.typicality, a.sortOrder) < (b.typicality, b.sortOrder) }
    }

    /// Route and direction to filter live data by. Pattern ids are `{route}-{variant}-{direction}`,
    /// which is the fallback for a line cached before `providerRefs` were filled.
    private nonisolated struct Ref {
        var route: String
        var direction: String

        init(_ line: TransitLine) {
            let parts = line.id.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            route = line.providerRefs["route"] ?? parts.dropLast(2).joined(separator: "-")
            direction = line.providerRefs["direction"] ?? parts.last ?? "0"
        }
    }

    /// MBTA's service day runs past midnight; `/schedules` wants the service date and a time of day
    /// counted from its start ("25:10"), in Boston time.
    private nonisolated struct ServiceDay {
        var date: String
        var minTime: String

        init(now: Date, timeZone: TimeZone) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.hour, .minute], from: now)
            let rollover = (parts.hour ?? 0) < 3
            let day = rollover ? calendar.date(byAdding: .day, value: -1, to: now) ?? now : now
            let ymd = calendar.dateComponents([.year, .month, .day], from: day)
            date = String(format: "%04d-%02d-%02d", ymd.year ?? 0, ymd.month ?? 0, ymd.day ?? 0)
            minTime = String(format: "%02d:%02d", (parts.hour ?? 0) + (rollover ? 24 : 0), parts.minute ?? 0)
        }
    }
}

/// Every MBTA bus stop (~6,900; ~255 KB gzipped, 2.3 MB of JSON), fetched once per session for
/// name search. A failed load is forgotten so the next search retries.
private actor MBTAStopIndex {
    static let shared = MBTAStopIndex()
    private var task: Task<[TransitStop], any Error>?

    func stops(load: @escaping @Sendable () async throws -> [TransitStop]) async throws -> [TransitStop] {
        if let task { return try await task.value }
        let task = Task { try await load() }
        self.task = task
        do { return try await task.value } catch { self.task = nil; throw error }
    }
}

/// Case- and accent-insensitive "every word appears in the name", exact and prefix matches first.
private nonisolated enum StopNameSearch {
    static func match(_ query: String, in stops: [TransitStop], limit: Int = 40) -> [TransitStop] {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let needle = fold(query)
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

// MARK: - Wire format (JSON:API)

private nonisolated enum DTO {
    struct Document<T: Decodable & Sendable>: Decodable, Sendable {
        var data: T
        var included: [Resource]?
    }

    struct Resource: Decodable, Sendable {
        var id: String
        var type: String
        var attributes: Attributes?
        var relationships: [String: Relationship]?

        var stop: TransitStop? {
            guard type == "stop", let a = attributes, let lat = a.latitude, let lon = a.longitude else { return nil }
            // A station has a postal address; a pole has the street it stands on and the one it
            // is at.
            let address = TransitStop.address([a.address]) ?? TransitStop.address([a.onStreet, a.atStreet], separator: " & ")
            return TransitStop(code: id, name: a.name ?? id, city: a.municipality, location: GeoPoint(lat: lat, lon: lon),
                               address: address)
        }
    }

    /// `data` is an object, an array or null depending on the relationship; all become a list of ids.
    struct Relationship: Decodable, Sendable {
        struct Linkage: Decodable, Sendable { var id: String }
        enum CodingKeys: String, CodingKey { case data }
        var ids: [String]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if try !container.contains(.data) || container.decodeNil(forKey: .data) {
                ids = []
            } else if let one = try? container.decode(Linkage.self, forKey: .data) {
                ids = [one.id]
            } else {
                ids = try container.decode([Linkage].self, forKey: .data).map(\.id)
            }
        }
    }

    /// The union of the attributes read from every resource type requested (sparse fieldsets keep
    /// each one small).
    struct Attributes: Decodable, Sendable {
        var name: String?
        var latitude: Double?
        var longitude: Double?
        var municipality: String?
        var address: String?
        var onStreet: String?
        var atStreet: String?
        var directionId: Int?
        var typicality: Int?
        var sortOrder: Int?
        var headsign: String?
        var shortName: String?
        var longName: String?
        var routeType: Int?
        var bearing: Double?
        var speed: Double?
        var updatedAt: String?
        var label: String?
        var arrivalTime: String?
        var departureTime: String?
        var scheduleRelationship: String?
        /// A shape's geometry: a Google encoded polyline, precision 5.
        var polyline: String?

        enum CodingKeys: String, CodingKey {
            case name, latitude, longitude, municipality, typicality, headsign, bearing, speed, label, address, polyline
            case onStreet = "on_street", atStreet = "at_street"
            case directionId = "direction_id", sortOrder = "sort_order", shortName = "short_name"
            case longName = "long_name", routeType = "type", updatedAt = "updated_at"
            case arrivalTime = "arrival_time", departureTime = "departure_time"
            case scheduleRelationship = "schedule_relationship"
        }

        /// Arrival, or departure at a trip's first stop (where arrival is null).
        var time: Date? { (arrivalTime ?? departureTime).flatMap(DTO.parseDate) }
    }

    /// `included` keyed by "type:id".
    static func index(_ resources: [Resource]?) -> [String: Resource] {
        Dictionary((resources ?? []).map { ("\($0.type):\($0.id)", $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// ISO 8601 with the Boston offset: "2026-09-22T05:37:00-04:00".
    static func parseDate(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }
}
