import Foundation

/// Worldwide fallback — Transitous (api.transitous.org), a community-run MOTIS 2 server fed by the
/// open GTFS / GTFS-RT feeds of several hundred operators. Used only where no region of ours covers
/// the rider, and only while the `transitous_enabled` remote flag is on.
///
/// LICENCE: the Transitous API policy (transitous.org/api) allows use only by projects that are
/// open source, NOT commercial, and light on its resources — "commercial use is not allowed". It
/// is also best-effort and may cut any client off at any time. This provider must stay switched off
/// (the flag defaults to false) in any paid or closed-source build.
///
/// Arrivals only: MOTIS publishes departures with realtime delays (`realTime` says per departure
/// whether a GTFS-RT update applied) but no vehicle positions. Its `/map/trips` positions are
/// interpolated from the timetable, so they are deliberately not offered as buses on the map.
/// Every request needs a User-Agent (403 without). Stop ids are `<feed>_<gtfs stop_id>`; there is
/// no search by the code printed on the sign, only by name. Buses and trams only.
nonisolated struct TransitousProvider: TransitProvider {
    static let providerID = "transitous"
    let id = TransitousProvider.providerID
    let displayName = "Transitous (worldwide)"
    /// The attribution the Transitous policy asks for: its sources page and OpenStreetMap.
    let attribution: String? = "Data: Transitous, https://transitous.org/sources/ · © OpenStreetMap contributors"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .linesAtStop, .routePattern, .realtimeArrivals, .scheduledArrivals, .nearbyStops, .routeShape,
    ]
    /// A volunteer server that asks to be spared: the board's per-line calls share one cached
    /// departures request per stop, so a poll costs one request.
    let suggestedRefreshInterval: Duration = .seconds(30)

    var session: URLSession = .shared

    private let base = "https://api.transitous.org"
    private static let modes = "BUS,TRAM"
    /// Departures looked at for a stop: the next 90 minutes, and at least 20 at a quiet stop.
    private static let departureWindow = 5400
    private static let departureMinimum = 20

    /// MOTIS applies GTFS translations where a feed has them and falls back to the published names.
    private var language: String { AppLanguage.locale.language.languageCode?.identifier ?? "en" }
    var datasetID: String { "\(id).\(language)" }
    /// A line's path has no names in it.
    var shapeDatasetID: String { id }

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let found = try await get([DTO.Match].self, "/api/v1/geocode",
                                  ["text": query, "type": "STOP", "mode": Self.modes,
                                   "numResults": "20", "language": language])
        return found.compactMap(\.stop)
    }

    /// One line per route and direction that departs from the stop in the next 90 minutes. A route
    /// that runs later (a night bus, by day) is not listed until it does.
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let departures = try await departures(at: stop.code)
        var groups: [String: [DTO.StopTime]] = [:]
        var order: [String] = []
        for departure in departures {
            let key = Self.lineID(departure)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(departure)
        }
        return order.compactMap { key in
            guard let group = groups[key], let first = group.first else { return nil }
            // The headsign most of its departures carry names the direction; short workings vary it.
            let headsign = Dictionary(grouping: group.compactMap(\.headsign), by: { $0 })
                .max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }?.key
            let typical = group.first { $0.headsign == headsign } ?? first
            var refs = ["routeId": first.routeId, "stopId": stop.code]
            if let direction = first.directionId { refs["directionId"] = direction }
            if let headsign { refs["headsign"] = headsign }
            return TransitLine(id: key, shortName: first.lineName, headsign: headsign,
                               agency: first.agencyName, origin: typical.tripFrom?.name,
                               destination: typical.tripTo?.name ?? headsign, providerRefs: refs)
        }
    }

    /// The whole trip of the line's next departure from the rider's stop, which is always a trip of
    /// that direction that serves it. The stop the rider boards at is renamed to the stop they
    /// chose, since the trip lists the platform and the board finds the rider's stop by code.
    ///
    /// A vehicle that runs on as another line (stay seated) would by default come back as one
    /// joined leg: Zürich's tram 4 arrived as route 13 from Albisgütli, with 13's stops in front.
    /// Unjoined, the trip asked for is its own leg.
    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        try await trip(of: line).pattern
    }

    /// The trip reply carries the leg's line along the roads (`legGeometry`, the feed's GTFS shape,
    /// or OSM-routed by MOTIS for feeds without one), so the shape costs no request. A leg without
    /// one gives an empty shape, kept so the card does not ask again.
    func routePatternWithShape(for line: TransitLine) async throws -> (pattern: RoutePattern, shape: RouteShape?) {
        try await trip(of: line)
    }

    /// Only asked for when the pattern was kept from before shapes were: the pattern's calls again.
    /// No departure soon (at night) says nothing about the path, so the card asks again next time.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        guard let shape = try await trip(of: line, noDeparture: TransitError.tryLater).shape, !shape.isEmpty else {
            throw TransitError.notFound("shape of \(line.shortName)")
        }
        return shape
    }

    private func trip(of line: TransitLine, noDeparture: (String) -> TransitError = TransitError.notFound) async throws
        -> (pattern: RoutePattern, shape: RouteShape?) {
        guard let stopID = line.providerRefs["stopId"] else { throw TransitError.notFound("stop of line \(line.id)") }
        guard let next = try await departures(at: stopID).first(where: { Self.lineID($0) == line.id }) else {
            throw noDeparture("a departure of \(line.shortName) from \(stopID)")
        }
        let trip = try await get(DTO.Itinerary.self, "/api/v6/trip",
                                 ["tripId": next.tripId, "joinInterlinedLegs": "false", "language": language])
        // A leg without its trip id: the one that leaves from the rider's stop, not the one that
        // ends there and hands over to it.
        let calling = { (leg: DTO.Itinerary.Leg) in leg.places.dropLast().contains { $0.stopId == next.place.stopId } }
        guard let leg = trip.legs.first(where: { $0.tripId == next.tripId }) ?? trip.legs.first(where: calling) ?? trip.legs.first else {
            throw TransitError.notFound("trip \(next.tripId)")
        }
        let places = leg.places
        let boarding = places.firstIndex { $0.stopId == next.place.stopId && $0.departure == next.place.departure }
            ?? places.firstIndex { $0.stopId == next.place.stopId }
        let stops = places.enumerated().compactMap { index, place -> PatternStop? in
            guard var stop = place.stop else { return nil }
            if index == boarding { stop.code = stopID }
            return PatternStop(stop: stop, sequence: index + 1, distanceAlongRoute: nil)
        }
        let points = leg.legGeometry.flatMap { try? Polyline.decode($0.points, precision: $0.precision ?? 6) }
        return (RoutePattern(line: line, stops: stops), RouteShape(points ?? []))
    }

    /// No vehicle positions exist in MOTIS; see the type's comment.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }

    /// A trip that calls at two platforms of the stop (a bus station's bays, a loop) comes once per
    /// call, a minute or two apart; it is kept once, at the rider's own stop when it calls there.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        var calls: [String: DTO.StopTime] = [:]
        var order: [String] = []
        for departure in try await departures(at: stop.code)
        where Self.lineID(departure) == line.id && !departure.isCancelled && departure.place.cancelled != true {
            guard let kept = calls[departure.tripId] else {
                calls[departure.tripId] = departure
                order.append(departure.tripId)
                continue
            }
            if departure.place.stopId == stop.code, kept.place.stopId != stop.code { calls[departure.tripId] = departure }
        }
        return order.compactMap { calls[$0] }
            .compactMap { departure -> Arrival? in
                let place = departure.place
                guard let expected = (place.departure ?? place.arrival).flatMap(DTO.parseDate) else { return nil }
                return Arrival(expectedAt: expected,
                               scheduledAt: (place.scheduledDeparture ?? place.scheduledArrival).flatMap(DTO.parseDate),
                               isRealtime: departure.realTime, tripId: departure.tripId)
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// `/map/stops` with `grouped` answers one entry per stop area in a box but says nothing about
    /// routes, so the nearest few are each asked `/stop` for theirs, in parallel.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let dLat = radiusMeters / 111_320
        let dLon = dLat / max(cos(point.lat * .pi / 180), 0.01)
        let places = try await get([DTO.Place].self, "/api/v6/map/stops",
                                   ["min": "\(point.lat - dLat),\(point.lon - dLon)",
                                    "max": "\(point.lat + dLat),\(point.lon + dLon)",
                                    "grouped": "true", "language": language])
        let candidates = places
            .filter { $0.servesBusOrTram }
            .compactMap { place in place.stop.map { ($0, RouteGeometry.meters(point, $0.location)) } }
            .filter { $0.1 <= radiusMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(8)
        return try await withThrowingTaskGroup(of: NearbyStop?.self) { group in
            for (stop, distance) in candidates {
                group.addTask {
                    let info = try await get(DTO.StopInfo.self, "/api/v6/stop", ["stopId": stop.code, "language": language])
                    var seen = Set<String>()
                    let lines = info.routes
                        .filter { DTO.busModes.contains($0.mode ?? "") }
                        .filter { seen.insert($0.routeShortName ?? $0.routeId).inserted }
                        .map { TransitLine(id: $0.routeId, shortName: $0.routeShortName ?? "?", agency: $0.agencyName) }
                    return lines.isEmpty ? nil : NearbyStop(stop: stop, distanceMeters: distance, lines: lines)
                }
            }
            var found: [NearbyStop] = []
            for try await stop in group { if let stop { found.append(stop) } }
            return found.sorted { $0.distanceMeters < $1.distanceMeters }
        }
    }

    // MARK: - Requests

    /// A line is one route in one direction. Feeds without `direction_id` are split by headsign.
    private static func lineID(_ departure: DTO.StopTime) -> String {
        "\(departure.routeId)|\(departure.directionId ?? "h:" + (departure.headsign ?? ""))"
    }

    /// The stop's upcoming bus and tram departures (by default MOTIS also includes its platforms
    /// and same-named stops nearby). Kept for 15 s, so the lines of one board poll share a request.
    private func departures(at stopID: String) async throws -> [DTO.StopTime] {
        let key = "\(stopID)|\(language)"
        return try await TransitousDepartures.shared.value(for: key) {
            try await get(DTO.StopTimes.self, "/api/v6/stoptimes",
                          ["stopId": stopID, "mode": Self.modes, "window": String(Self.departureWindow),
                           "n": String(Self.departureMinimum), "withAlerts": "false", "language": language])
                .stopTimes
        }
    }

    /// "BusBus-iOS/1.0 (+https://github.com/hayek/MyBusStop)": the version is the app's own, and the
    /// link is the open-source repository, where its authors can be reached.
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "BusBus-iOS/\(version) (+https://github.com/hayek/MyBusStop)"
    }()

    private func get<T: Decodable>(_ type: T.Type, _ path: String, _ query: [String: String]) async throws -> T {
        guard var components = URLComponents(string: base + path) else { throw TransitError.badResponse("invalid URL \(path)") }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw TransitError.badResponse("invalid URL \(path)") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The policy asks for the app's name, version and a way to reach its authors.
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Through HTTPClient: the nearby box says where the rider is, and must not be cached.
        let (data, response) = try await HTTPClient.data(for: request, on: session)
        try HTTPClient.check(data, response, request, path)
        return try HTTPClient.decode(T.self, data, response, request, path)
    }
}

/// Departures per stop for a few seconds, so three lines on one board cost one request, and
/// concurrent callers share the one in flight. Failures are not kept.
private actor TransitousDepartures {
    static let shared = TransitousDepartures()
    private static let lifetime: TimeInterval = 15
    private var entries: [String: (at: Date, task: Task<[DTO.StopTime], any Error>)] = [:]

    func value(for key: String, load: @escaping @Sendable () async throws -> [DTO.StopTime]) async throws -> [DTO.StopTime] {
        let now = Date()
        entries = entries.filter { now.timeIntervalSince($0.value.at) < Self.lifetime }
        if let entry = entries[key] { return try await entry.task.value }
        let task = Task { try await load() }
        entries[key] = (now, task)
        do { return try await task.value } catch { entries[key] = nil; throw error }
    }
}

// MARK: - Wire format (MOTIS 2)

private nonisolated enum DTO {
    static let busModes: Set<String> = ["BUS", "TRAM"]

    struct Area: Decodable, Sendable {
        var name: String
        var `default`: Bool?
    }

    /// A geocoder hit; only `type == "STOP"` is asked for.
    struct Match: Decodable, Sendable {
        var type: String
        var id: String
        var name: String
        var lat: Double
        var lon: Double
        var areas: [Area]?

        var stop: TransitStop? {
            guard type == "STOP" else { return nil }
            return TransitStop(code: id, name: name, city: areas?.first { $0.default == true }?.name,
                               location: GeoPoint(lat: lat, lon: lon))
        }
    }

    struct Place: Decodable, Sendable {
        var name: String
        var stopId: String?
        var lat: Double
        var lon: Double
        var modes: [String]?
        var arrival: String?
        var departure: String?
        var scheduledArrival: String?
        var scheduledDeparture: String?
        var cancelled: Bool?
        /// The feed's GTFS `stop_desc`. Some feeds put the street there; many leave it empty or
        /// repeat the name, which the address line hides.
        var description: String?

        var stop: TransitStop? {
            stopId.map { TransitStop(code: $0, name: name, city: nil, location: GeoPoint(lat: lat, lon: lon),
                                     address: TransitStop.address([description])) }
        }

        var servesBusOrTram: Bool { (modes ?? []).contains { DTO.busModes.contains($0) } }
    }

    struct StopTimes: Decodable, Sendable {
        var stopTimes: [StopTime]
    }

    struct StopTime: Decodable, Sendable {
        var place: Place
        var realTime: Bool
        var headsign: String?
        var tripFrom: Place?
        var tripTo: Place?
        var agencyName: String?
        var routeId: String
        var directionId: String?
        var tripId: String
        var routeShortName: String?
        var displayName: String?
        var cancelled: Bool?
        var tripCancelled: Bool?

        var lineName: String { [routeShortName, displayName].compactMap { $0 }.first { !$0.isEmpty } ?? "?" }
        var isCancelled: Bool { cancelled == true || tripCancelled == true }
    }

    struct StopInfo: Decodable, Sendable {
        struct Route: Decodable, Sendable {
            var routeId: String
            var routeShortName: String?
            var mode: String?
            var agencyName: String?
        }
        var routes: [Route]
    }

    struct Itinerary: Decodable, Sendable {
        struct Leg: Decodable, Sendable {
            var tripId: String?
            var from: Place
            var to: Place
            var intermediateStops: [Place]?
            var legGeometry: EncodedPolyline?

            var places: [Place] { [from] + (intermediateStops ?? []) + [to] }
        }
        var legs: [Leg]
    }

    /// A Google polyline, lat/lon, at precision 6 on every reply seen.
    struct EncodedPolyline: Decodable, Sendable {
        var points: String
        var precision: Int?
    }

    /// UTC, "2026-09-22T13:04:00Z"; fractional seconds are accepted too.
    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}
