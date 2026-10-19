import Foundation

/// France — STAR, the Rennes Métropole network run by Keolis Rennes, through its Opendatasoft
/// portal (data.explore.star.fr, Explore API v2.1). Official and keyless; anonymous callers get
/// 20,000 calls a day per IP. Data is ODbL: attribute "Données STAR / Keolis Rennes".
///
/// The realtime datasets identify a trip only by line and direction (`sens`), never by route
/// variant (`parcours`), so a `TransitLine` here is one line in one direction, and the variant
/// that serves the rider's stop (the main one when it does) is kept for drawing the pattern.
/// The whole stop list (1.8k stops, ~320 KB of JSON, ~47 KB gzipped) is cached once per session
/// for name search, nearby and the coordinates of pattern stops.
nonisolated struct STARRennesProvider: TransitProvider {
    let id = "star-rennes"
    let displayName = "STAR (Rennes)"
    let attribution: String? = "Données STAR / Keolis Rennes (ODbL)"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .scheduledArrivals, .nearbyStops, .routeShape,
    ]
    /// Vehicle and passage datasets are re-extracted about once a minute.
    let suggestedRefreshInterval: Duration = .seconds(30)

    var http = HTTPClient()

    private let base = "https://data.explore.star.fr/api/explore/v2.1/catalog/datasets"
    private static let store = STARStore()

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let index = try await stops()
        if query.allSatisfy(\.isNumber) {
            return [index.byID[query]].compactMap { $0 }
        }
        let tokens = STARStops.fold(query).split(separator: " ").map(String.init)
        let folded = STARStops.fold(query)
        return index.all
            .filter { entry in tokens.allSatisfy { entry.key.contains($0) } }
            .sorted { a, b in
                let ap = a.key.hasPrefix(folded), bp = b.key.hasPrefix(folded)
                return ap != bp ? ap : (a.stop.name, a.stop.code) < (b.stop.name, b.stop.code)
            }
            .prefix(50)
            .map(\.stop)
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let calls = try await http.get([DTO.Desserte].self, base, "/tco-bus-topologie-dessertes-td/exports/json", query: [
            "where": "idarret=\(Self.quoted(stop.code))",
            "select": "idparcours,idligne,nomcourtligne",
        ])
        guard !calls.isEmpty else { return [] }
        let variants = try await http.get([DTO.Parcours].self, base, "/tco-bus-topologie-parcours-td/exports/json", query: [
            "where": "id in (\(Set(calls.map(\.idparcours)).map(Self.quoted).joined(separator: ",")))",
            "select": "id,idligne,nomcourtligne,sens,type,nomarretdepart,nomarretarrivee,estaccessiblepmr",
        ])
        // One line per (line, direction); prefer the main variant, then the one listed first.
        let grouped = Dictionary(grouping: variants) { STARLineKey(idligne: $0.idligne, sens: $0.sens) }
        return grouped.values
            .compactMap { group in group.first { $0.type == "Principal" } ?? group.sorted { $0.id < $1.id }.first }
            .map(\.line)
            .sorted { ($0.shortName.count, $0.shortName, $0.id) < ($1.shortName.count, $1.shortName, $1.id) }
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        guard let parcours = line.providerRefs["parcours"] else {
            throw TransitError.unsupported("line \(line.id) has no parcours (was it loaded from another provider?)")
        }
        let index = try await stops()
        let calls = try await http.get([DTO.PatternCall].self, base, "/tco-bus-topologie-dessertes-td/exports/json", query: [
            "where": "idparcours=\(Self.quoted(parcours))",
            "select": "idarret,ordre",
            "order_by": "ordre",
        ])
        let stops = calls.sorted { $0.ordre < $1.ordre }.compactMap { call -> PatternStop? in
            guard let stop = index.byID[call.idarret] else { return nil }
            return PatternStop(stop: stop, sequence: call.ordre, distanceAlongRoute: nil)
        }
        guard !stops.isEmpty else { throw TransitError.notFound("stops for parcours \(parcours)") }
        return RoutePattern(line: line, stops: stops)
    }

    /// The variant's own trace from the topology dataset (`parcours`, GeoJSON): one call, for the
    /// variant the line already names. It lives beside the stop list rather than in it, and asking
    /// for it with the lines at a stop would download every variant's trace on each stop opened.
    /// `datedebutversion` marks the topology version it belongs to.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        guard let parcours = line.providerRefs["parcours"] else {
            throw TransitError.unsupported("line \(line.id) has no parcours (was it loaded from another provider?)")
        }
        let response = try await http.get(DTO.Page<DTO.Trace>.self, base, "/tco-bus-topologie-parcours-td/records", query: [
            "where": "id=\(Self.quoted(parcours))",
            "select": "id,datedebutversion,parcours",
            "limit": "1",
        ])
        guard let trace = response.results.first, let branches = trace.parcours?.geometry?.branches, !branches.isEmpty else {
            throw TransitError.notFound("trace of parcours \(parcours)")
        }
        return RouteShape(branches: ShapeCheck.chained(branches), version: trace.datedebutversion)
    }

    /// Positions only (no fix time, no trip id); `ecartsecondes` is the delay, not the age.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let key = try STARLineKey(line)
        let response = try await http.get(DTO.Page<DTO.Vehicle>.self, base, "/tco-bus-vehicules-position-tr/records", query: [
            "where": "idligne=\(Self.quoted(key.idligne)) and sens=\(key.sens)",
            "limit": "100",
        ])
        return response.results
            .filter { $0.etat?.contains("En ligne") ?? true }
            .compactMap { vehicle in
                vehicle.coordonnees.map { VehiclePosition(location: GeoPoint(lat: $0.lat, lon: $0.lon)) }
            }
    }

    /// `precision` says whether a passage is "Temps réel" or "Applicable" (timetable only).
    /// Departure times are used: at a line's first stop `arrivee` is when the bus pulled in to lay
    /// over, often 10–30 minutes before it leaves; everywhere else the two are the same.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let key = try STARLineKey(line)
        let response = try await http.get(DTO.Page<DTO.Passage>.self, base, "/tco-bus-circulation-passages-tr/records", query: [
            "where": "idarret=\(Self.quoted(stop.code)) and idligne=\(Self.quoted(key.idligne)) and sens=\(key.sens)",
            "order_by": "depart",
            "limit": "20",
        ])
        let cutoff = Date().addingTimeInterval(-60)
        return response.results
            .compactMap { passage -> Arrival? in
                guard let expected = (passage.depart ?? passage.arrivee).flatMap(DTO.parse), expected >= cutoff else { return nil }
                return Arrival(
                    expectedAt: expected,
                    scheduledAt: (passage.departtheorique ?? passage.arriveetheorique).flatMap(DTO.parse),
                    isRealtime: passage.precision == "Temps réel",
                    tripId: passage.idcourse
                )
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// Stops come from the cached list; their lines from one `dessertes` query for all of them.
    /// Those lines carry number and direction only — `lines(atStop:)` fills in the rest.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let index = try await stops()
        let near = index.all
            .map { ($0.stop, RouteGeometry.meters(point, $0.stop.location)) }
            .filter { $0.1 <= radiusMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(30)
        guard !near.isEmpty else { return [] }
        let calls = try await http.get([DTO.Desserte].self, base, "/tco-bus-topologie-dessertes-td/exports/json", query: [
            "where": "idarret in (\(near.map { Self.quoted($0.0.code) }.joined(separator: ",")))",
            "select": "idarret,idparcours,idligne,nomcourtligne",
        ])
        let byStop = Dictionary(grouping: calls) { $0.idarret ?? "" }
        return near.map { stop, distance in
            var seen = Set<String>()
            let lines = (byStop[stop.code] ?? [])
                .sorted { $0.idparcours < $1.idparcours }
                .compactMap(\.line)
                .filter { seen.insert($0.id).inserted }
            return NearbyStop(stop: stop, distanceMeters: distance, lines: lines)
        }
    }

    // MARK: - Helpers

    private func stops() async throws -> STARStops {
        try await Self.store.stops { [http, base] in
            let stops = try await http.get([DTO.Stop].self, base, "/tco-bus-topologie-pointsarret-td/exports/json", query: [
                "select": "id,nom,nomcommune,coordonnees",
            ])
            return STARStops(stops.compactMap(\.stop))
        }
    }

    /// ODSQL string literal.
    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Session cache

private actor STARStore {
    private var task: Task<STARStops, any Error>?

    func stops(_ load: @escaping @Sendable () async throws -> STARStops) async throws -> STARStops {
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

private nonisolated struct STARStops: Sendable {
    struct Entry: Sendable {
        var stop: TransitStop
        var key: String
    }

    let all: [Entry]
    let byID: [String: TransitStop]

    init(_ stops: [TransitStop]) {
        all = stops.map { Entry(stop: $0, key: Self.fold([$0.name, $0.city ?? ""].joined(separator: " "))) }
        byID = Dictionary(stops.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// A line in one direction: `TransitLine.id` is "<idligne>-<sens>", e.g. "0001-0" (C1 outbound).
private nonisolated struct STARLineKey: Hashable, Sendable {
    var idligne: String
    var sens: Int

    init(idligne: String, sens: Int) {
        self.idligne = idligne
        self.sens = sens
    }

    init(_ line: TransitLine) throws {
        let parts = line.id.split(separator: "-")
        guard parts.count == 2, let sens = Int(parts[1]) else {
            throw TransitError.badResponse("line id \(line.id) is not a STAR line-direction")
        }
        self.init(idligne: String(parts[0]), sens: sens)
    }

    var id: String { "\(idligne)-\(sens)" }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct Page<T: Decodable & Sendable>: Decodable, Sendable {
        var results: [T]
    }

    struct Coordinates: Decodable, Sendable {
        var lat: Double
        var lon: Double
    }

    struct Stop: Decodable, Sendable {
        var id: String
        var nom: String?
        var nomcommune: String?
        var coordonnees: Coordinates?

        var stop: TransitStop? {
            coordonnees.map {
                TransitStop(code: id, name: nom ?? id, city: nomcommune, location: GeoPoint(lat: $0.lat, lon: $0.lon))
            }
        }
    }

    /// A stop served by a route variant.
    struct Desserte: Decodable, Sendable {
        var idarret: String?
        var idparcours: String
        var idligne: String?
        var nomcourtligne: String?

        /// Variant ids read "<idligne>-<A|B>-<from>-<to>…"; A is `sens` 0, B is `sens` 1.
        var line: TransitLine? {
            let parts = idparcours.split(separator: "-")
            guard parts.count >= 2, let idligne = idligne ?? parts.first.map(String.init) else { return nil }
            let sens: Int
            switch parts[1] {
            case "A": sens = 0
            case "B": sens = 1
            default: return nil
            }
            return TransitLine(
                id: STARLineKey(idligne: idligne, sens: sens).id,
                shortName: nomcourtligne ?? idligne,
                agency: "STAR",
                providerRefs: ["parcours": idparcours]
            )
        }
    }

    struct Parcours: Decodable, Sendable {
        var id: String
        var idligne: String
        var nomcourtligne: String?
        var sens: Int
        var type: String?
        var nomarretdepart: String?
        var nomarretarrivee: String?
        var estaccessiblepmr: String?

        var line: TransitLine {
            TransitLine(
                id: STARLineKey(idligne: idligne, sens: sens).id,
                shortName: nomcourtligne ?? idligne,
                headsign: nomarretarrivee,
                agency: "STAR",
                origin: nomarretdepart,
                destination: nomarretarrivee,
                isAccessible: estaccessiblepmr.map { $0.lowercased() == "oui" },
                providerRefs: ["parcours": id]
            )
        }
    }

    /// A variant's trace: a GeoJSON Feature whose LineString is `[lon, lat]` pairs.
    struct Trace: Decodable, Sendable {
        struct Feature: Decodable, Sendable { var geometry: GeoJSONLine? }
        var id: String
        var datedebutversion: String?
        var parcours: Feature?
    }

    /// A LineString, or a MultiLineString read as its pieces.
    struct GeoJSONLine: Decodable, Sendable {
        var branches: [[GeoPoint]]

        private enum CodingKeys: String, CodingKey { case coordinates }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let pieces: [[[Double]]]
            if let line = try? container.decode([[Double]].self, forKey: .coordinates) {
                pieces = [line]
            } else {
                pieces = try container.decode([[[Double]]].self, forKey: .coordinates)
            }
            branches = pieces.map { $0.compactMap { $0.count >= 2 ? GeoPoint(lat: $0[1], lon: $0[0]) : nil } }
        }
    }

    struct PatternCall: Decodable, Sendable {
        var idarret: String
        var ordre: Int
    }

    struct Vehicle: Decodable, Sendable {
        var etat: [String]?
        var coordonnees: Coordinates?
    }

    struct Passage: Decodable, Sendable {
        var arriveetheorique: String?
        var departtheorique: String?
        var arrivee: String?
        var depart: String?
        var idcourse: String?
        var precision: String?
    }

    /// Times carry their offset: "2026-09-22T09:36:15+00:00".
    static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
