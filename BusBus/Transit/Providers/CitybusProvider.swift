import Foundation

/// Hong Kong — Citybus (which absorbed NWFB in 2023), the government ETA API on rt.data.gov.hk
/// (via DATA.GOV.HK). Keyless, no published rate limit; predictions refresh about every minute.
///
/// ARRIVALS ONLY, and ROUTE-FIRST: Citybus publishes predicted times per stop but no bus positions,
/// and — unlike KMB — has no list of all stops and no "routes at this stop" call. The only lists are
/// the routes (`/route/ctb`, ~110 KB, fetched once per session) and each route's stops by direction
/// (`/route-stop/ctb/{route}/{outbound|inbound}`, ~2 KB), with names and coordinates one stop at a time
/// (`/stop/{id}`, ~300 B). Indexing the whole network would take ~3,000 calls, so search works from
/// routes instead:
/// - a route number ("1", "A11", "E23") lists every stop of both directions of that route;
/// - anything else matches route termini ("Happy Valley") and lists the stops, on up to four such
///   routes, whose name contains the query.
/// Every route loaded that way is remembered for the session, and `lines(atStop:)` answers from that
/// memory — so the lines offered at a stop are those of the routes the rider searched through. There
/// is no nearby-stops support for the same reason. Six-digit stop ids exist but are not on signs.
///
/// Names follow the app language (`HKNameLanguage`): English, or the `*_tc` / `*_sc` fields every
/// record also carries. The session caches keep all three, and search matches any of them.
nonisolated struct CitybusProvider: TransitProvider {
    let id = "hk-citybus"
    /// Lines and patterns are cached with their names baked in, so each name language is its own dataset.
    var datasetID: String { "\(id).\(HKNameLanguage.current.rawValue)" }
    let displayName = "Citybus (Hong Kong)"
    let attribution: String? = "Data: Citybus Limited / DATA.GOV.HK; route lines: Transport Department / CSDI Portal"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .linesAtStop, .routePattern, .realtimeArrivals, .scheduledArrivals, .routeShape,
    ]
    let suggestedRefreshInterval: Duration = .seconds(30)

    var http = HTTPClient()

    private let base = "https://rt.data.gov.hk/v2/transport/citybus"
    private static let store = CitybusStore()
    /// A terminus-name query ("Central") can match dozens of routes; each costs ~40 stop lookups.
    private static let placeRouteLimit = 4
    /// Parallel `/stop/{id}` lookups at a time, per route direction.
    private static let stopFanOut = 6

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let language = HKNameLanguage.current
        let routes = try await routeList()

        if let route = routes.first(where: { $0.route.caseInsensitiveCompare(query) == .orderedSame }) {
            return try await stops(of: [route.route]).uniqued().map { $0.stop(in: language) }
        }

        let matched = routes
            .filter { [$0.orig_en, $0.dest_en, $0.orig_tc, $0.dest_tc, $0.orig_sc, $0.dest_sc]
                .contains { $0?.localizedCaseInsensitiveContains(query) == true } }
            .prefix(Self.placeRouteLimit)
            .map(\.route)
        return try await stops(of: matched)
            .filter { $0.matches(query) }
            .uniqued()
            .map { $0.stop(in: language) }
    }

    /// Both directions of each route, loaded side by side, concatenated in the order asked.
    private func stops(of routes: [String]) async throws -> [CitybusStop] {
        let keys = routes.flatMap { route in Direction.allCases.map { LineRef(route: route, direction: $0) } }
        return try await withThrowingTaskGroup(of: (Int, [CitybusStop]).self) { group in
            for (index, ref) in keys.enumerated() {
                group.addTask { (index, try await stops(route: ref.route, ref.direction)) }
            }
            var loaded: [Int: [CitybusStop]] = [:]
            for try await (index, stops) in group { loaded[index] = stops }
            return keys.indices.flatMap { loaded[$0] ?? [] }
        }
    }

    /// Lines, among the routes loaded this session, that call at the stop — minus a direction that ends
    /// there. A stop reached by a six-digit id alone, before any search, knows no lines yet.
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let routes = Dictionary(try await routeList().map { ($0.route, $0) }, uniquingKeysWith: { first, _ in first })
        let loaded = await Self.store.loadedPatterns()
        let language = HKNameLanguage.current
        let lines = loaded
            .filter { _, ids in
                guard let index = ids.lastIndex(of: stop.code) else { return false }
                return index < ids.count - 1 || ids.first == stop.code   // a loop's last stop is its first
            }
            .keys
            .compactMap { key -> TransitLine? in
                guard let ref = LineRef(id: key), let route = routes[ref.route] else { return nil }
                let outbound = ref.direction == .outbound
                let orig = language.pick(en: route.orig_en, tc: route.orig_tc, sc: route.orig_sc)
                let dest = language.pick(en: route.dest_en, tc: route.dest_tc, sc: route.dest_sc)
                let origin = outbound ? orig : dest
                let destination = outbound ? dest : orig
                return TransitLine(
                    id: key, shortName: route.route, headsign: destination, agency: "Citybus",
                    origin: origin, destination: destination,
                    providerRefs: ["route": route.route, "dir": ref.direction.code]
                )
            }
            .sorted { ($0.shortName.count, $0.shortName, $0.id) < ($1.shortName.count, $1.shortName, $1.id) }
        guard !lines.isEmpty else {
            throw TransitError.notFound("Citybus lines at stop \(stop.code) — search by route number first")
        }
        return lines
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        guard let ref = LineRef(id: line.id) else {
            throw TransitError.unsupported("line \(line.id) has no Citybus route/direction (was it loaded from another provider?)")
        }
        let stops = try await stops(route: ref.route, ref.direction)
        guard stops.count >= 2 else { throw TransitError.notFound("stops for Citybus line \(line.id)") }
        let language = HKNameLanguage.current
        return RoutePattern(line: line, stops: stops.enumerated().map {
            PatternStop(stop: $0.element.stop(in: language), sequence: $0.offset + 1, distanceAlongRoute: nil)
        })
    }

    /// A shape has no names in it.
    var shapeDatasetID: String { id }

    /// A direction's stop list merges TD's variants, and once in a while lists a stop TD drew no
    /// variant past (route 11 inbound's Ice House Street stop, 131 m off): that stop is let stand
    /// beside the line rather than losing the whole map.
    var shapeTolerance: ShapeTolerance { ShapeTolerance(stops: HKRouteLines.missReach, ends: 150) }

    /// TD's drawn line (`HKRouteLines`): one query answers both directions of the route number. A
    /// circular route is one loop there and two halves here, so the loop is cut to the half; a
    /// direction merging two variants gets both as branches; up to two stops on no drawn variant
    /// stay markers beside the line.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        guard let ref = LineRef(id: line.id) else {
            throw TransitError.unsupported("line \(line.id) has no Citybus route/direction (was it loaded from another provider?)")
        }
        // Citybus alone, and the routes it runs jointly with KMB or Long Win.
        return try await HKRouteLines.shape(route: ref.route, company: "COMPANY_CODE LIKE '%CTB%'", pattern: pattern,
                                            misses: 2, http: http)
    }

    /// Citybus publishes no vehicle positions.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }

    /// `eta/ctb/{stop}/{route}` answers both directions; the other one is dropped. It also answers every
    /// visit (`seq`) of the route to the stop: at a loop's first stop (S1, S56) the buses finishing the
    /// loop there come back too, so only the first visit is kept. The feed has no
    /// "scheduled" flag, but at a route's first stop the times are whole-minute timetable departures
    /// (no bus is tracked before it leaves), so those are reported as not realtime. A null or empty
    /// `eta` means no service.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        guard let ref = LineRef(id: line.id) else {
            throw TransitError.unsupported("line \(line.id) has no Citybus route/direction (was it loaded from another provider?)")
        }
        let response = try await http.get(DTO.List<DTO.ETA>.self, base, "/eta/ctb/\(stop.code)/\(ref.route)")
        let visits = (response.data ?? []).filter { $0.dir == ref.direction.code }
        let firstVisit = visits.compactMap(\.seq).min()
        return visits
            .filter { $0.seq == firstVisit }
            .compactMap { eta -> Arrival? in
                guard let text = eta.eta, !text.isEmpty, let expected = HKTime.parse(text) else { return nil }
                let scheduled = eta.seq == 1 || (eta.rmk_en ?? "").localizedCaseInsensitiveContains("scheduled")
                return Arrival(expectedAt: expected, scheduledAt: nil, isRealtime: !scheduled, tripId: nil, vehicleLocation: nil)
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    // MARK: - Loading

    private func routeList() async throws -> [DTO.Route] {
        try await Self.store.routes.value("routes", ttl: nil) { [http, base] in
            try await http.get(DTO.List<DTO.Route>.self, base, "/route/ctb").data ?? []
        }
    }

    /// Stops of one route direction, in travel order, with names and coordinates. Remembered for the
    /// session, which is what `lines(atStop:)` answers from.
    private func stops(route: String, _ direction: Direction) async throws -> [CitybusStop] {
        let key = LineRef(route: route, direction: direction).id
        return try await Self.store.patterns.value(key, ttl: nil) { [http, base] in
            let rows = try await http.get(DTO.List<DTO.RouteStop>.self, base, "/route-stop/ctb/\(route)/\(direction.rawValue)").data ?? []
            let ids = rows.sorted { $0.seq < $1.seq }.map(\.stop)
            let details = await Self.stopDetails(Array(Set(ids)), http: http, base: base)
            let stops = ids.compactMap { details[$0] }
            await Self.store.remember(key, ids: stops.map(\.code))
            return stops
        }
    }

    /// Unknown or malformed ids are skipped rather than failing the whole route.
    private static func stopDetails(_ ids: [String], http: HTTPClient, base: String) async -> [String: CitybusStop] {
        await withTaskGroup(of: CitybusStop?.self) { group in
            var result: [String: CitybusStop] = [:]
            var pending = ids[...]
            func next() {
                guard let id = pending.popFirst() else { return }
                group.addTask { try? await stopDetail(id, http: http, base: base) }
            }
            for _ in 0..<stopFanOut { next() }
            while let stop = await group.next() {
                if let stop { result[stop.code] = stop }
                next()
            }
            return result
        }
    }

    private static func stopDetail(_ id: String, http: HTTPClient, base: String) async throws -> CitybusStop {
        try await store.stops.value(id, ttl: nil) {
            let stop = try await http.get(DTO.One<DTO.Stop>.self, base, "/stop/\(id)").data
            guard let stop, let lat = Double(stop.lat), let lon = Double(stop.long) else {
                throw TransitError.notFound("Citybus stop \(id)")
            }
            return CitybusStop(code: stop.stop, location: GeoPoint(lat: lat, lon: lon),
                               nameEN: stop.name_en, nameTC: stop.name_tc, nameSC: stop.name_sc)
        }
    }
}

/// A stop with its name in all three languages, so the session cache serves any app language.
private nonisolated struct CitybusStop: Sendable {
    var code: String
    var location: GeoPoint
    var nameEN: String?
    var nameTC: String?
    var nameSC: String?

    func stop(in language: HKNameLanguage) -> TransitStop {
        TransitStop(code: code, name: language.pick(en: nameEN, tc: nameTC, sc: nameSC) ?? code, city: nil, location: location)
    }

    func matches(_ query: String) -> Bool {
        [nameEN, nameTC, nameSC].contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}

private nonisolated extension Array where Element == CitybusStop {
    func uniqued() -> [CitybusStop] {
        var seen = Set<String>()
        return filter { seen.insert($0.code).inserted }
    }
}

private nonisolated enum Direction: String, CaseIterable, Sendable {
    case outbound, inbound
    /// The `dir` field of route-stop and ETA records.
    var code: String { self == .outbound ? "O" : "I" }
}

/// `TransitLine.id` is "route|O" or "route|I", e.g. "1|I".
private nonisolated struct LineRef: Sendable {
    var route: String
    var direction: Direction

    init(route: String, direction: Direction) { (self.route, self.direction) = (route, direction) }

    init?(id: String) {
        let parts = id.split(separator: "|").map(String.init)
        guard parts.count == 2, let direction = Direction.allCases.first(where: { $0.code == parts[1] }) else { return nil }
        (route, self.direction) = (parts[0], direction)
    }

    var id: String { "\(route)|\(direction.code)" }
}

// MARK: - Session cache

private actor CitybusStore {
    let routes = Memo<[DTO.Route]>()
    let patterns = Memo<[CitybusStop]>()
    let stops = Memo<CitybusStop>()
    /// Line id → its stop ids in order, for every route direction loaded so far.
    private var loaded: [String: [String]] = [:]

    func remember(_ key: String, ids: [String]) { loaded[key] = ids }
    func loadedPatterns() -> [String: [String]] { loaded }
}

/// Coalesces concurrent loads of the same key and keeps the result for `ttl` (forever when nil).
/// Failures are not kept.
private actor Memo<Value: Sendable> {
    private var entries: [String: (at: ContinuousClock.Instant, task: Task<Value, any Error>)] = [:]

    func value(_ key: String, ttl: Duration?, _ load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let now = ContinuousClock.now
        if let entry = entries[key], ttl.map({ now - entry.at < $0 }) ?? true {
            return try await entry.task.value
        }
        if let ttl { entries = entries.filter { now - $0.value.at < ttl } }
        let task = Task { try await load() }
        entries[key] = (now, task)
        do {
            return try await task.value
        } catch {
            if entries[key]?.task == task { entries[key] = nil }
            throw error
        }
    }
}

/// Timestamps carry their offset ("2026-09-22T17:35:00+08:00"), so no zone guessing is needed.
private nonisolated enum HKTime {
    static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct List<T: Decodable & Sendable>: Decodable, Sendable { var data: [T]? }
    struct One<T: Decodable & Sendable>: Decodable, Sendable { var data: T? }

    /// `orig`/`dest` are the outbound termini; inbound runs the other way.
    struct Route: Decodable, Sendable {
        var route: String
        var orig_en: String?
        var dest_en: String?
        var orig_tc: String?
        var dest_tc: String?
        var orig_sc: String?
        var dest_sc: String?
    }

    struct RouteStop: Decodable, Sendable {
        var seq: Int
        var stop: String
    }

    /// Coordinates come as strings. An unknown id answers `"data": {}`.
    struct Stop: Decodable, Sendable {
        var stop: String
        var name_en: String?
        var name_tc: String?
        var name_sc: String?
        var lat: String
        var long: String
    }

    struct ETA: Decodable, Sendable {
        var dir: String?
        var seq: Int?
        var eta: String?
        var eta_seq: Int?
        var rmk_en: String?
    }
}
