import Foundation

/// Germany and Austria — Mentz EFA journey planners in their `rapidJSON` dialect. One adapter, one
/// host per instance: Baden-Württemberg (efa-bw.de, NVBW), NRW (efa.vrr.de, VRR) and Linz (LINZ AG
/// LINIEN). Keyless. The same dialect sits behind Munich's MVV, which `MVGProvider` borrows for its
/// lines and patterns. See docs/research/worldwide-apis.md §5.7.
///
/// ARRIVALS-ONLY: EFA knows planned and live departure times, never vehicle positions.
///
/// Terms differ per host. Linz publishes its EFA as Open Government Data (CC BY 4.0,
/// data.linz.gv.at). efa-bw.de and efa.vrr.de are the backends of the operators' own web planners
/// with no published API terms: NVBW's official route is a keyed TRIAS/EFA-JSON access under a
/// signed agreement (MobiData BW), and VRR's imprint reserves reuse of its content. Either host can
/// add a key or block us without notice.
///
/// Stops are DHIDs ("de:08111:6075", "at:44:41166"), the stop area; departures come back per
/// platform underneath it. A line is one EFA line id per direction ("vvs:30044: :H:j26", `H`/`R` is
/// the direction), which the departure monitor accepts as a filter and `XML_GEOOBJECT_REQUEST`
/// turns into the full ordered stop list without needing a trip or a date. All times are UTC.
nonisolated struct EFAProvider: TransitProvider {
    /// One EFA installation.
    struct Instance: Sendable {
        var id: String
        var displayName: String
        var base: String
        var attribution: String?
        var timeZone: TimeZone
        /// Whether the line's path in the geo object is drawn. Only checked for Linz so far.
        var drawsShapes = false
    }

    let instance: Instance
    var http = HTTPClient()

    init(_ instance: Instance) {
        self.instance = instance
    }

    var id: String { instance.id }
    var displayName: String { instance.displayName }
    var attribution: String? { instance.attribution }
    var capabilities: ProviderCapabilities {
        let base: ProviderCapabilities = [
            .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
            .realtimeArrivals, .scheduledArrivals, .nearbyStops,
        ]
        return instance.drawsShapes ? base.union(.routeShape) : base
    }
    /// No published limit on any host; one departure-monitor call per poll, kept gentle.
    let suggestedRefreshInterval: Duration = .seconds(30)

    /// Bus and tram only: Stadtbahn (3), tram (4), city/regional/express bus (5, 6, 7), on-demand
    /// (10), rail replacement (17) and community bus (19). Trains, U-Bahn and ferries are dropped.
    static let surfaceClasses: Set<Int> = [3, 4, 5, 6, 7, 10, 17, 19]

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let response = try await get("XML_STOPFINDER_REQUEST", [
            "type_sf": "any", "anyObjFilter_sf": "2", "name_sf": query,
        ])
        // Results are not ordered by match quality, and cover all of Germany (DELFI).
        return (response.locations ?? [])
            .filter { $0.type == "stop" && Self.servesSurface($0.productClasses) }
            .sorted { ($0.matchQuality ?? 0) > ($1.matchQuality ?? 0) }
            .prefix(30)
            .compactMap(\.stop)
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let response = try await get("XML_SERVINGLINES_REQUEST", [
            "type_sl": "stopID", "name_sl": stop.code, "mode": "odv",
        ])
        // The same id recurs once per destination a direction runs to (short workings); the main one
        // is the destination that ends the line's own description ("Killesberg - … - Westbahnhof").
        var byID: [String: DTO.Transportation] = [:]
        var order: [String] = []
        for line in response.lines ?? [] where Self.surfaceClasses.contains(line.product?.class ?? -1) {
            if let current = byID[line.id] {
                if !current.isMainVariant && line.isMainVariant { byID[line.id] = line }
            } else {
                byID[line.id] = line
                order.append(line.id)
            }
        }
        return order.compactMap { byID[$0]?.line(at: stop.code) }
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        try await patternAndShape(for: line).pattern
    }

    /// The geo object the pattern comes from also carries the line's path, so where it is drawn
    /// the shape costs no request of its own. A reply without one gives an empty shape, kept so
    /// the card does not ask again.
    func routePatternWithShape(for line: TransitLine) async throws -> (pattern: RoutePattern, shape: RouteShape?) {
        try await patternAndShape(for: line)
    }

    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        guard instance.drawsShapes else { throw TransitError.unsupported("route shapes") }
        guard let shape = try await patternAndShape(for: line).shape, !shape.isEmpty else {
            throw TransitError.notFound("shape of line \(line.id)")
        }
        return shape
    }

    /// The line's ordered stops from `XML_GEOOBJECT_REQUEST`, choosing the variant that calls at the
    /// rider's stop. When no variant does (a short working the geo object doesn't cover), the next
    /// trip of the line at that stop is fetched whole with `XML_STOPSEQCOORD_REQUEST`.
    ///
    /// The geo object's path is a heap of pieces, the union of the line's variants in no order;
    /// `EFAShape.stitch` threads the pattern's own way through them. A trip's path is one ordered
    /// line already.
    private func patternAndShape(for line: TransitLine) async throws -> (pattern: RoutePattern, shape: RouteShape?) {
        let stopCode = line.providerRefs["stop"]
        let response = try await get("XML_GEOOBJECT_REQUEST", ["line": line.id])
        let variants = (response.transportations ?? []).map {
            (stops: Self.patternStops($0.locationSequence ?? []), pieces: $0.coords ?? [])
        }
        var chosen = variants.first { variant in variant.stops.contains { $0.stop.code == stopCode } }
        var tripPath: [[Double]]?
        // Asked at most once per pattern: a trip that is not there now is not there a moment later.
        var askedForTrip = false
        if chosen == nil, let stopCode {
            askedForTrip = true
            if let trip = try? await tripPattern(line: line, stopCode: stopCode) {
                chosen = (trip.stops, [])
                tripPath = trip.coords
            }
        }
        guard let chosen = chosen ?? variants.max(by: { $0.stops.count < $1.stops.count }), chosen.stops.count >= 2 else {
            throw TransitError.notFound("stops of line \(line.id)")
        }
        let pattern = RoutePattern(line: line, stops: chosen.stops)
        guard instance.drawsShapes else { return (pattern, nil) }
        if let tripPath { return (pattern, RouteShape(EFAShape.points(tripPath))) }
        let stitched = EFAShape.stitch(chosen.pieces.map(EFAShape.points), stops: chosen.stops.map(\.stop.location))
        // Linz's geo object sometimes lists the stops of several variants in one run (tram 3's depot
        // branch after its terminus, both of 19's branches), which no bus calls at in that order.
        // Its path cannot serve such a list, so the next trip at the rider's stop is taken whole
        // instead: its own stops and its own path, two more requests for those lines only.
        if !askedForTrip,
           !ShapeCheck.verdict(RouteShape(stitched), stops: chosen.stops.map(\.stop.location), tolerance: shapeTolerance).passes,
           let stopCode, let trip = try? await tripPattern(line: line, stopCode: stopCode) {
            return (RoutePattern(line: line, stops: trip.stops), RouteShape(EFAShape.points(trip.coords)))
        }
        return (pattern, RouteShape(stitched))
    }

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }

    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let response = try await departures(of: line.id, at: stop.code, limit: 12)
        let cutoff = Date().addingTimeInterval(-60)
        return (response.stopEvents ?? [])
            .filter { $0.transportation?.id == line.id && !$0.isCancelledHere }
            .compactMap { event -> Arrival? in
                let planned = event.departureTimePlanned.flatMap(DTO.parseDate)
                let estimated = event.departureTimeEstimated.flatMap(DTO.parseDate)
                guard let expected = estimated ?? planned, expected >= cutoff else { return nil }
                return Arrival(
                    expectedAt: expected,
                    scheduledAt: planned,
                    isRealtime: estimated != nil && event.isRealtimeControlled == true,
                    tripId: event.transportation?.properties?.tripCode.map(String.init)
                )
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// `XML_COORD_REQUEST` finds the stops (nearest first, with distances); the lines of the closest
    /// few come from one serving-lines call each, in parallel.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let response = try await get("XML_COORD_REQUEST", [
            "coord": String(format: "%.6f:%.6f:WGS84[dd.ddddd]", point.lon, point.lat),
            "type_1": "STOP", "radius_1": String(Int(radiusMeters)), "inclFilter": "1", "max": "20",
        ])
        let stops = (response.locations ?? [])
            .filter { Self.servesSurface($0.productClasses) }
            .compactMap { location -> (TransitStop, Double)? in
                guard let stop = location.stop else { return nil }
                return (stop, location.properties?.distance ?? RouteGeometry.meters(point, stop.location))
            }
            .sorted { $0.1 < $1.1 }
            .prefix(8)
        return await withTaskGroup(of: NearbyStop?.self) { group in
            for (stop, distance) in stops {
                group.addTask {
                    guard let lines = try? await lines(atStop: stop), !lines.isEmpty else { return nil }
                    return NearbyStop(stop: stop, distanceMeters: distance, lines: lines)
                }
            }
            var result: [NearbyStop] = []
            for await stop in group { if let stop { result.append(stop) } }
            return result.sorted { $0.distanceMeters < $1.distanceMeters }
        }
    }

    // MARK: - Helpers

    /// The whole of the line's next trip at the stop (`tStOTType=all`, else only the stops after it),
    /// with its path.
    private func tripPattern(line: TransitLine, stopCode: String) async throws -> (stops: [PatternStop], coords: [[Double]])? {
        let monitor = try await departures(of: line.id, at: stopCode, limit: 1)
        guard let event = monitor.stopEvents?.first(where: { $0.transportation?.id == line.id }),
              let tripCode = event.transportation?.properties?.tripCode,
              let planned = event.departureTimePlanned.flatMap(DTO.parseDate) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = instance.timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: planned)
        let response = try await get("XML_STOPSEQCOORD_REQUEST", [
            "line": line.id, "tripCode": String(tripCode), "stopID": event.location?.parent?.id ?? stopCode,
            "date": String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
            "time": String(format: "%02d%02d", parts.hour ?? 0, parts.minute ?? 0),
            "tStOTType": "all",
        ])
        let stops = Self.patternStops(response.leg?.stopSequence ?? [])
        return stops.contains { $0.stop.code == stopCode } ? (stops, response.leg?.coords ?? []) : nil
    }

    private func departures(of lineID: String, at stopCode: String, limit: Int) async throws -> DTO.Response {
        try await get("XML_DM_REQUEST", [
            "type_dm": "stop", "name_dm": stopCode, "mode": "direct", "useRealtime": "1",
            "limit": String(limit), "line": lineID,
        ])
    }

    private func get(_ request: String, _ query: [String: String]) async throws -> DTO.Response {
        var query = query
        query["outputFormat"] = "rapidJSON"
        query["coordOutputFormat"] = "WGS84[dd.ddddd]"
        return try await http.get(DTO.Response.self, instance.base, "/" + request, query: query)
    }

    private static func servesSurface(_ classes: [Int]?) -> Bool {
        guard let classes else { return true }
        return !surfaceClasses.isDisjoint(with: classes)
    }

    /// Platforms collapse onto their stop area, so a line calling at two platforms of one stop in a
    /// row (VRR lists termini that way) counts once.
    private static func patternStops(_ locations: [DTO.Location]) -> [PatternStop] {
        var stops: [TransitStop] = []
        for location in locations {
            guard let stop = location.stop else { continue }
            if stops.last?.code == stop.code { continue }
            stops.append(stop)
        }
        return stops.enumerated().map { PatternStop(stop: $1, sequence: $0 + 1, distanceAlongRoute: nil) }
    }
}

nonisolated extension EFAProvider.Instance {
    static let badenWuerttemberg = Self(
        id: "efa-bw", displayName: "EFA-BW (Baden-Württemberg)", base: "https://www.efa-bw.de/nvbw",
        attribution: "Fahrplandaten: NVBW – Nahverkehrsgesellschaft Baden-Württemberg",
        timeZone: TimeZone(identifier: "Europe/Berlin")!
    )
    static let rheinRuhr = Self(
        id: "efa-vrr", displayName: "VRR (Rhine-Ruhr)", base: "https://efa.vrr.de/vrr",
        attribution: "Fahrplandaten: Verkehrsverbund Rhein-Ruhr (VRR)",
        timeZone: TimeZone(identifier: "Europe/Berlin")!
    )
    /// Open Government Data Linz, CC BY 4.0.
    static let linz = Self(
        id: "efa-linz", displayName: "LINZ AG LINIEN (Linz)", base: "https://www.linzag.at/linz2/efaAPI",
        attribution: "Datenquelle: LINZ AG LINIEN (CC BY 4.0)",
        timeZone: TimeZone(identifier: "Europe/Vienna")!,
        drawsShapes: true
    )
    /// Munich's MVV. Not a provider of its own: `MVGProvider` uses it for lines and patterns.
    static let munich = Self(
        id: "efa-mvv", displayName: "MVV (Munich)", base: "https://efa.mvv-muenchen.de/ng",
        attribution: nil,
        timeZone: TimeZone(identifier: "Europe/Berlin")!
    )
}

// MARK: - Wire format (rapidJSON)

private nonisolated enum DTO {
    /// The union of every request's top-level fields.
    struct Response: Decodable, Sendable {
        var locations: [Location]?
        var lines: [Transportation]?
        var transportations: [Transportation]?
        var stopEvents: [StopEvent]?
        var leg: Leg?
    }

    struct Leg: Decodable, Sendable {
        var stopSequence: [Location]?
        /// The trip's path in order, `[[lat, lon], …]`.
        var coords: [[Double]]?
    }

    struct Location: Decodable, Sendable {
        var id: String?
        var name: String?
        var disassembledName: String?
        var type: String?
        var coord: [Double]?
        var matchQuality: Int?
        var productClasses: [Int]?
        var properties: Properties?
        /// Platform → stop → locality.
        var parent: Parent?

        struct Properties: Decodable, Sendable {
            var distance: Double?
        }

        /// A platform resolves to the stop area above it, whose DHID is what the monitor takes.
        var stop: TransitStop? {
            guard let coord, coord.count == 2 else { return nil }
            let isPlatform = type == "platform" || type == "track"
            let area = isPlatform ? parent : nil
            guard let code = area?.id ?? id else { return nil }
            let locality = isPlatform ? parent?.parent?.name : parent?.name
            let fullName = area?.name ?? name ?? code
            let shortName = isPlatform ? nil : disassembledName
            return TransitStop(
                code: code,
                name: shortName ?? Self.strip(locality, from: fullName),
                city: locality,
                location: GeoPoint(lat: coord[0], lon: coord[1])
            )
        }

        /// "Linz/Donau Hauptplatz", "Stuttgart, Charlottenplatz" → "Hauptplatz", "Charlottenplatz".
        static func strip(_ locality: String?, from name: String) -> String {
            guard let locality, name.hasPrefix(locality) else { return name }
            let rest = name.dropFirst(locality.count).drop { $0 == "," || $0 == " " }
            return rest.isEmpty ? name : String(rest)
        }
    }

    struct Parent: Decodable, Sendable {
        var id: String?
        var name: String?
        var type: String?
        var parent: Locality?
    }

    struct Locality: Decodable, Sendable {
        var name: String?
    }

    struct Transportation: Decodable, Sendable {
        var id: String
        var name: String?
        var disassembledName: String?
        var number: String?
        var description: String?
        var product: Product?
        var `operator`: Named?
        var destination: Named?
        var properties: Properties?
        var locationSequence: [Location]?
        /// The geo object's path: pieces of `[[lat, lon], …]` (see `EFAShape`).
        var coords: [[[Double]]]?

        struct Product: Decodable, Sendable { var `class`: Int? }
        struct Named: Decodable, Sendable { var name: String? }
        struct Properties: Decodable, Sendable { var tripCode: Int? }

        /// "Killesberg - Hauptbahnhof - Westbahnhof" → its ends.
        private var ends: [String] {
            (description ?? "").components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        var isMainVariant: Bool { destination?.name != nil && destination?.name == ends.last }

        func line(at stopCode: String) -> TransitLine {
            TransitLine(
                id: id,
                shortName: number ?? disassembledName ?? name ?? id,
                headsign: destination?.name,
                agency: `operator`?.name,
                origin: ends.count > 1 ? ends.first : nil,
                destination: destination?.name ?? ends.last,
                providerRefs: ["stop": stopCode]
            )
        }
    }

    struct StopEvent: Decodable, Sendable {
        var location: Location?
        var departureTimePlanned: String?
        var departureTimeEstimated: String?
        var isRealtimeControlled: Bool?
        var isCancelled: Bool?
        /// "MONITORED", or a cancellation: some hosts flag one only here, never in `isCancelled`.
        var realtimeStatus: [String]?
        var transportation: Transportation?

        /// The trip is cancelled, or skips this stop.
        var isCancelledHere: Bool {
            isCancelled == true || (realtimeStatus ?? []).contains(where: Self.cancelled.contains)
        }

        private static let cancelled: Set<String> = ["TRIP_CANCELLED", "DEPARTURE_CANCELLED", "STOP_CANCELLED"]
    }

    /// "2026-09-22T12:33:00Z".
    static func parseDate(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }
}
