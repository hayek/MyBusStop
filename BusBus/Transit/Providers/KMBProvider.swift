import Foundation

/// Hong Kong — KMB / Long Win Bus, the government ETA API on data.etabus.gov.hk (via DATA.GOV.HK).
/// Keyless, no published rate limit; predictions refresh about every 20–30 s (`data_timestamp`).
///
/// ARRIVALS ONLY: KMB publishes predicted times per stop but no bus positions, so the board computes
/// progress itself. There is no search or proximity query either, so the whole network comes from two
/// list endpoints, each fetched once per session and only when needed:
/// - `/stop` — every stop, ~6,700 of them: ~320 KB gzipped (1.2 MB JSON). Search, nearby, patterns.
/// - `/route-stop` — every stop of every route: ~390 KB gzipped (3.4 MB JSON). Lines at a stop.
/// plus `/route` (~40 KB gzipped) for termini. See docs/research/worldwide-apis.md §8.1.
///
/// Stop ids are 16-hex strings with no public meaning; the English name usually ends in the stop's
/// signpost code ("NELSON STREET MONG KOK (MK515)"), so searching for "MK515" also finds it.
/// A line is route + bound (O/I) + `service_type` — the latter numbers KMB's special variants of a route.
///
/// Names follow the app language (`HKNameLanguage`): English (upper case, as published), or the
/// `*_tc` / `*_sc` fields every record also carries. Search matches every language at once.
nonisolated struct KMBProvider: TransitProvider {
    let id = "hk-kmb"
    /// Lines and patterns are cached with their names baked in, so each name language is its own dataset.
    var datasetID: String { "\(id).\(HKNameLanguage.current.rawValue)" }
    let displayName = "KMB (Hong Kong)"
    let attribution: String? = "Data: Kowloon Motor Bus / DATA.GOV.HK; route lines: Transport Department / CSDI Portal"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .realtimeArrivals, .scheduledArrivals, .nearbyStops, .routeShape,
    ]
    let suggestedRefreshInterval: Duration = .seconds(30)

    var http = HTTPClient()

    private let base = "https://data.etabus.gov.hk/v1/transport/kmb"
    private static let store = KMBStore()
    private static let searchLimit = 60

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard !query.isEmpty else { return [] }
        let language = HKNameLanguage.current
        let stops = try await allStops()
        if let exact = stops.byID[query] { return [exact.stop(in: language)] }
        return stops.list
            .filter { $0.matches(query) }
            .prefix(Self.searchLimit)
            .map { $0.stop(in: language) }
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        do {
            async let index = routeStops()
            async let routes = routeList()
            return try await Self.lines(at: stop.code, index: index, routes: routes, language: HKNameLanguage.current)
        } catch {
            // The dumps sit behind a touchy firewall. Without them, the stop's own ETA board still
            // names every route that has a bus coming — just not ones that have finished for the day.
            let response = try await http.get(DTO.List<DTO.ETA>.self, base, "/stop-eta/\(stop.code)")
            let language = HKNameLanguage.current
            return (response.data ?? [])
                .compactMap { eta -> TransitLine? in
                    guard let route = eta.route, let dir = eta.dir, let serviceType = eta.service_type else { return nil }
                    let destination = language.pick(en: eta.dest_en, tc: eta.dest_tc, sc: eta.dest_sc)
                    return TransitLine(
                        id: "\(route)|\(dir)|\(serviceType)", shortName: route, headsign: destination, agency: "KMB",
                        destination: destination,
                        providerRefs: ["route": route, "bound": dir, "serviceType": String(serviceType)]
                    )
                }
                .reduce(into: [TransitLine]()) { list, line in if !list.contains(where: { $0.id == line.id }) { list.append(line) } }
        }
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        guard let ref = LineRef(line) else {
            throw TransitError.unsupported("line \(line.id) has no KMB route/bound (was it loaded from another provider?)")
        }
        async let response = http.get(DTO.List<DTO.RouteStop>.self, base, "/route-stop/\(ref.route)/\(ref.boundPath)/\(ref.serviceType)")
        async let stops = allStops()
        let (rows, index) = try await (response.data ?? [], stops)
        let language = HKNameLanguage.current
        let pattern = rows
            .compactMap { row -> PatternStop? in
                guard let seq = Int(row.seq), let stop = index.byID[row.stop] else { return nil }
                return PatternStop(stop: stop.stop(in: language), sequence: seq, distanceAlongRoute: nil)
            }
            .sorted { $0.sequence < $1.sequence }
        guard pattern.count >= 2 else { throw TransitError.notFound("stops for KMB line \(line.id)") }
        return RoutePattern(line: line, stops: pattern)
    }

    /// A shape has no names in it.
    var shapeDatasetID: String { id }

    /// TD's drawn line (`HKRouteLines`): one query answers every direction and service type of the
    /// route number. KMB's and Long Win's own routes, and those run jointly with Citybus.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        guard let ref = LineRef(line) else {
            throw TransitError.unsupported("line \(line.id) has no KMB route/bound (was it loaded from another provider?)")
        }
        return try await HKRouteLines.shape(route: ref.route, company: "COMPANY_CODE <> 'CTB' AND COMPANY_CODE <> 'NLB'",
                                            pattern: pattern, http: http)
    }

    /// KMB publishes no vehicle positions.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }

    /// `eta/{stop}/{route}/{service_type}` answers both directions of the route; the other one is dropped.
    /// It also answers every visit (`seq`) of the route to the stop: at a loop's first stop (5M, 8A) the
    /// buses finishing the loop there come back too. Only the first visit is kept, as hkbus/hk-bus-eta does.
    /// An entry remarked "Scheduled Bus" (原定班次) is a timetable slot, not a tracked bus. A null `eta`
    /// means no service (the remark then says why, e.g. the last bus has left).
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        guard let ref = LineRef(line) else {
            throw TransitError.unsupported("line \(line.id) has no KMB route/bound (was it loaded from another provider?)")
        }
        let response = try await http.get(DTO.List<DTO.ETA>.self, base, "/eta/\(stop.code)/\(ref.route)/\(ref.serviceType)")
        let visits = (response.data ?? []).filter { $0.dir == ref.bound }
        let firstVisit = visits.compactMap(\.seq).min()
        return visits
            .filter { $0.seq == firstVisit }
            .compactMap { eta -> Arrival? in
                guard let expected = eta.eta.flatMap(HKTime.parse) else { return nil }
                let scheduled = (eta.rmk_en ?? "").localizedCaseInsensitiveContains("scheduled")
                return Arrival(expectedAt: expected, scheduledAt: nil, isRealtime: !scheduled, tripId: nil, vehicleLocation: nil)
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        async let stops = allStops()
        async let index = routeStops()
        async let routes = routeList()
        let (all, stopIndex, routeIndex) = try await (stops, index, routes)
        let language = HKNameLanguage.current
        return all.list
            .compactMap { entry -> NearbyStop? in
                let distance = RouteGeometry.meters(point, entry.location)
                guard distance <= radiusMeters else { return nil }
                return NearbyStop(stop: entry.stop(in: language), distanceMeters: distance,
                                  lines: Self.lines(at: entry.code, index: stopIndex, routes: routeIndex, language: language))
            }
            .sorted { $0.distanceMeters < $1.distanceMeters }
    }

    // MARK: - Session caches

    private func allStops() async throws -> KMBStops {
        try await Self.store.stops.value("stops", ttl: nil) { [base] in
            KMBStops(try await Self.list(DTO.Stop.self, base + "/stop"))
        }
    }

    private func routeStops() async throws -> KMBRouteStops {
        try await Self.store.routeStops.value("route-stop", ttl: nil) { [base] in
            KMBRouteStops(try await Self.list(DTO.RouteStop.self, base + "/route-stop"))
        }
    }

    private func routeList() async throws -> [String: DTO.Route] {
        try await Self.store.routes.value("route", ttl: nil) { [base] in
            let routes = try await Self.list(DTO.Route.self, base + "/route")
            return Dictionary(routes.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// The whole-network lists (`/stop`, `/route`, `/route-stop`) sit behind an Azure Front Door rule
    /// that answers 403 "The request is blocked" to a second list request on the same connection
    /// (verified with curl: separate connections pass, one reused connection fails). So each list is
    /// fetched on its own throwaway session, and retried once on a fresh one after a short pause.
    private static func list<T: Decodable & Sendable>(_ type: T.Type, _ url: String) async throws -> [T] {
        guard let url = URL(string: url) else { throw TransitError.badResponse("invalid URL \(url)") }
        for attempt in 0..<2 {
            if attempt > 0 { try await Task.sleep(for: .seconds(3)) }
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("BusBus-iOS/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 403 && attempt == 0 { continue }
            guard (200..<300).contains(status) else { throw TransitError.badResponse("HTTP \(status) for \(url.path)") }
            do {
                return try JSONDecoder().decode(DTO.List<T>.self, from: data).data ?? []
            } catch {
                throw TransitError.badResponse("decoding \(url.path): \(error)")
            }
        }
        throw TransitError.badResponse("HTTP 403 for \(url.path)")
    }

    /// Lines calling at the stop, minus those that end there (nobody boards a bus at its last stop).
    private static func lines(at code: String, index: KMBRouteStops, routes: [String: DTO.Route],
                              language: HKNameLanguage) -> [TransitLine] {
        (index.byStop[code] ?? [])
            .filter { index.lastSeq[$0.key] != $0.seq }
            .map(\.key)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .compactMap { key -> TransitLine? in
                guard let route = routes[key] else { return nil }
                let destination = language.pick(en: route.dest_en, tc: route.dest_tc, sc: route.dest_sc)
                return TransitLine(
                    id: key,
                    shortName: route.route,
                    headsign: destination,
                    agency: "KMB",
                    origin: language.pick(en: route.orig_en, tc: route.orig_tc, sc: route.orig_sc),
                    destination: destination,
                    providerRefs: ["route": route.route, "bound": route.bound, "serviceType": route.service_type]
                )
            }
            .sorted { ($0.shortName.count, $0.shortName, $0.id) < ($1.shortName.count, $1.shortName, $1.id) }
    }
}

/// `TransitLine.id` is "route|bound|service_type", e.g. "1A|O|1".
private nonisolated struct LineRef {
    var route: String
    var bound: String
    var serviceType: String

    init?(_ line: TransitLine) {
        let parts = line.id.split(separator: "|").map(String.init)
        guard parts.count == 3 else { return nil }
        (route, bound, serviceType) = (parts[0], parts[1], parts[2])
    }

    var boundPath: String { bound == "I" ? "inbound" : "outbound" }
}

// MARK: - Indexes

/// Every stop with its name in all three languages, so the session cache serves any app language.
private nonisolated struct KMBStops: Sendable {
    struct Entry: Sendable {
        var code: String
        var location: GeoPoint
        var nameEN: String?
        var nameTC: String?
        var nameSC: String?

        func stop(in language: HKNameLanguage) -> TransitStop {
            TransitStop(code: code, name: language.pick(en: nameEN, tc: nameTC, sc: nameSC) ?? code, city: nil, location: location)
        }

        /// `query` is upper-cased; Chinese is unaffected by that.
        func matches(_ query: String) -> Bool {
            [nameEN?.uppercased(), nameTC, nameSC].contains { $0?.contains(query) == true }
        }
    }

    var list: [Entry] = []
    var byID: [String: Entry] = [:]

    init(_ rows: [DTO.Stop]) {
        for row in rows {
            guard let lat = Double(row.lat), let lon = Double(row.long) else { continue }
            let entry = Entry(code: row.stop, location: GeoPoint(lat: lat, lon: lon),
                              nameEN: row.name_en, nameTC: row.name_tc, nameSC: row.name_sc)
            list.append(entry)
            byID[row.stop] = entry
        }
    }
}

private nonisolated struct KMBRouteStops: Sendable {
    struct Call: Sendable { var key: String; var seq: Int }

    var byStop: [String: [Call]] = [:]
    var lastSeq: [String: Int] = [:]

    init(_ rows: [DTO.RouteStop]) {
        for row in rows {
            guard let seq = Int(row.seq) else { continue }
            let key = "\(row.route)|\(row.bound)|\(row.service_type)"
            byStop[row.stop, default: []].append(Call(key: key, seq: seq))
            lastSeq[key] = max(lastSeq[key] ?? seq, seq)
        }
    }
}

private actor KMBStore {
    let stops = Memo<KMBStops>()
    let routeStops = Memo<KMBRouteStops>()
    let routes = Memo<[String: DTO.Route]>()
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

// MARK: - Name language (shared by the Hong Kong providers)

/// Which of the parallel name fields Hong Kong feeds publish (`name_en` / `name_tc` / `name_sc`) to show.
/// Resolved from `AppLanguage.locale` on every call, since the rider can switch language at runtime:
/// Chinese in Traditional script (zh-Hant, zh-HK, zh-TW) reads `tc`, Chinese in Simplified script
/// (zh-Hans, zh-CN, plain zh) reads `sc`, anything else English.
nonisolated enum HKNameLanguage: String, Sendable {
    case en, tc, sc

    static var current: HKNameLanguage { HKNameLanguage(locale: AppLanguage.locale) }

    init(locale: Locale) {
        let language = locale.language
        guard language.languageCode == .chinese else { self = .en; return }
        // "zh-HK" names no script; the maximal form ("zh-Hant-HK") does.
        let script = language.script ?? Locale.Language(identifier: language.maximalIdentifier).script
        self = script == .hanSimplified ? .sc : .tc
    }

    /// The name in this language, else the nearest other one that is present. Blank counts as absent.
    func pick(en: String?, tc: String?, sc: String? = nil) -> String? {
        let order = switch self {
        case .en: [en, tc, sc]
        case .tc: [tc, sc, en]
        case .sc: [sc, tc, en]
        }
        return order.lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

/// Timestamps carry their offset ("2026-09-22T17:26:11+08:00"), so no zone guessing is needed.
private nonisolated enum HKTime {
    static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct List<T: Decodable & Sendable>: Decodable, Sendable {
        var data: [T]?
    }

    /// Coordinates come as strings.
    struct Stop: Decodable, Sendable {
        var stop: String
        var name_en: String?
        var name_tc: String?
        var name_sc: String?
        var lat: String
        var long: String
    }

    /// `seq` and `service_type` are strings here (and numbers in the ETA feed).
    struct RouteStop: Decodable, Sendable {
        var route: String
        var bound: String
        var service_type: String
        var seq: String
        var stop: String
    }

    struct Route: Decodable, Sendable {
        var route: String
        var bound: String
        var service_type: String
        var orig_en: String?
        var dest_en: String?
        var orig_tc: String?
        var dest_tc: String?
        var orig_sc: String?
        var dest_sc: String?

        var key: String { "\(route)|\(bound)|\(service_type)" }
    }

    struct ETA: Decodable, Sendable {
        var route: String?
        var service_type: Int?
        var dest_en: String?
        var dest_tc: String?
        var dest_sc: String?
        var dir: String?
        /// The stop's place in the route; a loop's first stop is also its last.
        var seq: Int?
        var eta: String?
        var eta_seq: Int?
        var rmk_en: String?
        var data_timestamp: String?
    }
}
