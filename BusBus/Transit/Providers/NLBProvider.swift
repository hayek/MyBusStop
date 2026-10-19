import Foundation

/// Hong Kong — New Lantao Bus (NLB), Lantau Island's buses (Tung Chung, Mui Wo, Tai O, Ngong Ping,
/// the airport and the HZMB port), the operator's API v2 on rt.data.gov.hk (via DATA.GOV.HK). Keyless,
/// no published rate limit.
///
/// ARRIVALS ONLY: NLB publishes predicted times per stop but no bus positions, and has no search or
/// proximity query. The network is small, though — 64 route variants, ~290 stops — so it comes whole
/// from the two list endpoints, fetched once per session: `route.php?action=list` (~19 KB) and each
/// route's `stop.php?action=list&routeId=` (~8 KB, stops in order with names and coordinates), ~520 KB
/// in all, uncompressed. Search, nearby, lines at a stop and patterns all answer from that.
///
/// A route id is one direction of one variant (3M from Tung Chung and 3M from Mui Wo are two), so it is
/// the line id as it stands. Stop ids are small numbers with no public meaning. The predictions are
/// computed from the timetable and historical running times, not live traffic: only a departure that
/// has left its first stop with a GPS-equipped bus (`departed`, `noGPS`) is shown as tracked.
///
/// Names follow the app language (`HKNameLanguage`): English, or the `_c` (Traditional) / `_s`
/// (Simplified) fields every record also carries. Search matches every language at once, and route
/// numbers too ("3M" lists the stops of every 3M variant).
nonisolated struct NLBProvider: TransitProvider {
    let id = "hk-nlb"
    /// Lines and patterns are cached with their names baked in, so each name language is its own dataset.
    var datasetID: String { "\(id).\(HKNameLanguage.current.rawValue)" }
    let displayName = "NLB (Hong Kong)"
    let attribution: String? = "Data: New Lantao Bus / DATA.GOV.HK; route lines: Transport Department / CSDI Portal"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .linesAtStop, .routePattern,
        .realtimeArrivals, .scheduledArrivals, .nearbyStops, .routeShape,
    ]
    let suggestedRefreshInterval: Duration = .seconds(30)

    var http = HTTPClient()

    private let base = "https://rt.data.gov.hk/v2/transport/nlb"
    private static let store = NLBStore()
    /// Parallel `stop.php?action=list` requests while the network loads.
    private static let fanOut = 6

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let network = try await network()
        let language = HKNameLanguage.current
        let routes = network.routes.filter { $0.routeNo.caseInsensitiveCompare(query) == .orderedSame }
        if !routes.isEmpty {
            return routes
                .flatMap { network.patterns[$0.routeId] ?? [] }
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .compactMap { network.stops[$0]?.stop(in: language) }
        }
        return network.list
            .filter { $0.matches(query) }
            .map { $0.stop(in: language) }
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let network = try await network()
        let lines = network.lines(at: stop.code, language: HKNameLanguage.current)
        guard !lines.isEmpty else { throw TransitError.notFound("NLB lines at stop \(stop.code)") }
        return lines
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let network = try await network()
        let language = HKNameLanguage.current
        let stops = (network.patterns[line.id] ?? []).enumerated().compactMap { index, code -> PatternStop? in
            network.stops[code].map { PatternStop(stop: $0.stop(in: language), sequence: index + 1, distanceAlongRoute: nil) }
        }
        guard stops.count >= 2 else { throw TransitError.notFound("stops for NLB line \(line.id)") }
        return RoutePattern(line: line, stops: stops)
    }

    /// A shape has no names in it.
    var shapeDatasetID: String { id }

    /// TD's drawn line (`HKRouteLines`): one query answers every variant of the route number. NLB's
    /// route ids are not TD's, and TD's `ROUTE_SEQ` is not the direction (3M Tung Chung → Mui Wo is 2).
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        let number: String
        if let route = line.providerRefs["route"] {
            number = route
        } else if let route = try await network().routes.first(where: { $0.routeId == line.id }) {
            number = route.routeNo
        } else {
            throw TransitError.notFound("NLB route \(line.id)")
        }
        return try await HKRouteLines.shape(route: number, company: "COMPANY_CODE = 'NLB'", pattern: pattern, http: http)
    }

    /// NLB publishes no vehicle positions.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }

    /// No `estimatedArrivals` key (an empty `{}`) means nothing is due.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let language = switch HKNameLanguage.current {
        case .en: "en"
        case .tc: "zh"
        case .sc: "cn"
        }
        let response = try await http.get(DTO.Arrivals.self, base, "/stop.php", query: [
            "action": "estimatedArrivals", "routeId": line.id, "stopId": stop.code, "language": language,
        ])
        return (response.estimatedArrivals ?? [])
            .compactMap { eta -> Arrival? in
                guard let expected = eta.estimatedArrivalTime.flatMap(HKTime.parse) else { return nil }
                let tracked = eta.departed?.value == "1" && eta.noGPS?.value != "1"
                return Arrival(expectedAt: expected, scheduledAt: nil, isRealtime: tracked, tripId: nil, vehicleLocation: nil)
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let network = try await network()
        let language = HKNameLanguage.current
        return network.list
            .compactMap { entry -> NearbyStop? in
                let distance = RouteGeometry.meters(point, entry.location)
                guard distance <= radiusMeters else { return nil }
                return NearbyStop(stop: entry.stop(in: language), distanceMeters: distance,
                                  lines: network.lines(at: entry.code, language: language))
            }
            .sorted { $0.distanceMeters < $1.distanceMeters }
    }

    // MARK: - Session cache

    /// Every route and every route's stops. One route whose stops will not load is left out; none
    /// loading at all is an error.
    private func network() async throws -> NLBNetwork {
        try await Self.store.network.value("network", ttl: nil) { [http, base] in
            let routes = try await http.get(DTO.Routes.self, base, "/route.php", query: ["action": "list"]).routes
            let stops = await withTaskGroup(of: (String, [DTO.Stop]?).self) { group in
                var result: [String: [DTO.Stop]] = [:]
                var pending = routes.map(\.routeId.value)[...]
                func next() {
                    guard let id = pending.popFirst() else { return }
                    group.addTask {
                        (id, try? await http.get(DTO.Stops.self, base, "/stop.php", query: ["action": "list", "routeId": id]).stops)
                    }
                }
                for _ in 0..<Self.fanOut { next() }
                while let (id, stops) = await group.next() {
                    if let stops { result[id] = stops }
                    next()
                }
                return result
            }
            guard !stops.isEmpty else { throw TransitError.badResponse("no NLB route stop list loaded") }
            return NLBNetwork(routes: routes, stops: stops)
        }
    }
}

// MARK: - Index

private nonisolated struct NLBNetwork: Sendable {
    struct Route: Sendable {
        var routeId: String
        var routeNo: String
        /// "Tai O > Mui Wo Ferry Pier", split at the arrow.
        var nameEN: String
        var nameTC: String
        var nameSC: String
    }

    /// A stop with its name and street in all three languages, so the session cache serves any app language.
    struct Entry: Sendable {
        var code: String
        var location: GeoPoint
        var nameEN: String?
        var nameTC: String?
        var nameSC: String?
        var streetEN: String?
        var streetTC: String?
        var streetSC: String?

        func stop(in language: HKNameLanguage) -> TransitStop {
            TransitStop(code: code, name: language.pick(en: nameEN, tc: nameTC, sc: nameSC) ?? code, city: nil,
                        location: location, address: language.pick(en: streetEN, tc: streetTC, sc: streetSC))
        }

        func matches(_ query: String) -> Bool {
            [nameEN, nameTC, nameSC].contains { $0?.localizedCaseInsensitiveContains(query) == true }
        }
    }

    var routes: [Route] = []
    var list: [Entry] = []
    var stops: [String: Entry] = [:]
    /// Route id → its stop ids in order.
    var patterns: [String: [String]] = [:]

    init(routes: [DTO.Route], stops: [String: [DTO.Stop]]) {
        self.routes = routes.map {
            Route(routeId: $0.routeId.value, routeNo: $0.routeNo, nameEN: $0.routeName_e ?? "", nameTC: $0.routeName_c ?? "",
                  nameSC: $0.routeName_s ?? "")
        }
        for route in self.routes {
            guard let rows = stops[route.routeId] else { continue }
            patterns[route.routeId] = rows.map(\.stopId.value)
            for row in rows where self.stops[row.stopId.value] == nil {
                guard let lat = Double(row.latitude.value), let lon = Double(row.longitude.value) else { continue }
                let entry = Entry(code: row.stopId.value, location: GeoPoint(lat: lat, lon: lon),
                                  nameEN: row.stopName_e, nameTC: row.stopName_c, nameSC: row.stopName_s,
                                  streetEN: row.stopLocation_e, streetTC: row.stopLocation_c, streetSC: row.stopLocation_s)
                list.append(entry)
                self.stops[entry.code] = entry
            }
        }
    }

    /// Lines calling at the stop, minus those that end there (nobody boards a bus at its last stop;
    /// a loop's last stop is its first).
    func lines(at code: String, language: HKNameLanguage) -> [TransitLine] {
        routes
            .filter { route in
                guard let ids = patterns[route.routeId], let index = ids.lastIndex(of: code) else { return false }
                return index < ids.count - 1 || ids.first == code
            }
            .map { route in
                let (origin, destination) = Self.termini(language.pick(en: route.nameEN, tc: route.nameTC, sc: route.nameSC) ?? "")
                return TransitLine(
                    id: route.routeId, shortName: route.routeNo, headsign: destination, agency: "NLB",
                    origin: origin, destination: destination, providerRefs: ["route": route.routeNo]
                )
            }
            .sorted { ($0.shortName.count, $0.shortName, $0.id) < ($1.shortName.count, $1.shortName, $1.id) }
    }

    /// "Mui Wo Ferry Pier > Tong Fuk (to Shui Hau)" → ("Mui Wo Ferry Pier", "Tong Fuk (to Shui Hau)").
    static func termini(_ name: String) -> (String?, String?) {
        let parts = name.split(separator: ">", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let clean = parts.map { $0.replacing(/\s{2,}/, with: " ") }.map { $0.isEmpty ? nil : $0 }
        return clean.count == 2 ? (clean[0], clean[1]) : (nil, clean.first ?? nil)
    }
}

private actor NLBStore {
    let network = Memo<NLBNetwork>()
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

/// "2026-09-28 22:15:00" is Hong Kong local time, with no offset given.
private nonisolated enum HKTime {
    static func parse(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Hong_Kong")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    /// Numbers come as strings or numbers, depending on the field and the day ("routeId": "2",
    /// "departed": "0", "someDepartureObserveOnly": 0), so they are read either way.
    struct Text: Decodable, Sendable {
        var value: String

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                value = text
            } else if let number = try? container.decode(Int.self) {
                value = String(number)
            } else {
                value = String(try container.decode(Double.self))
            }
        }
    }

    struct Routes: Decodable, Sendable { var routes: [Route] }

    struct Route: Decodable, Sendable {
        var routeId: Text
        var routeNo: String
        var routeName_c: String?
        var routeName_s: String?
        var routeName_e: String?
    }

    struct Stops: Decodable, Sendable { var stops: [Stop] }

    /// Coordinates come as strings ("22.28986200").
    struct Stop: Decodable, Sendable {
        var stopId: Text
        var stopName_c: String?
        var stopName_s: String?
        var stopName_e: String?
        var stopLocation_c: String?
        var stopLocation_s: String?
        var stopLocation_e: String?
        var latitude: Text
        var longitude: Text
    }

    struct Arrivals: Decodable, Sendable {
        var estimatedArrivals: [ETA]?
    }

    struct ETA: Decodable, Sendable {
        var estimatedArrivalTime: String?
        var departed: Text?
        var noGPS: Text?
    }
}
