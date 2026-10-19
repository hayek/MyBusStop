import Foundation

/// Brussels, Belgium — STIB-MIVB (buses, trams and metro) through the Belgian Mobility Company's
/// open-data gateway (data.belgianmobility.io). Official and keyless; CC BY 4.0, with the credit
/// line the platform's terms prescribe. Anonymous callers are told to expect about 100 requests a
/// day and 10 a minute (not enforced as of September 2026), so everything static is fetched once
/// per session and the board costs two small requests a refresh. See docs/research/worldwide-apis.md.
///
/// Four datasets, each filtered with an Opendatasoft-like `where`:
/// - `static/stopDetails`: every stop pole (2.5k, ~340 KB of JSON, ~71 KB gzipped), bilingual names.
/// - `static/stopsByLine`: the ordered stop ids of each line in each direction (146 rows, ~22 KB gzipped).
/// - `rt/WaitingTimes`: the next two passages of each line at a stop.
/// - `rt/VehiclePositions`: each vehicle as the last stop it passed plus metres since.
///
/// A `TransitLine` is one line in one direction ("City" or "Suburb"). The static datasets tag some
/// poles with a letter ("2292B"); the realtime ones never do ("2292"), so they are matched on the
/// digits. Names are JSON strings inside the JSON ("{\"fr\":…,\"nl\":…}"). There is no proximity
/// query (a geo filter is silently ignored), so nearby stops come from the cached list.
nonisolated struct STIBProvider: TransitProvider {
    let id = "stib"
    let displayName = "STIB-MIVB (Brussels)"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .scheduledArrivals, .nearbyStops,
    ]
    /// Both realtime datasets refresh about every 20 s; the slow end of the band spares the quota.
    let suggestedRefreshInterval: Duration = .seconds(30)

    var http = HTTPClient()

    static let timeZone = TimeZone(identifier: "Europe/Brussels")!

    /// The platform's terms (art. 4) ask for "Source: [PTO Name] – Open Data – [Date of dataset
    /// update]". The realtime datasets are updated continuously, so the date is today's in Brussels.
    var attribution: String? {
        "Source: STIB-MIVB – Open Data – " + Date().formatted(Date.ISO8601FormatStyle(timeZone: Self.timeZone).year().month().day())
    }

    /// Stop and terminus names come in French and Dutch. Dutch readers get Dutch; everyone else
    /// French, the language most visitors meet first. Resolved per call, like the app's language.
    static var language: STIBLanguage {
        AppLanguage.locale.language.languageCode?.identifier == "nl" ? .nl : .fr
    }

    /// Cached lines and patterns carry names, so each language is its own dataset.
    var datasetID: String { "\(id).\(Self.language.rawValue)" }

    private let base = "https://api-management-discovery-production.azure-api.net/api/datasets/stibmivb"
    private static let store = STIBStore()

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let network = try await network()
        let language = Self.language
        if query.first?.isNumber == true, !query.contains(" ") {
            let code = query.uppercased()
            if let exact = network.stops[code] { return [exact.stop(in: language)] }
            return network.stops.values
                .filter { $0.digits == code }
                .sorted { $0.id < $1.id }
                .map { $0.stop(in: language) }
        }
        let folded = STIBNetwork.fold(query)
        let tokens = folded.split(separator: " ").map(String.init)
        let found = network.stops.values
            .filter { pole in tokens.allSatisfy { pole.key.contains($0) } }
            .map { $0.stop(in: language) }
            .sorted { a, b in
                let ap = STIBNetwork.fold(a.name).hasPrefix(folded), bp = STIBNetwork.fold(b.name).hasPrefix(folded)
                return ap != bp ? ap : (a.name, a.code) < (b.name, b.code)
            }
        return Array(found.prefix(50))
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let network = try await network()
        let language = Self.language
        return network.routes
            .filter { $0.points.contains(stop.code) }
            .map { network.line($0, in: language) }
            .sorted(by: STIBNetwork.order)
    }

    /// Poles missing from `stopDetails` (depots, works diversions, ~90 of them) have no coordinates
    /// and are left out of the pattern.
    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let network = try await network()
        let route = try network.route(of: line)
        let language = Self.language
        let stops = route.points.enumerated().compactMap { index, id -> PatternStop? in
            network.stops[id].map { PatternStop(stop: $0.stop(in: language), sequence: index + 1, distanceAlongRoute: nil) }
        }
        guard stops.count >= 2 else { throw TransitError.notFound("stops for STIB line \(line.id)") }
        return RoutePattern(line: network.line(route, in: language), stops: stops)
    }

    /// The feed gives no coordinates, only the last stop passed and the metres driven since, so each
    /// vehicle is placed that far along the pattern's stop-to-stop polyline. Nor does it say the
    /// direction outright: `directionId` is the stop the vehicle is heading for, usually the
    /// terminus, but a short working's last stop or a diversion's may be neither.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let network = try await network()
        let route = try network.route(of: line)
        let other = network.routes.first { $0.line == route.line && $0.direction != route.direction }
        let response = try await http.get(DTO.Page<DTO.LineVehicles>.self, base, "/rt/VehiclePositions", query: [
            "where": "lineid=\(Self.quoted(route.line))",
        ])
        let pattern = try await routePattern(for: line)
        let geometry = RouteGeometry(pattern: pattern)
        let indexByDigits = Dictionary(pattern.stops.enumerated().map { (STIBNetwork.digits($1.stop.code), $0) },
                                       uniquingKeysWith: { a, _ in a })
        return response.results
            .flatMap(\.vehicles)
            .filter { route.carries($0, other: other) }
            .compactMap { vehicle -> VehiclePosition? in
                guard let index = indexByDigits[vehicle.pointId] else { return nil }
                let start = geometry.stopDistances[index]
                let end = geometry.stopDistances.indices.contains(index + 1) ? geometry.stopDistances[index + 1] : start
                let along = min(start + Double(max(vehicle.distanceFromPoint, 0)), end)
                return VehiclePosition(location: geometry.point(atDistance: along), distanceAlongRoute: along)
            }
    }

    /// Two passages per line and stop. "Theoretical time" marks a timetable guess; buses flagged
    /// "Do not embark" (arriving to terminate) are no use to someone waiting, so they are dropped.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let network = try await network()
        let route = try network.route(of: line)
        let response = try await http.get(DTO.Page<DTO.StopPassages>.self, base, "/rt/WaitingTimes", query: [
            "where": "pointid=\(Self.quoted(STIBNetwork.digits(stop.code))) and lineid=\(Self.quoted(route.line))",
        ])
        // Most poles serve one direction; where a line calls both ways (a loop, a terminus) the
        // passages are told apart by where they are going.
        let bothWays = network.routes.filter { $0.line == route.line && $0.points.contains(stop.code) }.count > 1
        let cutoff = Date().addingTimeInterval(-60)
        return response.results
            .flatMap(\.passages)
            .filter { $0.message?.en != "Do not embark" }
            .filter { !bothWays || $0.destination?.fr == route.destination.fr }
            .compactMap { passage -> Arrival? in
                guard let expected = DTO.parse(passage.expectedArrivalTime), expected >= cutoff else { return nil }
                return Arrival(expectedAt: expected, isRealtime: passage.message?.en != "Theoretical time")
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// Stops and their lines both come from the cached lists: no request of its own.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let network = try await network()
        let language = Self.language
        return network.stops.values
            .map { ($0, RouteGeometry.meters(point, $0.location)) }
            .filter { $0.1 <= radiusMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(30)
            .map { pole, distance in
                let lines = network.routes
                    .filter { $0.points.contains(pole.id) }
                    .map { network.line($0, in: language) }
                    .sorted(by: STIBNetwork.order)
                return NearbyStop(stop: pole.stop(in: language), distanceMeters: distance, lines: lines)
            }
    }

    // MARK: - Helpers

    private func network() async throws -> STIBNetwork {
        try await Self.store.network { [http, base] in
            async let stops = http.get(DTO.Page<DTO.Stop>.self, base, "/static/stopDetails")
            async let routes = http.get(DTO.Page<DTO.Route>.self, base, "/static/stopsByLine")
            return try await STIBNetwork(stops: stops.results.compactMap(\.pole), routes: routes.results.compactMap(\.route))
        }
    }

    /// The gateway's string literal.
    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

nonisolated enum STIBLanguage: String, Sendable {
    case fr, nl
}

// MARK: - Session cache

private actor STIBStore {
    private var task: Task<STIBNetwork, any Error>?

    func network(_ load: @escaping @Sendable () async throws -> STIBNetwork) async throws -> STIBNetwork {
        if let task { return try await task.value }
        let task = Task { try await load() }
        self.task = task
        do {
            return try await task.value
        } catch {
            if self.task == task { self.task = nil }
            throw error
        }
    }
}

/// French and Dutch, both kept so a change of language needs no new download.
private nonisolated struct STIBName: Decodable, Hashable, Sendable {
    var fr: String?
    var nl: String?

    func pick(_ language: STIBLanguage) -> String? {
        let order = language == .nl ? [nl, fr] : [fr, nl]
        return order.lazy.compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}

private nonisolated struct STIBPole: Sendable {
    var id: String
    var name: STIBName
    var location: GeoPoint
    /// Both names folded, for search.
    var key: String

    var digits: String { STIBNetwork.digits(id) }

    func stop(in language: STIBLanguage) -> TransitStop {
        TransitStop(code: id, name: name.pick(language) ?? id, city: nil, location: location)
    }
}

/// One line in one direction, as `stopsByLine` lists it.
private nonisolated struct STIBRoute: Sendable {
    var line: String
    /// "City" or "Suburb".
    var direction: String
    var destination: STIBName
    /// Pole ids in order, letters and all.
    var points: [String]

    var id: String { "\(line)-\(direction)" }
    var terminus: String? { points.last.map(STIBNetwork.digits) }

    /// Whether a vehicle of this line is travelling this way. A vehicle bound for this route's
    /// terminus is; one bound for the other's is not. Otherwise it is judged by the stop it last
    /// passed: on this route only, or on both with the stop it is heading for further along here.
    func carries(_ vehicle: DTO.Vehicle, other: STIBRoute?) -> Bool {
        if vehicle.directionId == terminus { return true }
        if let other, vehicle.directionId == other.terminus { return false }
        let digits = points.map(STIBNetwork.digits)
        guard let at = digits.firstIndex(of: vehicle.pointId) else { return false }
        guard let other, other.points.contains(where: { STIBNetwork.digits($0) == vehicle.pointId }) else { return true }
        return digits.firstIndex(of: vehicle.directionId).map { at <= $0 } ?? false
    }
}

private nonisolated struct STIBNetwork: Sendable {
    let stops: [String: STIBPole]
    let routes: [STIBRoute]

    init(stops: [STIBPole], routes: [STIBRoute]) {
        self.stops = Dictionary(stops.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.routes = routes
    }

    func route(of line: TransitLine) throws -> STIBRoute {
        guard let route = routes.first(where: { $0.id == line.id }) else {
            throw TransitError.notFound("STIB line \(line.id) (was it loaded from another provider?)")
        }
        return route
    }

    func line(_ route: STIBRoute, in language: STIBLanguage) -> TransitLine {
        let destination = route.destination.pick(language)
        return TransitLine(
            id: route.id,
            shortName: route.line,
            headsign: destination,
            agency: "STIB-MIVB",
            origin: route.points.first.flatMap { stops[$0]?.name.pick(language) },
            destination: destination
        )
    }

    /// Numbers in numeric order ("1" … "98"), then anything else ("T81").
    static func order(_ a: TransitLine, _ b: TransitLine) -> Bool {
        (Int(a.shortName) ?? .max, a.shortName, a.id) < (Int(b.shortName) ?? .max, b.shortName, b.id)
    }

    /// A pole id without its letter, as the realtime datasets write it: "2292B" → "2292".
    static func digits(_ id: String) -> String {
        String(id.prefix { $0.isNumber })
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

private nonisolated extension RouteGeometry {
    /// The point a distance along the stop-to-stop polyline, clamped to its ends.
    func point(atDistance distance: Double) -> GeoPoint {
        let points = pattern.stops.map(\.stop.location)
        guard let first = points.first else { return GeoPoint(lat: 0, lon: 0) }
        guard let index = stopDistances.lastIndex(where: { $0 <= distance }), index + 1 < points.count else {
            return distance <= 0 ? first : points[points.count - 1]
        }
        let a = points[index], b = points[index + 1]
        let span = stopDistances[index + 1] - stopDistances[index]
        let t = span > 0 ? min(1, (distance - stopDistances[index]) / span) : 0
        return GeoPoint(lat: a.lat + t * (b.lat - a.lat), lon: a.lon + t * (b.lon - a.lon))
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct Page<T: Decodable & Sendable>: Decodable, Sendable {
        var results: [T]
    }

    /// Several fields are JSON documents serialised into a string.
    static func nested<T: Decodable>(_ type: T.Type, _ string: String?) -> T? {
        string.flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }

    struct Stop: Decodable, Sendable {
        struct Coordinates: Decodable, Sendable {
            var latitude: Double
            var longitude: Double
        }

        var id: String
        var name: String?
        var gpscoordinates: String?

        var pole: STIBPole? {
            guard let coordinates = DTO.nested(Coordinates.self, gpscoordinates) else { return nil }
            let name = DTO.nested(STIBName.self, name) ?? STIBName()
            return STIBPole(
                id: id, name: name, location: GeoPoint(lat: coordinates.latitude, lon: coordinates.longitude),
                key: STIBNetwork.fold([name.fr, name.nl].compactMap { $0 }.joined(separator: " "))
            )
        }
    }

    struct Route: Decodable, Sendable {
        struct Point: Decodable, Sendable {
            var id: String
            var order: Int
        }

        var lineid: String
        var direction: String
        var destination: String?
        var points: String?

        var route: STIBRoute? {
            guard let points = DTO.nested([Point].self, points), !points.isEmpty else { return nil }
            return STIBRoute(
                line: lineid, direction: direction,
                destination: DTO.nested(STIBName.self, destination) ?? STIBName(),
                points: points.sorted { $0.order < $1.order }.map(\.id)
            )
        }
    }

    struct LineVehicles: Decodable, Sendable {
        var vehiclepositions: String?

        var vehicles: [Vehicle] { DTO.nested([Vehicle].self, vehiclepositions) ?? [] }
    }

    struct Vehicle: Decodable, Sendable {
        var directionId: String
        var distanceFromPoint: Int
        var pointId: String
    }

    struct StopPassages: Decodable, Sendable {
        var passingtimes: String?

        var passages: [Passage] { DTO.nested([Passage].self, passingtimes) ?? [] }
    }

    struct Passage: Decodable, Sendable {
        struct Message: Decodable, Sendable {
            var en: String?
        }

        var destination: STIBName?
        var expectedArrivalTime: String
        var message: Message?
    }

    /// "2026-09-28T15:46:01.541+02:00" — Brussels offset, with or without milliseconds.
    static func parse(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
