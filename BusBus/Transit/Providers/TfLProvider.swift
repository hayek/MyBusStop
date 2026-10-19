import Foundation

/// London — TfL Unified API (api.tfl.gov.uk). Official, keyless at 50 requests/minute per IP
/// (500/min with a free `app_key`). Commercial use is allowed under the TfL transport data terms,
/// which require the credit "Powered by TfL Open Data" (and "Contains OS data © Crown copyright and
/// database rights 2016"). See docs/research/worldwide-apis.md §6.1.
///
/// ARRIVALS-ONLY: TfL publishes no bus GPS (`Line/{id}/Vehicles` is a 404), only iBus countdown
/// predictions, which have no timetable time next to them.
///
/// Stops are NaPTAN ids ("490000173RC"): that is what every endpoint takes. The 5-digit SMS code on
/// the stop flag is accepted by search and resolved to its NaPTAN id. Bus stops are one-directional,
/// so a line at a stop is one `TransitLine` per direction ("88:inbound").
nonisolated struct TfLProvider: TransitProvider {
    let id = "tfl"
    let displayName = "TfL (London)"
    let attribution: String? = "Powered by TfL Open Data. Contains OS data © Crown copyright and database rights"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .realtimeArrivals, .nearbyStops, .routeShape,
    ]
    /// Predictions are refreshed upstream every ~30 s, and 50 req/min is shared by everything on the IP.
    let suggestedRefreshInterval: Duration = .seconds(30)

    var http = HTTPClient()

    private let base = "https://api.tfl.gov.uk"
    private static let lookedUp = TfLStopLookups()

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        if query.count == 5, Int(query) != nil {
            // `/StopPoint/Sms/{code}` answers with a 302 to `/StopPoint/{naptanId}`, which URLSession follows.
            // An unknown code is a 404, read as "no such stop"; the code is checked on the way back anyway.
            guard let point = try? await http.get(DTO.StopPoint.self, base, "/StopPoint/Sms/\(query)"),
                  point.smsCode == query else { return [] }
            return point.busStops.map(\.stop)
        }
        // Matches are a mix of single stops and stop groups ("490G…"), and carry no stop letter, so
        // they are looked up again in one batched call to get both the children and the letters.
        let term = query.replacingOccurrences(of: "/", with: " ")
        let path = "/StopPoint/Search/\(term.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? term)"
        let search = try await http.get(DTO.SearchResponse.self, base, path,
                                        query: ["modes": "bus", "includeHubs": "false", "maxResults": "12"])
        let ids = search.matches.map(\.id)
        guard !ids.isEmpty else { return [] }
        let points = try await http.get(DTO.OneOrMany<DTO.StopPoint>.self, base, "/StopPoint/\(ids.joined(separator: ","))")
        var seen = Set<String>()
        return points.items.flatMap(\.busStops).filter { seen.insert($0.naptanId).inserted }.map(\.stop)
    }

    /// `StopPoint/{id}/Route` lists each line's route sections through the stop with their direction,
    /// which is exactly the per-direction split the picker needs, in one call.
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let sections = try await http.get([DTO.RouteSection].self, base, "/StopPoint/\(stop.code)/Route",
                                          query: ["serviceTypes": "Regular,Night"])
        var byLine: [String: DTO.RouteSection] = [:]
        var order: [String] = []
        for section in sections where section.mode == "bus" {
            let key = "\(section.lineId):\(section.direction)"
            if let existing = byLine[key] {
                // Branches: keep a section that is running today over one that is not.
                if existing.isActive != true, section.isActive == true { byLine[key] = section }
            } else {
                byLine[key] = section
                order.append(key)
            }
        }
        return order.compactMap { byLine[$0]?.line(atStop: stop.code) }
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        try await routeSequence(for: line).pattern
    }

    /// `Route/Sequence` carries the drawn line too (`lineStrings`), so the shape costs no request.
    /// A reply without one is kept as an empty shape: the card would only ask again to learn so.
    func routePatternWithShape(for line: TransitLine) async throws -> (pattern: RoutePattern, shape: RouteShape?) {
        let (pattern, sequence) = try await routeSequence(for: line)
        return (pattern, Self.shape(sequence.lineStrings ?? [], for: pattern, tolerance: shapeTolerance) ?? RouteShape(branches: []))
    }

    /// Only asked for when the pattern was kept from before shapes were; the same one call.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        let sequence = try await routeSequence(for: line).sequence
        guard let shape = Self.shape(sequence.lineStrings ?? [], for: pattern, tolerance: shapeTolerance) else {
            throw TransitError.notFound("shape of line \(line.id)")
        }
        return shape
    }

    /// `lineStrings` are not one per route variant: identical copies, and pieces for short workings
    /// beside the full route (63 inbound). Of every distinct piece, the shortest one the stops lie
    /// along is the pattern's. Pieces are never joined: the 63's two joined run twice its length.
    /// When none fits (19 inbound's Highbury Grove routing has no geometry of its own), the longest
    /// is kept anyway, so the cache records the rejection instead of asking again.
    static func shape(_ lineStrings: [String], for pattern: RoutePattern, tolerance: ShapeTolerance) -> RouteShape? {
        let pieces = lineStrings.flatMap { string -> [[GeoPoint]] in
            // A JSON string inside the JSON: `[[[lon, lat], …], …]`, one array per piece.
            guard let decoded = try? JSONDecoder().decode([[[Double]]].self, from: Data(string.utf8)) else { return [] }
            return decoded.map { $0.compactMap { $0.count >= 2 ? GeoPoint(lat: $0[1], lon: $0[0]) : nil } }
        }
        let stops = pattern.stops.map(\.stop.location)
        if let best = ShapeCheck.bestPiece(pieces, stops: stops, tolerance: tolerance) { return RouteShape(best) }
        return pieces.filter { $0.count >= 2 }.max { ShapeCheck.length($0) < ShapeCheck.length($1) }.map { RouteShape($0) }
    }

    private func routeSequence(for line: TransitLine) async throws -> (pattern: RoutePattern, sequence: DTO.RouteSequence) {
        let ref = try await reference(for: line)
        let sequence = try await http.get(
            DTO.RouteSequence.self, base, "/Line/\(ref.lineId)/Route/Sequence/\(ref.direction)",
            query: ["serviceTypes": "Regular,Night", "excludeCrowding": "true"]
        )
        var points: [String: TransitStop] = [:]
        for branch in sequence.stopPointSequences ?? [] {
            for point in branch.stopPoint ?? [] { points[point.id] = point.stop }
        }
        // `orderedLineRoutes` are the whole end-to-end variants; the longest one through the rider's
        // stop is the one the board draws.
        let routes = (sequence.orderedLineRoutes ?? []).map(\.naptanIds)
        let through = routes.filter { ids in ref.naptanId.map(ids.contains) ?? true }
        guard let ids = (through.isEmpty ? routes : through).max(by: { $0.count < $1.count }), !ids.isEmpty else {
            throw TransitError.notFound("stops for line \(ref.lineId) \(ref.direction)")
        }
        // A diversion's own stops can be missing from `stopPointSequences`, which then describe the
        // usual road (19 inbound, Highbury Grove works: 10 of 47 stops). They are looked up in one
        // call rather than dropped, which left a gap in the pattern. Kept for the session: the card
        // and the next day's refresh would ask for the same stops again.
        let missing = Set(ids.filter { points[$0] == nil })
        if !missing.isEmpty, let found = try? await Self.lookedUp.stops(missing, load: { [http, base] in
            let reply = try await http.get(DTO.OneOrMany<DTO.StopPoint>.self, base, "/StopPoint/\(missing.sorted().joined(separator: ","))")
            return reply.items.flatMap(\.busStops).filter { missing.contains($0.naptanId) }.map { ($0.naptanId, $0.stop) }
        }) {
            for (id, stop) in found { points[id] = stop }
        }
        let stops = ids.compactMap { points[$0] }
        guard stops.count >= 2 else { throw TransitError.notFound("stops for line \(ref.lineId) \(ref.direction)") }
        let pattern = RoutePattern(
            line: line,
            stops: stops.enumerated().map { PatternStop(stop: $0.element, sequence: $0.offset, distanceAlongRoute: nil) }
        )
        return (pattern, sequence)
    }

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }

    /// `Line/{id}/Arrivals/{stop}` narrows the countdown to one line at one stop. Every prediction
    /// is live iBus data; TfL gives no scheduled time alongside it.
    ///
    /// The feed now and then lists one prediction twice under the same `id`, and a reply may be up to
    /// a minute old (`s-maxage=60` at the edge), so a prediction past its `timeToLive` is dropped.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let ref = try await reference(for: line)
        var query: [String: String] = [:]
        if line.providerRefs["direction"] != nil { query["direction"] = ref.direction }
        let predictions = try await http.get([DTO.Prediction].self, base, "/Line/\(ref.lineId)/Arrivals/\(stop.code)", query: query)
        let now = Date()
        var seen = Set<String>()
        return predictions
            .filter { $0.naptanId == stop.code && $0.lineId == ref.lineId }
            .filter { $0.id.map { seen.insert($0).inserted } ?? true }
            .filter { $0.timeToLive.flatMap(DTO.parseInstant).map { $0 > now } ?? true }
            .compactMap { prediction in
                prediction.expectedArrival.flatMap(DTO.parseInstant).map {
                    Arrival(expectedAt: $0, scheduledAt: nil, isRealtime: true, tripId: nil, vehicleLocation: nil)
                }
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// The proximity search returns each stop with the ids of its lines but not their direction, so
    /// those lines only carry the stop; the direction is looked up if one is ever used on its own.
    /// Stops with no lines (disused, or drop-off only) are left out.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let response = try await http.get(DTO.NearbyResponse.self, base, "/StopPoint", query: [
            "lat": String(point.lat), "lon": String(point.lon), "radius": String(Int(radiusMeters)),
            "stopTypes": "NaptanPublicBusCoachTram", "modes": "bus", "returnLines": "true",
        ])
        return response.stopPoints
            .filter { $0.modes?.contains("bus") ?? false && !($0.lines ?? []).isEmpty }
            .map { entry in
                let stop = entry.stop
                let lines = (entry.lines ?? []).map { line in
                    TransitLine(id: "\(line.id)@\(entry.naptanId)", shortName: DTO.displayName(line.name ?? line.id),
                                agency: "TfL", providerRefs: ["lineId": line.id, "naptanId": entry.naptanId])
                }
                return NearbyStop(stop: stop, distanceMeters: RouteGeometry.meters(point, stop.location), lines: lines)
            }
            .sorted { $0.distanceMeters < $1.distanceMeters }
    }

    // MARK: - Line references

    private struct Reference { var lineId: String; var direction: String; var naptanId: String? }

    private func reference(for line: TransitLine) async throws -> Reference {
        let lineId = line.providerRefs["lineId"] ?? String(line.id.prefix { $0 != ":" && $0 != "@" })
        let naptanId = line.providerRefs["naptanId"]
        if let direction = line.providerRefs["direction"] {
            return Reference(lineId: lineId, direction: direction, naptanId: naptanId)
        }
        // A line from the nearby list: its stop is one-directional, so its route through it says which way.
        guard let naptanId else { throw TransitError.unsupported("line \(line.id) has no direction or stop") }
        let sections = try await http.get([DTO.RouteSection].self, base, "/StopPoint/\(naptanId)/Route",
                                          query: ["serviceTypes": "Regular,Night"])
        guard let section = sections.first(where: { $0.lineId == lineId }) else {
            throw TransitError.notFound("line \(lineId) at stop \(naptanId)")
        }
        return Reference(lineId: lineId, direction: section.direction, naptanId: naptanId)
    }
}

/// Diversion stops looked up by id, per set of ids, for the session. A failed lookup is forgotten.
private actor TfLStopLookups {
    private var tasks: [Set<String>: Task<[(String, TransitStop)], any Error>] = [:]

    func stops(_ ids: Set<String>, load: @escaping @Sendable () async throws -> [(String, TransitStop)]) async throws -> [(String, TransitStop)] {
        if let task = tasks[ids] { return try await task.value }
        let task = Task { try await load() }
        tasks[ids] = task
        do { return try await task.value } catch { tasks[ids] = nil; throw error }
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    /// `/StopPoint/{a,b}` answers with an array, `/StopPoint/{a}` with a single object.
    struct OneOrMany<T: Decodable & Sendable>: Decodable, Sendable {
        var items: [T]
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let many = try? container.decode([T].self) { items = many } else { items = [try container.decode(T.self)] }
        }
    }

    struct Identifier: Decodable, Sendable { var id: String; var name: String? }

    struct SearchResponse: Decodable, Sendable {
        struct Match: Decodable, Sendable { var id: String }
        var matches: [Match]
    }

    struct StopPoint: Decodable, Sendable {
        var naptanId: String
        var commonName: String
        var stopLetter: String?
        var smsCode: String?
        var stopType: String?
        var modes: [String]?
        var lines: [Identifier]?
        var lat: Double
        var lon: Double
        var children: [StopPoint]?
        var distance: Double?

        var stop: TransitStop {
            TransitStop(code: naptanId, name: DTO.stopName(commonName, letter: stopLetter), city: nil,
                        location: GeoPoint(lat: lat, lon: lon))
        }

        /// This point and everything under it that a bus actually stops at.
        var busStops: [StopPoint] {
            let own = stopType == "NaptanPublicBusCoachTram" && (modes?.contains("bus") ?? false) ? [self] : []
            return own + (children ?? []).flatMap(\.busStops)
        }
    }

    struct NearbyResponse: Decodable, Sendable { var stopPoints: [StopPoint] }

    struct MatchedStop: Decodable, Sendable {
        var id: String
        var name: String
        var stopLetter: String?
        var lat: Double
        var lon: Double

        var stop: TransitStop {
            TransitStop(code: id, name: DTO.stopName(name, letter: stopLetter), city: nil, location: GeoPoint(lat: lat, lon: lon))
        }
    }

    struct RouteSection: Decodable, Sendable {
        var lineId: String
        var mode: String?
        var direction: String
        var routeSectionName: String?
        var destinationName: String?
        var vehicleDestinationText: String?
        var isActive: Bool?

        func line(atStop naptanId: String) -> TransitLine {
            // "Etherow Street - Margaret Street / Oxford Circus": origin is what precedes the destination.
            var origin: String?
            if let name = routeSectionName, let destination = destinationName, name.hasSuffix(" - " + destination) {
                origin = String(name.dropLast(destination.count + 3))
            }
            return TransitLine(
                id: "\(lineId):\(direction)",
                shortName: DTO.displayName(lineId),
                headsign: vehicleDestinationText ?? destinationName,
                agency: "TfL",
                origin: origin,
                destination: destinationName,
                providerRefs: ["lineId": lineId, "direction": direction, "naptanId": naptanId]
            )
        }
    }

    struct RouteSequence: Decodable, Sendable {
        struct Branch: Decodable, Sendable { var stopPoint: [MatchedStop]? }
        struct OrderedRoute: Decodable, Sendable { var naptanIds: [String] }
        var stopPointSequences: [Branch]?
        var orderedLineRoutes: [OrderedRoute]?
        /// The drawn line, as JSON strings; see `TfLProvider.shape`.
        var lineStrings: [String]?
    }

    struct Prediction: Decodable, Sendable {
        var id: String?
        var lineId: String?
        var naptanId: String?
        var expectedArrival: String?
        /// When the prediction stops being valid, ~30 s after `expectedArrival`.
        var timeToLive: String?
    }

    /// Night routes have lower-case ids ("n15"); the blinds say "N15".
    static func displayName(_ lineId: String) -> String { lineId.uppercased() }

    /// "Oxford Circus Station (Stop RC)". Stops without a letter publish an arrow ("->W") instead.
    static func stopName(_ name: String, letter: String?) -> String {
        let name = name.replacingOccurrences(of: "  ", with: " ")
        guard let letter, !letter.isEmpty, !letter.hasPrefix("-") else { return name }
        return "\(name) (Stop \(letter))"
    }

    /// Instants are UTC with a "Z": "2026-09-22T09:42:35Z".
    static func parseInstant(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: String(string.prefix(19)) + "Z")
    }
}
