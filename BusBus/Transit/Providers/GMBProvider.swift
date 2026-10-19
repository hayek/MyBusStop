import Foundation

/// Hong Kong — green minibuses (GMB), the Transport Department's ETA API on data.etagmb.gov.hk (via
/// DATA.GOV.HK). Keyless, no published rate limit; every one of the ~550 GMB routes is covered.
///
/// ARRIVALS ONLY, and ROUTE-FIRST: GMB publishes predicted times per stop but no minibus positions, and
/// has no list of all stops and no search. Its lists are the route codes by region (`/route`, ~5 KB,
/// once per session), a route's variants and directions (`/route/{region}/{code}`, ~5 KB) and each
/// direction's stops with their names (`/route-stop/{route_id}/{route_seq}`, ~2 KB), with coordinates
/// one stop at a time (`/stop/{id}`, ~370 B). An all-stops dump exists only as the Transport
/// Department's 20 MB GeoJSON, too big for a phone, so search works from routes, like Citybus:
/// - a route code ("1", "12A", or "NT 1A" for one region) lists every stop of every variant and
///   direction of that route;
/// - anything else matches route termini ("Sai Kung") and lists the stops, on up to four such route
///   directions, whose name contains the query. The termini come from the same dataset's route layer
///   on the CSDI portal (every direction's first and last stop, ~50 KB gzipped, once per session).
/// Unlike Citybus, `/stop-route/{id}` names every route calling at a stop, so the lines offered at a
/// stop never depend on what was searched. There is no nearby-stops support: no endpoint takes a point.
///
/// Route codes repeat across the three regions (HKI, KLN, NT — NT 1 and HKI 1 are unrelated), so a
/// line is the `route_id` of one variant plus its `route_seq` (1 or 2; a circular route has only 1).
/// Stop ids are eight digits with no public meaning; one searched as a whole finds that stop.
///
/// Names follow the app language (`HKNameLanguage`): English, or the `*_tc` / `*_sc` fields every
/// record also carries. The session caches keep all three, and search matches any of them.
nonisolated struct GMBProvider: TransitProvider {
    let id = "hk-gmb"
    /// Lines and patterns are cached with their names baked in, so each name language is its own dataset.
    var datasetID: String { "\(id).\(HKNameLanguage.current.rawValue)" }
    let displayName = "Green Minibus (Hong Kong)"
    let attribution: String? = "Data: Transport Department / DATA.GOV.HK / CSDI Portal"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .linesAtStop, .routePattern, .realtimeArrivals, .scheduledArrivals, .routeShape,
    ]
    let suggestedRefreshInterval: Duration = .seconds(30)

    var http = HTTPClient()

    private static let base = "https://data.etagmb.gov.hk"
    /// The GMB route layer of the same dataset, served by the CSDI portal's ArcGIS server.
    private let terminiURL = HKRouteLines.minibusLayer
    private static let store = GMBStore()
    private static let regions = ["HKI", "KLN", "NT"]
    /// A terminus-name query ("Central") can match dozens of route directions; each costs ~20 stop lookups.
    private static let placeRouteLimit = 4
    /// Parallel lookups at a time (`/stop/{id}`, `/route/{id}`). Kept low: the API answers a burst
    /// from one address with 429 "Too Many Requests".
    private static let fanOut = 3

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let language = HKNameLanguage.current

        if query.count == 8, query.allSatisfy(\.isASCII), query.allSatisfy(\.isNumber) {
            return [try await stop(id: query).stop(in: language)]
        }

        let routes = try await routeList()
        let words = query.split(separator: " ", maxSplits: 1).map(String.init)
        let region = words.count == 2 ? Self.regions.first { $0.caseInsensitiveCompare(words[0]) == .orderedSame } : nil
        let code = region == nil ? query : words[1]
        let codes = (region.map { [$0] } ?? Self.regions).flatMap { region in
            (routes[region] ?? []).filter { $0.caseInsensitiveCompare(code) == .orderedSame }.map { (region, $0) }
        }
        if !codes.isEmpty {
            var directions: [LineRef] = []
            for (region, code) in codes {
                directions += try await variants(region: region, code: code).flatMap { route in
                    route.directions.map { LineRef(routeID: route.route_id, seq: $0.route_seq) }
                }
            }
            return try await stops(of: directions).uniqued().map { $0.stop(in: language) }
        }

        // The termini are a nicety on top of the ETA API: without them a place name just finds nothing.
        let matched = ((try? await termini()) ?? [])
            .filter { [$0.ST_STOP_NAMEE, $0.ST_STOP_NAMEC, $0.ST_STOP_NAMES, $0.ED_STOP_NAMEE, $0.ED_STOP_NAMEC, $0.ED_STOP_NAMES]
                .contains { $0?.localizedCaseInsensitiveContains(query) == true } }
            .prefix(Self.placeRouteLimit)
            .map { LineRef(routeID: $0.ROUTE_ID, seq: $0.ROUTE_SEQ) }
        return try await stops(of: Array(matched))
            .filter { $0.matches(query) }
            .uniqued()
            .map { $0.stop(in: language) }
    }

    /// Every route direction calling at the stop, minus those that end there (nobody boards a minibus at
    /// its last stop; a loop's last stop is its first).
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let calls = try await Self.get(DTO.List<DTO.StopRoute>.self, http, "/stop-route/\(stop.code)").data ?? []
        let refs = calls.map { LineRef(routeID: $0.route_id, seq: $0.route_seq) }.uniqued()
        // One route or stop list that will not load drops that line, not the whole stop.
        async let routes = Self.map(Array(Set(refs.map(\.routeID)))) { [self] id in try? await route(id: id) }
        async let patterns = Self.map(refs) { [self] ref in (ref, try? await rows(ref)) }
        let (info, lists) = try await (routes, patterns)
        let byID = Dictionary(info.compactMap { $0 ?? nil }.map { ($0.route_id, $0) }, uniquingKeysWith: { first, _ in first })
        let endsHere = Set(lists.compactMap { $0 }.compactMap { ref, rows -> LineRef? in
            guard let last = rows?.last?.stop_id, let first = rows?.first?.stop_id else { return nil }
            return String(last) == stop.code && String(first) != stop.code ? ref : nil
        })
        let language = HKNameLanguage.current
        let lines = refs
            .filter { !endsHere.contains($0) }
            .compactMap { ref -> TransitLine? in
                guard let route = byID[ref.routeID] else { return nil }
                return Self.line(route, ref, language: language)
            }
            .sorted { ($0.shortName.count, $0.shortName, $0.id) < ($1.shortName.count, $1.shortName, $1.id) }
        guard !lines.isEmpty else { throw TransitError.notFound("GMB lines at stop \(stop.code)") }
        return lines
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        guard let ref = LineRef(id: line.id) else {
            throw TransitError.unsupported("line \(line.id) has no GMB route id/sequence (was it loaded from another provider?)")
        }
        let stops = try await stops(ref)
        guard stops.count >= 2 else { throw TransitError.notFound("stops for GMB line \(line.id)") }
        let language = HKNameLanguage.current
        return RoutePattern(line: line, stops: stops.map {
            PatternStop(stop: $0.stop(in: language), sequence: $0.sequence, distanceAlongRoute: nil)
        })
    }

    /// A shape has no names in it.
    var shapeDatasetID: String { id }

    /// TD's drawn line from the minibus layer, whose ids are this API's own `route_id` and
    /// `route_seq`, so it is asked for the one direction (`HKRouteLines`).
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        guard let ref = LineRef(id: line.id) else {
            throw TransitError.unsupported("line \(line.id) has no GMB route id/sequence (was it loaded from another provider?)")
        }
        return try await HKRouteLines.shape(HKRouteLines.minibusLayer, where: "ROUTE_ID = \(ref.routeID) AND ROUTE_SEQ = \(ref.seq)",
                                            pattern: pattern, http: http)
    }

    /// GMB publishes no vehicle positions.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }

    /// `eta/route-stop/{route_id}/{stop_id}` answers every visit of the route to the stop, in both
    /// directions; the other direction is dropped. At a loop's first stop (HKI 12, 14M) that includes the
    /// minibuses finishing the loop there (the last `stop_seq`), so only the first visit is kept. An entry remarked "Scheduled" (未開出, "not yet
    /// departed") is a timetable slot, not a tracked minibus. `enabled: false` means no ETA service.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        guard let ref = LineRef(id: line.id) else {
            throw TransitError.unsupported("line \(line.id) has no GMB route id/sequence (was it loaded from another provider?)")
        }
        let visits = (try await Self.get(DTO.List<DTO.StopETA>.self, http, "/eta/route-stop/\(ref.routeID)/\(stop.code)").data ?? [])
            .filter { $0.route_seq == ref.seq }
        let firstVisit = visits.map(\.stop_seq).min()
        return visits
            .filter { $0.stop_seq == firstVisit && $0.enabled != false }
            .flatMap { $0.eta ?? [] }
            .compactMap { eta -> Arrival? in
                guard let expected = eta.timestamp.flatMap(HKTime.parse) else { return nil }
                let scheduled = (eta.remarks_en ?? "").localizedCaseInsensitiveContains("scheduled")
                return Arrival(expectedAt: expected, scheduledAt: nil, isRealtime: !scheduled, tripId: nil, vehicleLocation: nil)
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    // MARK: - Loading

    /// Route codes by region.
    private func routeList() async throws -> [String: [String]] {
        try await Self.store.routeList.value("routes", ttl: nil) { [http] in
            try await Self.get(DTO.One<DTO.RouteList>.self, http, "/route").data?.routes ?? [:]
        }
    }

    /// Every variant of a route code in a region ("Normal Route", "Short Working Service"…).
    private func variants(region: String, code: String) async throws -> [DTO.Route] {
        let path = "/route/\(region)/\(code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? code)"
        return try await Self.store.routes.value(path, ttl: nil) { [http] in
            let routes = try await Self.get(DTO.List<DTO.Route>.self, http, path).data ?? []
            for route in routes { await Self.store.routes.seed("/route/\(route.route_id)", [route]) }
            return routes
        }
    }

    private func route(id: Int) async throws -> DTO.Route? {
        let path = "/route/\(id)"
        return try await Self.store.routes.value(path, ttl: nil) { [http] in
            try await Self.get(DTO.List<DTO.Route>.self, http, path).data ?? []
        }.first
    }

    private func termini() async throws -> [DTO.Terminus] {
        try await Self.store.termini.value("termini", ttl: nil) { [http, terminiURL] in
            try await http.get(DTO.Features.self, terminiURL, "/query", query: [
                "where": "1=1", "returnGeometry": "false", "f": "json",
                "outFields": "ROUTE_ID,ROUTE_SEQ,ST_STOP_NAMEE,ST_STOP_NAMEC,ST_STOP_NAMES,ED_STOP_NAMEE,ED_STOP_NAMEC,ED_STOP_NAMES",
            ]).features.map(\.attributes)
        }
    }

    /// One direction's stop list: ids and names, in travel order.
    private func rows(_ ref: LineRef) async throws -> [DTO.RouteStop] {
        try await Self.store.rows.value(ref.id, ttl: nil) { [http] in
            let rows = try await Self.get(DTO.One<DTO.RouteStops>.self, http, "/route-stop/\(ref.routeID)/\(ref.seq)").data?.route_stops ?? []
            return rows.sorted { $0.stop_seq < $1.stop_seq }
        }
    }

    /// One direction's stops with coordinates. A stop whose coordinates cannot be had is skipped
    /// rather than failing the whole route.
    private func stops(_ ref: LineRef) async throws -> [GMBStop] {
        let rows = try await rows(ref)
        let ids = Array(Set(rows.map(\.stop_id)))
        let located = try await Self.map(ids) { [self] id in try? await location(of: id) }
        let locations = Dictionary(zip(ids, located).compactMap { id, point in (point ?? nil).map { (id, $0) } },
                                   uniquingKeysWith: { first, _ in first })
        guard !locations.isEmpty || rows.isEmpty else { throw TransitError.notFound("coordinates of GMB line \(ref.id)") }
        return rows.compactMap { row in
            guard let location = locations[row.stop_id] else { return nil }
            return GMBStop(code: String(row.stop_id), location: location, sequence: row.stop_seq,
                           nameEN: row.name_en, nameTC: row.name_tc, nameSC: row.name_sc)
        }
    }

    /// Several directions, loaded side by side, concatenated in the order asked.
    private func stops(of refs: [LineRef]) async throws -> [GMBStop] {
        let loaded = try await Self.map(refs) { [self] ref in try await stops(ref) }
        return loaded.flatMap { $0 ?? [] }
    }

    private func location(of id: Int) async throws -> GeoPoint {
        try await Self.store.locations.value(String(id), ttl: nil) { [http] in
            guard let point = try await Self.get(DTO.One<DTO.Stop>.self, http, "/stop/\(id)").data?.coordinates?.wgs84 else {
                throw TransitError.notFound("GMB stop \(id)")
            }
            return GeoPoint(lat: point.latitude, lon: point.longitude)
        }
    }

    /// A stop reached by its id alone: coordinates from `/stop`, its name from the first route calling there.
    private func stop(id: String) async throws -> GMBStop {
        guard let number = Int(id) else { throw TransitError.notFound("GMB stop \(id)") }
        async let location = location(of: number)
        async let calls = Self.get(DTO.List<DTO.StopRoute>.self, http, "/stop-route/\(id)")
        let (point, routes) = try await (location, calls)
        let first = routes.data?.first
        return GMBStop(code: id, location: point, sequence: first?.stop_seq ?? 0,
                       nameEN: first?.name_en, nameTC: first?.name_tc, nameSC: first?.name_sc)
    }

    /// A GET on the ETA API, tried once more after a pause when it answers 429 "Too Many Requests",
    /// which it does to a burst of lookups (a route search is dozens of `/stop` calls).
    private static func get<T: Decodable & Sendable>(_ type: T.Type, _ http: HTTPClient, _ path: String) async throws -> T {
        do {
            return try await http.get(T.self, base, path)
        } catch let error as ResponseError where error.status == 429 {
            try await Task.sleep(for: .seconds(3))
            return try await http.get(T.self, base, path)
        }
    }

    /// `body` over every element, `fanOut` at a time, results in input order (nil where it threw).
    private static func map<T: Sendable, R: Sendable>(_ items: [T], _ body: @escaping @Sendable (T) async throws -> R) async throws -> [R?] {
        try await withThrowingTaskGroup(of: (Int, R?).self) { group in
            var results = [R?](repeating: nil, count: items.count)
            var pending = items.enumerated().makeIterator()
            func next() {
                guard let (index, item) = pending.next() else { return }
                group.addTask { (index, try await body(item)) }
            }
            for _ in 0..<fanOut { next() }
            while let (index, result) = try await group.next() {
                results[index] = result
                next()
            }
            return results
        }
    }

    private static func line(_ route: DTO.Route, _ ref: LineRef, language: HKNameLanguage) -> TransitLine? {
        guard let direction = route.directions.first(where: { $0.route_seq == ref.seq }) else { return nil }
        let destination = language.pick(en: direction.dest_en, tc: direction.dest_tc, sc: direction.dest_sc)
        return TransitLine(
            id: ref.id, shortName: route.route_code, headsign: destination, agency: "GMB",
            origin: language.pick(en: direction.orig_en, tc: direction.orig_tc, sc: direction.orig_sc),
            destination: destination,
            providerRefs: ["region": route.region, "route": route.route_code, "routeID": String(ref.routeID), "routeSeq": String(ref.seq)]
        )
    }
}

/// A stop as one route direction names it, with its name in all three languages so the session cache
/// serves any app language. (The same stop id may carry a different name on another route.)
private nonisolated struct GMBStop: Sendable {
    var code: String
    var location: GeoPoint
    var sequence: Int
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

private nonisolated extension Array where Element == GMBStop {
    func uniqued() -> [GMBStop] {
        var seen = Set<String>()
        return filter { seen.insert($0.code).inserted }
    }
}

private nonisolated extension Array where Element == LineRef {
    func uniqued() -> [LineRef] {
        var seen = Set<LineRef>()
        return filter { seen.insert($0).inserted }
    }
}

/// `TransitLine.id` is "route_id|route_seq", e.g. "2006408|1".
private nonisolated struct LineRef: Hashable, Sendable {
    var routeID: Int
    var seq: Int

    init(routeID: Int, seq: Int) { (self.routeID, self.seq) = (routeID, seq) }

    init?(id: String) {
        let parts = id.split(separator: "|")
        guard parts.count == 2, let routeID = Int(parts[0]), let seq = Int(parts[1]) else { return nil }
        (self.routeID, self.seq) = (routeID, seq)
    }

    var id: String { "\(routeID)|\(seq)" }
}

// MARK: - Session cache

private actor GMBStore {
    let routeList = Memo<[String: [String]]>()
    /// Keyed by request path: "/route/HKI/1" (every variant) or "/route/2006408" (one).
    let routes = Memo<[DTO.Route]>()
    let termini = Memo<[DTO.Terminus]>()
    let rows = Memo<[DTO.RouteStop]>()
    let locations = Memo<GeoPoint>()
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

    /// Keeps a value already in hand, unless one is loaded or loading.
    func seed(_ key: String, _ value: Value) {
        guard entries[key] == nil else { return }
        entries[key] = (ContinuousClock.now, Task { value })
    }
}

/// Timestamps carry milliseconds and their offset ("2026-09-28T22:05:10.278+08:00").
private nonisolated enum HKTime {
    static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct List<T: Decodable & Sendable>: Decodable, Sendable { var data: [T]? }
    struct One<T: Decodable & Sendable>: Decodable, Sendable { var data: T? }

    struct RouteList: Decodable, Sendable {
        var routes: [String: [String]]
    }

    struct Route: Decodable, Sendable {
        var route_id: Int
        var region: String
        var route_code: String
        var description_en: String?
        var directions: [Direction]
    }

    struct Direction: Decodable, Sendable {
        var route_seq: Int
        var orig_en: String?
        var orig_tc: String?
        var orig_sc: String?
        var dest_en: String?
        var dest_tc: String?
        var dest_sc: String?
    }

    struct RouteStops: Decodable, Sendable {
        var route_stops: [RouteStop]
    }

    struct RouteStop: Decodable, Sendable {
        var stop_seq: Int
        var stop_id: Int
        var name_en: String?
        var name_tc: String?
        var name_sc: String?
    }

    struct Stop: Decodable, Sendable {
        var coordinates: Coordinates?

        struct Coordinates: Decodable, Sendable { var wgs84: Point? }
        struct Point: Decodable, Sendable { var latitude: Double; var longitude: Double }
    }

    struct StopRoute: Decodable, Sendable {
        var route_id: Int
        var route_seq: Int
        var stop_seq: Int
        var name_en: String?
        var name_tc: String?
        var name_sc: String?
    }

    /// One visit of the route to the stop. With ETA disabled, `eta` is absent and a `description_*` says why.
    struct StopETA: Decodable, Sendable {
        var route_seq: Int
        var stop_seq: Int
        var enabled: Bool?
        var eta: [ETA]?
    }

    struct ETA: Decodable, Sendable {
        var eta_seq: Int?
        var diff: Int?
        var timestamp: String?
        var remarks_en: String?
    }

    /// ArcGIS query reply of the CSDI route layer: one feature per route direction, first and last stop.
    struct Features: Decodable, Sendable {
        var features: [Feature]
        struct Feature: Decodable, Sendable { var attributes: Terminus }
    }

    struct Terminus: Decodable, Sendable {
        var ROUTE_ID: Int
        var ROUTE_SEQ: Int
        var ST_STOP_NAMEE: String?
        var ST_STOP_NAMEC: String?
        var ST_STOP_NAMES: String?
        var ED_STOP_NAMEE: String?
        var ED_STOP_NAMEC: String?
        var ED_STOP_NAMES: String?
    }
}
