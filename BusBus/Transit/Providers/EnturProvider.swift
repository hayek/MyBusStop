import Foundation

/// Norway — Entur, the national journey planner (every operator: Skyss, AtB, Kolumbus, Ruter, …).
/// Keyless and documented (developer.entur.no), NLOD licence. Journey Planner v3 and Vehicles v2 are
/// GraphQL over POST; stop search is the Pelias-style geocoder. Every call carries `ET-Client-Name`:
/// unidentified clients are strictly rate-limited and may be blocked. No quota is published for
/// identified clients. See docs/research/worldwide-apis.md §5.1.
///
/// A stop is a *stop place* (what riders search for and what the geocoder returns), normalised to
/// its multimodal parent when it has one. A stop place holds several quays (one per kerb/direction),
/// so direction lives on the line instead: one `TransitLine` per line + journey-pattern direction
/// that actually calls at one of the stop's quays. That keeps the board one stop with many lines,
/// while arrivals and vehicles are filtered to the rider's direction.
///
/// Ruter (Oslo/Akershus) does not feed vehicle positions to Entur, so Oslo lines have arrivals only.
nonisolated struct EnturProvider: TransitProvider {
    let id = "entur"
    let displayName = "Entur (Norway)"
    let attribution: String? = "Data: Entur (NLOD), including data from Norwegian public transport operators"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .scheduledArrivals, .nearbyStops, .routeShape,
    ]
    let suggestedRefreshInterval: Duration = .seconds(20)

    var client = EnturClient()

    private static let geocoder = "https://api.entur.io/geocoder/v1/autocomplete"
    private static let journeyPlanner = URL(string: "https://api.entur.io/journey-planner/v3/graphql")!
    private static let vehiclesAPI = URL(string: "https://api.entur.io/realtime/v2/vehicles/graphql")!
    /// Oslo time — service dates and every timetable in the feed are Norwegian.
    static let timeZone = TimeZone(identifier: "Europe/Oslo")!
    private static let busModes: Set<String> = ["bus"]

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        // No public stop numbers in Norway (quays only have kerb letters), so name search only.
        // `layers=venue` returns stop places *and* POIs; only `NSR:StopPlace` ids are stops.
        let response = try await client.get(DTO.Geocoder.self, Self.geocoder, query: [
            "text": query, "layers": "venue", "size": "20", "lang": "no",
        ])
        return response.features.compactMap { feature -> TransitStop? in
            let p = feature.properties
            guard p.id.hasPrefix("NSR:StopPlace:"), feature.geometry.coordinates.count == 2 else { return nil }
            if let categories = p.category, !categories.contains(where: DTO.busCategories.contains) { return nil }
            return TransitStop(code: p.id, name: p.name, city: p.locality,
                               location: GeoPoint(lat: feature.geometry.coordinates[1], lon: feature.geometry.coordinates[0]))
        }
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let query = """
        { stopPlace(id: \(gql(stop.code))) { id \(Self.linesFields(soon: 300)) } }
        """
        let data = try await client.graphQL(DTO.StopPlaceData.self, Self.journeyPlanner, query)
        guard let place = data.stopPlace else { throw TransitError.notFound("stop place \(stop.code)") }
        var groups = Self.groups(of: place)
        let quiet = Set(groups.values.filter { $0.headsigns.isEmpty }.map(\.line.id))
        Self.count(try await lookAhead(at: stop.code, lines: quiet.sorted()), into: &groups)
        return Self.lines(of: groups, stopCode: stop.code)
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        try await chosenPattern(for: line).pattern
    }

    /// Every journey pattern carries its own path (`pointsOnLink`) in the line query the pattern
    /// already comes from, so the shape costs no request of its own. A pattern without one gives
    /// an empty shape, kept so the card does not ask again.
    func routePatternWithShape(for line: TransitLine) async throws -> (pattern: RoutePattern, shape: RouteShape?) {
        let (pattern, chosen) = try await chosenPattern(for: line)
        return (pattern, Self.shape(of: chosen, ref: try LineRef(line)) ?? RouteShape(branches: []))
    }

    /// Only asked when the pattern was cached without its shape; the line query is kept in memory
    /// for the day, so this is that one query at most.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        let (_, chosen) = try await chosenPattern(for: line)
        guard let shape = Self.shape(of: chosen, ref: try LineRef(line)) else {
            throw TransitError.notFound("shape of journey pattern \(chosen.id)")
        }
        return shape
    }

    /// The pattern's polyline, with each stop placed at its quay: the stop list shows the
    /// multimodal parent, whose centre can stand 75 m off the road at a big interchange (Oslo).
    private static func shape(of pattern: DTO.LinePattern, ref: LineRef) -> RouteShape? {
        guard let encoded = pattern.pointsOnLink?.points, let points = try? Polyline.decode(encoded),
              points.count >= 2 else { return nil }
        var positions: [String: GeoPoint] = [:]
        for quay in pattern.quays {
            guard let lat = quay.latitude, let lon = quay.longitude else { continue }
            let code = quay.stop(preferring: ref.stop).code
            if positions[code] == nil { positions[code] = GeoPoint(lat: lat, lon: lon) }
        }
        return RouteShape(points, stopPositions: positions, version: pattern.id)
    }

    private func chosenPattern(for line: TransitLine) async throws -> (pattern: RoutePattern, chosen: DTO.LinePattern) {
        let ref = try LineRef(line)
        let patterns = try await linePatterns(ref.line)
        let group = patterns.filter { $0.directionKey == ref.direction }
        // Several variants share a direction (short turns, depot runs, school trips). Draw the one
        // that runs most today among those calling at the rider's stop — so the stop is on it.
        let calling = group.filter { $0.quays.contains { $0.isIn(stopPlace: ref.stop) } }
        guard let chosen = (calling.isEmpty ? group : calling).max(by: {
            ($0.serviceJourneysForDate?.count ?? 0, $0.quays.count) < ($1.serviceJourneysForDate?.count ?? 0, $1.quays.count)
        }) else {
            throw TransitError.notFound("journey pattern for \(line.id)")
        }
        var stops: [PatternStop] = []
        for quay in chosen.quays {
            let stop = quay.stop(preferring: ref.stop)
            // Two kerbs of the same stop place back to back would be one stop to a rider.
            if stops.last?.stop.code == stop.code { continue }
            stops.append(PatternStop(stop: stop, sequence: stops.count + 1, distanceAlongRoute: nil))
        }
        return (RoutePattern(line: line, stops: stops), chosen)
    }

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let ref = try LineRef(line)
        // Without maxDataAge the feed also returns vehicles last heard from up to an hour ago.
        let query = """
        { vehicles(lineRef: \(gql(ref.line)), maxDataAge: "PT2M") {
            vehicleId direction destinationRef destinationName lastUpdatedEpochSecond bearing
            serviceJourney { id } location { latitude longitude } monitoredCall { stopPointRef } } }
        """
        let data = try await client.graphQL(DTO.VehiclesData.self, Self.vehiclesAPI, query)
        let vehicles = data.vehicles ?? []
        guard !vehicles.isEmpty else { return [] }

        // The vehicle feed has no journey-pattern id. Some operators (AtB) send a direction that
        // matches the pattern's directionType; others (Skyss) send none, so the vehicle's
        // destination quay is matched against the terminals of this direction's patterns instead.
        let patterns = try await linePatterns(ref.line)
        let mine = patterns.filter { $0.directionKey == ref.direction }
        let others = patterns.filter { $0.directionKey != ref.direction }
        let myTerminals = Set(mine.flatMap(\.terminalRefs))
        let otherTerminals = Set(others.flatMap(\.terminalRefs))
        let myQuays = Set(mine.flatMap { $0.quays.map(\.id) })
        let otherQuays = Set(others.flatMap { $0.quays.map(\.id) })

        return vehicles.compactMap { v -> VehiclePosition? in
            guard let location = v.location, let lat = location.latitude, let lon = location.longitude else { return nil }
            let belongs: Bool
            if let direction = v.direction?.lowercased(), DTO.namedDirections.contains(ref.direction) {
                belongs = direction == ref.direction
            } else if let headsign = ref.headsign, v.destinationName == headsign {
                belongs = true
            } else if let destination = v.destinationRef, myTerminals.contains(destination) {
                if otherTerminals.contains(destination) {
                    // Both directions end there (a loop): fall back to where the bus is calling now.
                    guard let current = v.monitoredCall?.stopPointRef else { return nil }
                    belongs = myQuays.contains(current) && !otherQuays.contains(current)
                } else {
                    belongs = true
                }
            } else {
                belongs = false
            }
            guard belongs else { return nil }
            return VehiclePosition(
                location: GeoPoint(lat: lat, lon: lon),
                recordedAt: v.lastUpdatedEpochSecond.map { Date(timeIntervalSince1970: $0) },
                tripId: v.serviceJourney?.id,
                bearing: v.bearing
            )
        }
    }

    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let ref = try LineRef(line)
        let query = """
        { stopPlace(id: \(gql(stop.code))) {
            estimatedCalls(numberOfDepartures: 30, timeRange: 86400, filters: [{ select: [{ lines: [\(gql(ref.line))] }] }]) {
              realtime aimedArrivalTime expectedArrivalTime aimedDepartureTime expectedDepartureTime
              destinationDisplay { frontText } serviceJourney { id journeyPattern { id directionType } } } } }
        """
        let data = try await client.graphQL(DTO.CallsData.self, Self.journeyPlanner, query)
        guard let calls = data.stopPlace?.estimatedCalls else { throw TransitError.notFound("stop place \(stop.code)") }
        return calls
            .filter { call in
                guard let pattern = call.serviceJourney?.journeyPattern else { return false }
                if let headsign = ref.headsign {
                    return !DTO.namedDirections.contains(DTO.directionKey(pattern))
                        && call.destinationDisplay?.frontText == headsign
                }
                return DTO.directionKey(pattern) == ref.direction
            }
            .compactMap { call -> Arrival? in
                guard let expected = (call.expectedArrivalTime ?? call.expectedDepartureTime).flatMap(DTO.parseDate) else { return nil }
                return Arrival(
                    expectedAt: expected,
                    scheduledAt: (call.aimedArrivalTime ?? call.aimedDepartureTime).flatMap(DTO.parseDate),
                    isRealtime: call.realtime ?? false,
                    tripId: call.serviceJourney?.id
                )
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// `nearest` with `multiModalMode: parent` returns the same stop place ids the geocoder does, and
    /// the lines ride along in the same request (one call, no per-stop fan-out; ~160 KB for ten
    /// stops in central Bergen).
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let query = """
        { nearest(latitude: \(point.lat), longitude: \(point.lon), maximumDistance: \(Int(radiusMeters)), maximumResults: 10,
                  filterByPlaceTypes: [stopPlace], filterByModes: [bus], filterByInUse: true, multiModalMode: parent) {
            edges { node { distance place { ... on StopPlace { id name latitude longitude \(Self.linesFields(soon: 120)) } } } } } }
        """
        let data = try await client.graphQL(DTO.NearestData.self, Self.journeyPlanner, query)
        return (data.nearest?.edges ?? [])
            .compactMap { edge -> NearbyStop? in
                guard let place = edge.node?.place, let id = place.id, let lat = place.latitude, let lon = place.longitude else { return nil }
                let stop = TransitStop(code: id, name: place.name ?? id, city: nil, location: GeoPoint(lat: lat, lon: lon))
                // No week-ahead look per stop here: the list is about what runs now.
                let lines = Self.lines(of: Self.groups(of: place), stopCode: id)
                guard !lines.isEmpty else { return nil }
                return NearbyStop(stop: stop, distanceMeters: edge.node?.distance ?? RouteGeometry.meters(point, stop.location), lines: lines)
            }
            .sorted { $0.distanceMeters < $1.distanceMeters }
    }

    // MARK: - Lines

    /// The journey patterns calling at each quay are the complete, static list of what stops here;
    /// the next day's departures (`soon`) say which of them a rider can actually *board* here and
    /// under which headsign. ~160 KB at Bergen busstasjon (the largest), ~60 KB at a city-centre stop.
    private static let callFields = "destinationDisplay { frontText } serviceJourney { journeyPattern { id directionType line { id } } }"

    private static func linesFields(soon: Int) -> String {
        """
        quays(filterByInUse: true) { journeyPatterns { id directionType
          line { id publicCode transportMode authority { name } } } }
        soon: estimatedCalls(numberOfDepartures: \(soon), timeRange: 86400) { \(callFields) }
        """
    }

    /// Directions with no departure in the next day are either ones that end here (nothing to
    /// board) or ones that run on other days (night and weekend lines). One look a week ahead per
    /// line tells them apart; OTP's own one-per-line departure query gives up after a few hours, so
    /// each line gets its own aliased `estimatedCalls`.
    private func lookAhead(at stopCode: String, lines lineIDs: [String]) async throws -> [DTO.StopPlace.Call] {
        guard !lineIDs.isEmpty else { return [] }
        let aliases = lineIDs.prefix(60).enumerated().map { index, line in
            "l\(index): estimatedCalls(numberOfDepartures: 10, timeRange: 604800, filters: [{ select: [{ lines: [\(gql(line))] }] }]) { \(Self.callFields) }"
        }
        let query = "{ stopPlace(id: \(gql(stopCode))) { \(aliases.joined(separator: "\n")) } }"
        let data = try await client.graphQL(DTO.AliasedCallsData.self, Self.journeyPlanner, query)
        return data.stopPlace?.values.flatMap { $0 } ?? []
    }

    private struct LineGroup {
        var line: DTO.LineInfo
        var direction: String
        var headsigns: [String: Int] = [:]
    }

    /// One group per line + direction among the bus patterns at the stop, with the headsigns of
    /// the departures seen so far.
    private static func groups(of place: DTO.StopPlace) -> [String: LineGroup] {
        var groups: [String: LineGroup] = [:]
        for pattern in (place.quays ?? []).flatMap({ $0.journeyPatterns ?? [] }) {
            guard let line = pattern.line, busModes.contains(line.transportMode ?? "") else { continue }
            let direction = DTO.directionKey(pattern)
            groups["\(line.id)#\(direction)"] = groups["\(line.id)#\(direction)"] ?? LineGroup(line: line, direction: direction)
        }
        count(place.soon ?? [], into: &groups)
        return groups
    }

    private static func count(_ calls: [DTO.StopPlace.Call], into groups: inout [String: LineGroup]) {
        for call in calls {
            guard let pattern = call.serviceJourney?.journeyPattern, let line = pattern.line?.id,
                  let text = call.destinationDisplay?.frontText else { continue }
            groups["\(line)#\(DTO.directionKey(pattern))"]?.headsigns[text, default: 0] += 1
        }
    }

    /// Only groups with a departure become lines: that drops the directions that end here.
    private static func lines(of groups: [String: LineGroup], stopCode: String) -> [TransitLine] {
        var lines: [String: (line: TransitLine, trips: Int)] = [:]
        for (key, group) in groups {
            guard let (headsign, _) = group.headsigns.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { continue }
            let trips = group.headsigns.values.reduce(0, +)
            var refs = ["line": group.line.id, "direction": group.direction, "stop": stopCode]
            // A pattern with no direction stands alone. Operators that leave direction out (the
            // airport coaches) publish one such pattern per variant, so they are told apart — and
            // merged back into one line — by headsign.
            var dedupe = key
            if !DTO.namedDirections.contains(group.direction) {
                refs["headsign"] = headsign
                dedupe = "\(group.line.id)#to:\(headsign)"
                if let existing = lines[dedupe], existing.trips >= trips { continue }
            }
            lines[dedupe] = (TransitLine(
                id: "\(key)#\(stopCode)",
                shortName: group.line.publicCode ?? group.line.id,
                headsign: headsign,
                agency: group.line.authority?.name,
                destination: headsign,
                providerRefs: refs
            ), trips)
        }
        return lines.values.map(\.line).sorted {
            let order = $0.shortName.localizedStandardCompare($1.shortName)
            return order == .orderedSame ? ($0.headsign ?? "") < ($1.headsign ?? "") : order == .orderedAscending
        }
    }

    /// Every journey pattern of a line with its quays, today's journeys and its path (~40 KB for a
    /// trunk line; the paths add 2–5 KB gzipped), kept in memory for the session: routePattern and
    /// every vehicles poll need it.
    private func linePatterns(_ lineID: String) async throws -> [DTO.LinePattern] {
        let date = DTO.serviceDate(Date())
        return try await PatternCache.shared.value(key: "\(lineID)@\(date)") {
            let query = """
            { line(id: \(gql(lineID))) { journeyPatterns { id directionType pointsOnLink { points }
                serviceJourneysForDate(date: "\(date)") { id }
                quays { id name latitude longitude
                  stopPlace { id name latitude longitude parent { id name latitude longitude } } } } } }
            """
            let data = try await client.graphQL(DTO.LineData.self, Self.journeyPlanner, query)
            guard let patterns = data.line?.journeyPatterns else { throw TransitError.notFound("line \(lineID)") }
            return patterns
        }
    }
}

// MARK: - Call-back info

/// What a `TransitLine` from this provider carries: the Entur line, the direction key and the stop
/// place it was listed at. The stop is part of the line id so a cached route pattern is always the
/// variant that calls at that stop.
private nonisolated struct LineRef {
    var line: String
    var direction: String
    var stop: String
    /// Only for a pattern with no direction: its destination display.
    var headsign: String?

    init(_ transitLine: TransitLine) throws {
        guard let line = transitLine.providerRefs["line"], let direction = transitLine.providerRefs["direction"],
              let stop = transitLine.providerRefs["stop"] else {
            throw TransitError.unsupported("line \(transitLine.id) has no Entur refs (was it loaded from another provider?)")
        }
        self.line = line
        self.direction = direction
        self.stop = stop
        self.headsign = transitLine.providerRefs["headsign"]
    }
}

/// A GraphQL string literal. JSON string escaping is a subset of GraphQL's.
private nonisolated func gql(_ value: String) -> String {
    (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "\"\""
}

private actor PatternCache {
    static let shared = PatternCache()
    private var entries: [String: [DTO.LinePattern]] = [:]

    func value(key: String, fetch: @Sendable () async throws -> [DTO.LinePattern]) async throws -> [DTO.LinePattern] {
        if let hit = entries[key] { return hit }
        let fresh = try await fetch()
        entries[key] = fresh
        return fresh
    }
}

// MARK: - HTTP

/// GET/POST with Entur's identification header, which `HTTPClient` has no way to send.
nonisolated struct EnturClient: Sendable {
    var session: URLSession = .shared
    var timeout: TimeInterval = 30
    static let clientName = "hayek-busbus"

    func get<T: Decodable>(_ type: T.Type, _ url: String, query: [String: String]) async throws -> T {
        guard var components = URLComponents(string: url) else { throw TransitError.badResponse("invalid URL \(url)") }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let full = components.url else { throw TransitError.badResponse("invalid URL \(url)") }
        return try await send(type, URLRequest(url: full, timeoutInterval: timeout))
    }

    func graphQL<T: Decodable>(_ type: T.Type, _ url: URL, _ query: String) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["query": query])
        let (response, raw) = try await exchange(GraphQLResponse<T>.self, request)
        if let data = response.data { return data }
        throw ResponseError("GraphQL: \(response.errors?.compactMap(\.message).joined(separator: "; ") ?? "no data")",
                            raw.data, raw.response, raw.request)
    }

    private func send<T: Decodable>(_ type: T.Type, _ request: URLRequest) async throws -> T {
        try await exchange(type, request).value
    }

    /// The decoded reply, and the raw one it came from for errors found after decoding.
    private func exchange<T: Decodable>(_ type: T.Type, _ request: URLRequest) async throws
        -> (value: T, raw: (data: Data, response: URLResponse, request: URLRequest)) {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.clientName, forHTTPHeaderField: "ET-Client-Name")
        request.setValue("BusBus-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let path = request.url?.path ?? "?"
        try HTTPClient.check(data, response, request, path)
        return (try HTTPClient.decode(T.self, data, response, request, path), (data, response, request))
    }
}

private nonisolated struct GraphQLResponse<T: Decodable>: Decodable {
    struct Failure: Decodable { var message: String? }
    var data: T?
    var errors: [Failure]?
}

// MARK: - Wire format

private nonisolated enum DTO {
    static let busCategories: Set<String> = ["onstreetBus", "busStation", "coachStation"]
    /// Directions that mean the same thing on every pattern of a line. Anything else ("unknown",
    /// missing) cannot be paired with other patterns, so such a pattern is its own direction.
    static let namedDirections: Set<String> = ["inbound", "outbound", "clockwise", "anticlockwise"]

    static func directionKey(_ pattern: some DirectedPattern) -> String {
        let type = pattern.directionType?.lowercased() ?? ""
        return namedDirections.contains(type) ? type : pattern.id
    }

    // Geocoder

    struct Geocoder: Decodable, Sendable {
        struct Feature: Decodable, Sendable {
            struct Geometry: Decodable, Sendable { var coordinates: [Double] }
            struct Properties: Decodable, Sendable {
                var id: String
                var name: String
                var locality: String?
                var category: [String]?
            }
            var geometry: Geometry
            var properties: Properties
        }
        var features: [Feature]
    }

    // Stop place with its lines

    struct StopPlaceData: Decodable, Sendable { var stopPlace: StopPlace? }

    struct NearestData: Decodable, Sendable {
        struct Connection: Decodable, Sendable { var edges: [Edge]? }
        struct Edge: Decodable, Sendable { var node: Node? }
        struct Node: Decodable, Sendable { var distance: Double?; var place: StopPlace? }
        var nearest: Connection?
    }

    struct StopPlace: Decodable, Sendable {
        struct Quay: Decodable, Sendable { var journeyPatterns: [StopPattern]? }
        struct Call: Decodable, Sendable {
            struct Display: Decodable, Sendable { var frontText: String? }
            struct Journey: Decodable, Sendable { var journeyPattern: StopPattern? }
            var destinationDisplay: Display?
            var serviceJourney: Journey?
        }
        var id: String?
        var name: String?
        var latitude: Double?
        var longitude: Double?
        var quays: [Quay]?
        var soon: [Call]?
    }

    /// `{ stopPlace: { l0: [calls], l1: [calls], … } }`
    struct AliasedCallsData: Decodable, Sendable { var stopPlace: [String: [StopPlace.Call]]? }

    struct LineInfo: Decodable, Sendable {
        struct Authority: Decodable, Sendable { var name: String? }
        var id: String
        var publicCode: String?
        var transportMode: String?
        var authority: Authority?
    }

    struct StopPattern: Decodable, Sendable, DirectedPattern {
        var id: String
        var directionType: String?
        var line: LineInfo?
    }

    // Line with its patterns

    struct LineData: Decodable, Sendable {
        struct Line: Decodable, Sendable { var journeyPatterns: [LinePattern]? }
        var line: Line?
    }

    struct Place: Decodable, Sendable {
        var id: String
        var name: String?
        var latitude: Double?
        var longitude: Double?
    }

    struct PatternStopPlace: Decodable, Sendable {
        var id: String
        var name: String?
        var latitude: Double?
        var longitude: Double?
        var parent: Place?
    }

    struct Quay: Decodable, Sendable {
        var id: String
        var name: String?
        var latitude: Double?
        var longitude: Double?
        var stopPlace: PatternStopPlace?

        func isIn(stopPlace code: String) -> Bool {
            stopPlace?.id == code || stopPlace?.parent?.id == code
        }

        /// The stop a rider knows: the multimodal parent when there is one (as the geocoder and
        /// `nearest` return), except that the stop the line was listed at keeps its own code.
        func stop(preferring code: String) -> TransitStop {
            let own = stopPlace.map { Place(id: $0.id, name: $0.name, latitude: $0.latitude, longitude: $0.longitude) }
            let place = stopPlace?.id == code ? own : (stopPlace?.parent ?? own)
            let lat = place?.latitude ?? latitude ?? 0
            let lon = place?.longitude ?? longitude ?? 0
            return TransitStop(code: place?.id ?? id, name: place?.name ?? name ?? id, city: nil,
                               location: GeoPoint(lat: lat, lon: lon))
        }
    }

    struct LinePattern: Decodable, Sendable, DirectedPattern {
        struct Journey: Decodable, Sendable { var id: String }
        /// Google encoded polyline, precision 5, in travel order.
        struct Points: Decodable, Sendable { var points: String? }
        var id: String
        var directionType: String?
        var pointsOnLink: Points?
        var serviceJourneysForDate: [Journey]?
        var quays: [Quay]

        var directionKey: String { DTO.directionKey(self) }

        /// Last quay and its stop place(s): what a vehicle's `destinationRef` may name.
        var terminalRefs: [String] {
            guard let last = quays.last else { return [] }
            return [last.id, last.stopPlace?.id, last.stopPlace?.parent?.id].compactMap { $0 }
        }
    }

    // Live

    struct VehiclesData: Decodable, Sendable {
        struct Vehicle: Decodable, Sendable {
            struct Location: Decodable, Sendable { var latitude: Double?; var longitude: Double? }
            struct Journey: Decodable, Sendable { var id: String? }
            struct Call: Decodable, Sendable { var stopPointRef: String? }
            var vehicleId: String?
            var direction: String?
            var destinationRef: String?
            var destinationName: String?
            var lastUpdatedEpochSecond: Double?
            var bearing: Double?
            var serviceJourney: Journey?
            var location: Location?
            var monitoredCall: Call?
        }
        var vehicles: [Vehicle]?
    }

    struct CallsData: Decodable, Sendable {
        struct Place: Decodable, Sendable { var estimatedCalls: [Call]? }
        struct Call: Decodable, Sendable {
            struct Journey: Decodable, Sendable {
                struct Pattern: Decodable, Sendable, DirectedPattern { var id: String; var directionType: String? }
                var id: String?
                var journeyPattern: Pattern?
            }
            var realtime: Bool?
            var aimedArrivalTime: String?
            var expectedArrivalTime: String?
            var aimedDepartureTime: String?
            var expectedDepartureTime: String?
            struct Display: Decodable, Sendable { var frontText: String? }
            var destinationDisplay: Display?
            var serviceJourney: Journey?
        }
        var stopPlace: Place?
    }

    /// Times carry their offset: "2026-09-22T11:36:00+02:00".
    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)
    }

    /// Today's service date in Norway, "yyyy-MM-dd".
    static func serviceDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = EnturProvider.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private nonisolated protocol DirectedPattern {
    var id: String { get }
    var directionType: String? { get }
}
