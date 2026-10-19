import Foundation

/// Tampere region, Finland (Nysse) — ITS Factory Journeys API, a SIRI-flavoured JSON REST API.
/// Keyless, no documented rate limit, CC BY 4.0. Responses are gzipped when asked, and
/// `exclude-fields` trims them hard: a stop's journey patterns without their timetables are ~3 KB
/// instead of ~700 KB, which is what makes this usable straight from the phone.
///
/// A line here is one Journeys line in one direction. The two live endpoints disagree on how they
/// number directions: `stop-monitoring` uses the journey pattern's own `direction` ("0"/"1"), while
/// `vehicle-activity` counts from one ("1"/"2") — checked against origin/destination stops.
nonisolated struct TampereProvider: TransitProvider {
    let id = "tampere"
    let displayName = "Nysse (Tampere)"
    /// `stop-monitoring` only lists vehicles already on their way, so there is no timetable fallback.
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .nearbyStops, .routeShape,
    ]
    let suggestedRefreshInterval: Duration = .seconds(20)

    let attribution: String? = "Data: Tampere Regional Transport (Nysse) / ITS Factory Journeys API, CC BY 4.0"
    static let timeZone = TimeZone(identifier: "Europe/Helsinki")!

    var http = HTTPClient()

    private static let base = "https://data.itsfactory.fi/journeys/api/1"
    /// Keeps each pattern's stop list but drops its timetable and per-stop municipality blocks.
    /// (Excluding `stopPoints.url` would also drop the pattern's own `url`, which carries its id.)
    private static let patternFields = "journeys,stopPoints.municipality,stopPoints.tariffZone"

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        // Stop numbers are four digits with leading zeros ("0012"); `name` does not match them.
        let filter = query.allSatisfy(\.isNumber)
            ? ["shortName": String(repeating: "0", count: max(0, 4 - query.count)) + query]
            : ["name": query]
        let response = try await http.get(Envelope<[DTO.StopPoint]>.self, Self.base, "/stop-points",
                                          query: filter.merging(["exclude-fields": "tariffZone"]) { a, _ in a })
        return (response.body ?? []).compactMap(\.stop)
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let response = try await http.get(Envelope<[DTO.JourneyPattern]>.self, Self.base, "/journey-patterns",
                                          query: ["stopPointId": stop.code, "exclude-fields": Self.patternFields])
        var groups: [String: [DTO.JourneyPattern]] = [:]
        for pattern in response.body ?? [] {
            guard let line = pattern.lineName else { continue }
            groups["\(line)/\(pattern.direction ?? "0")", default: []].append(pattern)
        }
        return groups.values
            .compactMap { patterns in
                // Short-turn variants share a direction with the full run; the longest stands for it.
                patterns.max { ($0.stopPoints?.count ?? 0) < ($1.stopPoints?.count ?? 0) }?.line
            }
            .sorted { a, b in
                a.shortName == b.shortName ? a.id < b.id : a.shortName.localizedStandardCompare(b.shortName) == .orderedAscending
            }
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let pattern = try await journeyPattern(for: line)
        let stops = (pattern?.stopPoints ?? []).compactMap(\.stop)
        guard !stops.isEmpty else { throw TransitError.notFound("stops of Tampere line \(line.id)") }
        // The pattern's route is where its shape lives; kept so the shape needs no second look.
        var line = line
        line.providerRefs["routeId"] = pattern?.routeID
        // The API returns stop points in travel order and publishes no sequence number of its own.
        return RoutePattern(line: line, stops: stops.enumerated().map {
            PatternStop(stop: $0.element, sequence: $0.offset + 1, distanceAlongRoute: nil)
        })
    }

    /// The path of the pattern's route (one route per journey pattern, short turns included):
    /// `routes/{id}` without its journeys is 1–3 KB gzipped, with them ~425 KB.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        var routeID = pattern.line.providerRefs["routeId"]
        if routeID == nil { routeID = try await journeyPattern(for: line)?.routeID }
        guard let routeID else { throw TransitError.notFound("route of Tampere line \(line.id)") }
        let response = try await http.get(Envelope<[DTO.Route]>.self, Self.base, "/routes/\(routeID)",
                                          query: ["exclude-fields": "journeys,journeyPatterns"])
        guard let projection = response.body?.first?.geographicCoordinateProjection else {
            throw TransitError.notFound("shape of Tampere route \(routeID)")
        }
        return RouteShape(try Self.decodeProjection(projection), version: routeID)
    }

    /// "6144766,2383534:-6,-1:0,20:…": the first pair is lat,lon × 1e5, and every pair after it is
    /// *subtracted* from the one before (adding them draws the line mirrored).
    static func decodeProjection(_ text: String) throws -> [GeoPoint] {
        var lat = 0, lon = 0
        return try text.split(separator: ":").enumerated().map { index, pair in
            let values = pair.split(separator: ",").compactMap { Int($0) }
            guard values.count == 2 else { throw TransitError.badResponse("Tampere route projection \(pair)") }
            if index == 0 { (lat, lon) = (values[0], values[1]) } else { lat -= values[0]; lon -= values[1] }
            return GeoPoint(lat: Double(lat) / 1e5, lon: Double(lon) / 1e5)
        }
    }

    private func journeyPattern(for line: TransitLine) async throws -> DTO.JourneyPattern? {
        let (name, direction) = try Self.refs(line)
        var pattern: DTO.JourneyPattern?
        if let id = line.providerRefs["patternId"] {
            pattern = try? await http.get(Envelope<[DTO.JourneyPattern]>.self, Self.base, "/journey-patterns/\(id)",
                                          query: ["exclude-fields": Self.patternFields]).body?.first
        }
        if pattern?.stopPoints?.isEmpty ?? true {
            // Pattern ids are content hashes and change with each timetable; fall back to the line.
            let response = try await http.get(Envelope<[DTO.JourneyPattern]>.self, Self.base, "/journey-patterns",
                                              query: ["lineId": name, "exclude-fields": Self.patternFields])
            pattern = (response.body ?? [])
                .filter { ($0.direction ?? "0") == direction }
                .max { ($0.stopPoints?.count ?? 0) < ($1.stopPoints?.count ?? 0) }
        }
        return pattern
    }

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let (name, direction) = try Self.refs(line)
        let activityDirection = Int(direction).map { String($0 + 1) }
        let response = try await http.get(Envelope<[DTO.VehicleActivity]>.self, Self.base, "/vehicle-activity",
                                          query: ["lineRef": name, "exclude-fields": "monitoredVehicleJourney.onwardCalls"])
        return (response.body ?? []).compactMap { activity -> VehiclePosition? in
            guard let journey = activity.monitoredVehicleJourney,
                  journey.lineRef == name, journey.directionRef == activityDirection,
                  let location = journey.vehicleLocation?.point else { return nil }
            return VehiclePosition(
                location: location,
                recordedAt: activity.recordedAtTime.flatMap(Self.parseISO),
                tripId: journey.framedVehicleJourneyRef?.datedVehicleJourneyRef.flatMap { URL(string: $0)?.lastPathComponent },
                // Operator + vehicle number ("56920_4"), not a plate — the board only needs a stable identity.
                plateNumber: journey.vehicleRef,
                bearing: journey.bearing.flatMap(Double.init),
                speedKmh: journey.speed.flatMap(Double.init),
                aimedDeparture: Self.parseClock(journey.originAimedDepartureTime, on: journey.framedVehicleJourneyRef?.dateFrameRef)
            )
        }
    }

    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let (name, direction) = try Self.refs(line)
        let response = try await http.get(Envelope<[String: [DTO.MonitoredStopVisit]]>.self, Self.base, "/stop-monitoring",
                                          query: ["stops": stop.code])
        return (response.body?[stop.code] ?? [])
            .filter { $0.lineRef == name && $0.directionRef == direction }
            .compactMap { visit -> Arrival? in
                let call = visit.call
                guard let expected = (call?.expectedArrivalTime ?? call?.expectedDepartureTime).flatMap(Self.parseISO) else { return nil }
                return Arrival(
                    expectedAt: expected,
                    scheduledAt: (call?.aimedArrivalTime ?? call?.aimedDepartureTime).flatMap(Self.parseISO),
                    isRealtime: true,
                    tripId: nil,
                    vehicleLocation: visit.vehicleLocation?.point
                )
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// `stop-points?location=` takes a box, "minLat,minLon:maxLat,maxLon" (the "lat,lon:radius" form
    /// returns nothing). Each of the nearest stops is then asked for its lines, capped at 12 stops.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let dLat = radiusMeters / 111_320
        let dLon = radiusMeters / (111_320 * max(cos(point.lat * .pi / 180), 0.01))
        let box = "\(point.lat - dLat),\(point.lon - dLon):\(point.lat + dLat),\(point.lon + dLon)"
        let response = try await http.get(Envelope<[DTO.StopPoint]>.self, Self.base, "/stop-points",
                                          query: ["location": box, "exclude-fields": "tariffZone"])
        let near = (response.body ?? [])
            .compactMap(\.stop)
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

    private static func refs(_ line: TransitLine) throws -> (line: String, direction: String) {
        let parts = line.id.split(separator: "/")
        guard let name = line.providerRefs["line"] ?? parts.first.map(String.init),
              let direction = line.providerRefs["direction"] ?? parts.dropFirst().first.map(String.init) else {
            throw TransitError.unsupported("line \(line.id) is not a Tampere line/direction (was it loaded from another provider?)")
        }
        return (name, direction)
    }

    /// Offsets are always present, with or without fractional seconds:
    /// "2026-09-22T09:24:57.966Z", "2026-09-22T12:31:00+03:00".
    private static func parseISO(_ string: String) -> Date? {
        (try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(string, strategy: Date.ISO8601FormatStyle()))
    }

    /// `originAimedDepartureTime` is a bare local "HHmm" ("0918"); `dateFrameRef` is the service day.
    private static func parseClock(_ hhmm: String?, on day: String?) -> Date? {
        guard let hhmm, hhmm.count == 4, let day else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.date(from: "\(day) \(hhmm)")
    }
}

// MARK: - Wire format

private nonisolated struct Envelope<T: Decodable & Sendable>: Decodable, Sendable {
    var status: String?
    var body: T?
}

private nonisolated enum DTO {
    /// Coordinates arrive as strings: `"61.4986610"`.
    struct Coordinates: Decodable, Sendable {
        var latitude: String?
        var longitude: String?
        var point: GeoPoint? {
            guard let lat = latitude.flatMap(Double.init), let lon = longitude.flatMap(Double.init) else { return nil }
            return GeoPoint(lat: lat, lon: lon)
        }
    }

    struct Municipality: Decodable, Sendable { var name: String? }

    struct StopPoint: Decodable, Sendable {
        var shortName: String
        var name: String?
        /// "lat,lon" as one string: "61.49754,23.76152".
        var location: String?
        var municipality: Municipality?

        var stop: TransitStop? {
            let parts = (location ?? "").split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            return TransitStop(code: shortName, name: name ?? shortName, city: municipality?.name,
                               location: GeoPoint(lat: parts[0], lon: parts[1]))
        }
    }

    struct JourneyPattern: Decodable, Sendable {
        var url: String?
        var lineUrl: String?
        var routeUrl: String?
        var direction: String?
        var name: String?
        var stopPoints: [StopPoint]?

        var id: String? { url.flatMap { URL(string: $0)?.lastPathComponent } }
        var lineName: String? { lineUrl.flatMap { URL(string: $0)?.lastPathComponent } }
        var routeID: String? { routeUrl.flatMap { URL(string: $0)?.lastPathComponent } }

        var line: TransitLine? {
            guard let lineName else { return nil }
            let direction = direction ?? "0"
            let first = stopPoints?.first?.name
            let last = stopPoints?.last?.name
            var refs = ["line": lineName, "direction": direction]
            refs["patternId"] = id
            return TransitLine(
                id: "\(lineName)/\(direction)",
                shortName: lineName,
                headsign: last,
                agency: "Nysse",
                origin: first,
                destination: last,
                providerRefs: refs
            )
        }
    }

    struct Route: Decodable, Sendable { var geographicCoordinateProjection: String? }

    struct VehicleActivity: Decodable, Sendable {
        var recordedAtTime: String?
        var monitoredVehicleJourney: Journey?
    }

    struct FramedJourney: Decodable, Sendable {
        var dateFrameRef: String?
        var datedVehicleJourneyRef: String?
    }

    struct Journey: Decodable, Sendable {
        var lineRef: String?
        var directionRef: String?
        var framedVehicleJourneyRef: FramedJourney?
        var vehicleLocation: Coordinates?
        var bearing: String?
        var speed: String?
        var vehicleRef: String?
        var originAimedDepartureTime: String?
    }

    struct MonitoredStopVisit: Decodable, Sendable {
        struct Call: Decodable, Sendable {
            var aimedArrivalTime: String?
            var expectedArrivalTime: String?
            var aimedDepartureTime: String?
            var expectedDepartureTime: String?
        }

        var lineRef: String?
        var directionRef: String?
        var vehicleLocation: Coordinates?
        var call: Call?
    }
}
