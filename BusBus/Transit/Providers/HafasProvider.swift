import Foundation

/// HaCon's HAFAS ReST API ("fahrinfo"/"opendata/apiserver"), as transit authorities license it out
/// with a personal `accessId` given by e-mail. One adapter, one `Network` each:
///
/// - **Luxembourg** (mobiliteit.lu, Administration des transports publics, CC BY 4.0,
///   `MOBILITEIT_LU_KEY`): the whole country's buses and trams. The server answers only
///   `location.nearbystops` and `departureBoard` — no name search, no trip details — so the stop list
///   is loaded whole once (the authority's own documented query, ~0.7 MB) and searched here, and a
///   pattern is the trip's onward stops from the board's `passlist`.
/// - **VBB** (Berlin-Brandenburg, `VBB_KEY`): production access since 2026-10-02. Name search,
///   `location.nearbystops` and `journeyDetail` (the whole trip) all answer. VBB's terms: VBB named
///   as the timetable source in the app and on the website, efficient requests (or the ID may be
///   paused), no warranty on data or uptime; error reports to api@vbb.de carry the request, the
///   response and the URL.
///
/// ARRIVALS-ONLY: boards carry the plan (`date`/`time`) and, where the operator feeds it, the
/// prognosis (`rtDate`/`rtTime`); no vehicle positions. A stop is a station ("main mast",
/// `200405036`), which gathers its platforms; a line is a HAFAS line id in one direction
/// (`directionFlag`), named by the destination the board shows.
///
/// Release goes through our key-holding proxy (`TransitProxy`); Debug calls HAFAS directly when a
/// local key is present (see `APIKeys`, `KeyedEndpoint.keyed`).
nonisolated struct HafasProvider: TransitProvider {
    nonisolated struct Network: Sendable {
        enum StopSearch: Sendable {
            /// `location.name`.
            case byName
            /// The server has no name search: load every stop once and search locally.
            case wholeList(center: GeoPoint, radiusMeters: Int)
        }

        var id: String
        var displayName: String
        var attribution: String?
        var endpoint: KeyedEndpoint
        var timeZone: TimeZone
        /// The `products` bitmask for buses and trams on this server (each server numbers its own).
        var surfaceProducts: Int
        var stopSearch: StopSearch
        /// `journeyDetail` answers: a pattern is the whole trip, not only its onward stops.
        var hasJourneyDetail: Bool
    }

    var network: Network
    var id: String { network.id }
    var displayName: String { network.displayName }
    var attribution: String? { network.attribution }
    var capabilities: ProviderCapabilities {
        var capabilities: ProviderCapabilities = [
            .stopSearchByName, .linesAtStop, .routePattern, .realtimeArrivals, .scheduledArrivals, .nearbyStops,
        ]
        if case .wholeList = network.stopSearch { capabilities.insert(.stopSearchByCode) }
        if network.hasJourneyDetail { capabilities.insert(.routeShape) }
        return capabilities
    }
    /// One board per poll; the proxy shares one fetch between riders for 15 s.
    let suggestedRefreshInterval: Duration = .seconds(30)
    var requiredAPIKey: String? { endpoint.unmetKey }

    var http = HTTPClient()
    var endpoint: KeyedEndpoint

    init(_ network: Network) {
        self.network = network
        endpoint = network.endpoint
    }

    // MARK: - Stops

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        switch network.stopSearch {
        case .byName:
            let found = try await hafas(DTO.Locations.self, "/location.name",
                                        query: ["input": query, "type": "S", "maxNo": "20"])
            return Self.stations(found.stops).map(\.stop)
        case .wholeList:
            return Self.search(query, in: try await allStations())
        }
    }

    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let stations: [Station]
        switch network.stopSearch {
        case .byName:
            // `maxNo` counts platforms, so a small one returns a single station's platforms or none.
            let found = try await hafas(DTO.Locations.self, "/location.nearbystops", query: [
                "originCoordLat": String(point.lat), "originCoordLong": String(point.lon),
                "r": String(Int(radiusMeters)), "maxNo": "1000",
            ])
            stations = Self.stations(found.stops)
        case .wholeList:
            stations = try await allStations()
        }
        let nearest = stations
            .map { (stop: $0.stop, meters: RouteGeometry.meters(point, $0.stop.location)) }
            .filter { $0.meters <= radiusMeters }
            .sorted { $0.meters < $1.meters }
            .prefix(5)
        return await withTaskGroup(of: NearbyStop?.self) { group in
            for (stop, meters) in nearest {
                group.addTask {
                    guard let lines = try? await lines(atStop: stop), !lines.isEmpty else { return nil }
                    return NearbyStop(stop: stop, distanceMeters: meters, lines: lines)
                }
            }
            var result: [NearbyStop] = []
            for await stop in group { if let stop { result.append(stop) } }
            return result.sorted { $0.distanceMeters < $1.distanceMeters }
        }
    }

    /// Every bus and tram line leaving the station within `horizonMinutes`, one per direction. A
    /// line whose every trip there is cancelled is left out: picking it would show an empty board.
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let board = try await board(at: stop.code, minutes: Self.horizonMinutes, passlist: false)
        var lines = Self.lines(from: board, at: stop.code)
        // A loop runs both ways to one destination ("980 → Kopernikusstr." twice), so the two read
        // the same. Rare enough to pay for a second board that names each one's next stop.
        let labels = Dictionary(grouping: lines.indices) { "\(lines[$0].shortName)→\(lines[$0].headsign ?? "")" }
        let clashing = labels.values.filter { $0.count > 1 }.flatMap { $0 }
        if !clashing.isEmpty,
           let full = try? await self.board(at: stop.code, minutes: Self.horizonMinutes, passlist: true) {
            for index in clashing {
                guard let via = Self.nextStopName(of: lines[index].id, in: full) else { continue }
                lines[index].headsign = "\(lines[index].headsign ?? "") via \(via)"
            }
        }
        return lines
    }

    /// How far ahead lines and arrivals are looked for. One horizon for both, so a line that is
    /// offered always has a time to show (rural lines run hourly or less).
    static let horizonMinutes = 120

    static func lines(from board: [DTO.Visit], at stopCode: String) -> [TransitLine] {
        var seen: Set<String> = []
        return board.compactMap { departure -> TransitLine? in
            guard departure.cancelled != true, let key = departure.lineKey, let name = departure.lineName,
                  seen.insert(key).inserted else { return nil }
            return TransitLine(
                id: key,
                shortName: name,
                headsign: departure.direction,
                agency: departure.ProductAtStop?.operator,
                destination: departure.direction,
                providerRefs: ["stop": stopCode]
            )
        }
        .sorted { ($0.shortName.count, $0.shortName, $0.id) < ($1.shortName.count, $1.shortName, $1.id) }
    }

    /// The stop after the rider's on the line's next trip, from a board with `passlist`.
    static func nextStopName(of lineKey: String, in board: [DTO.Visit]) -> String? {
        guard let departure = board.first(where: { $0.lineKey == lineKey && $0.cancelled != true }),
              let stops = departure.Stops?.Stop else { return nil }
        let here = stops.firstIndex { $0.extId == departure.stopExtId } ?? 0
        return stops.dropFirst(here + 1).first { $0.name != stops[here].name }?.name
    }

    // MARK: - Patterns

    /// The next trip of the line from the board, whole: from `journeyDetail` where the server has
    /// it, else from a board at the line's first stop (`wholeTrip`). The board draws the stretch a
    /// bus comes along *to* the rider, so the onward stops alone (the `passlist` here) are kept only
    /// when that fails.
    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        try await trip(of: line).pattern
    }

    private func trip(of line: TransitLine, noDeparture: (String) -> TransitError = TransitError.notFound) async throws
        -> (pattern: RoutePattern, shape: RouteShape?) {
        guard let stopCode = line.providerRefs["stop"] else { throw TransitError.notFound("stop of line \(line.id)") }
        let board = try await board(at: stopCode, minutes: Self.horizonMinutes, passlist: !network.hasJourneyDetail)
        guard let departure = board.first(where: { $0.lineKey == line.id && $0.cancelled != true }) else {
            throw noDeparture("a trip of \(line.shortName) → \(line.headsign ?? "") at \(stopCode)")
        }
        var trip = departure.Stops?.Stop ?? []
        var boardingPlatform = departure.stopExtId
        var shape: RouteShape?
        if network.hasJourneyDetail, let ref = departure.JourneyDetailRef?.ref {
            // Always with the trip's line (`poly`), so the proxy's one cached reply serves both.
            // A trip without one gives an empty shape, kept so the card does not ask again.
            let journey = try await hafas(DTO.Journey.self, "/journeyDetail", query: ["id": ref, "poly": "1"])
            trip = journey.Stops?.Stop ?? []
            shape = journey.PolylineGroup?.shape ?? RouteShape(branches: [])
        } else if let whole = await wholeTrip(of: line.id, at: stopCode, board: board) {
            trip = whole
            boardingPlatform = nil
        }
        let stops = Self.patternStops(trip, boardingPlatform: boardingPlatform, riderStop: stopCode)
        guard stops.count >= 2 else { throw TransitError.notFound("stops of \(line.shortName) → \(line.headsign ?? "")") }
        return (RoutePattern(line: line, stops: stops), shape)
    }

    /// Without `journeyDetail`, a trip's earlier stops come from where it starts: a trip the other
    /// way past the rider ends there, and a board there (with `passlist`) lists a trip of this line
    /// that calls at the rider's station from its first stop on. Nil when any of that is missing (a
    /// one-way loop, no trip the other way soon).
    private func wholeTrip(of lineKey: String, at stopCode: String, board: [DTO.Visit]) async -> [DTO.TripStop]? {
        guard let start = Self.firstStop(of: lineKey, from: board), start != stopCode,
              let there = try? await self.board(at: start, minutes: Self.horizonMinutes, passlist: true) else { return nil }
        return Self.tripCalling(at: stopCode, of: lineKey, in: there)
    }

    /// Where the line's direction starts: the end of the longest trip the other way. Same HAFAS line,
    /// another `lineKey`.
    static func firstStop(of lineKey: String, from board: [DTO.Visit]) -> String? {
        guard let line = board.first(where: { $0.lineKey == lineKey })?.ProductAtStop?.lineId else { return nil }
        let opposite = board
            .filter { $0.ProductAtStop?.lineId == line && $0.lineKey != lineKey && $0.cancelled != true }
            .max { ($0.Stops?.Stop?.count ?? 0) < ($1.Stops?.Stop?.count ?? 0) }
        return opposite?.Stops?.Stop?.last.map { $0.mainMastExtId ?? $0.extId }
    }

    /// A trip of the line, from a board's `passlist`, that calls at the station. One that runs, if
    /// any does; else one cancelled at the board's stop, which still traces the route (a diversion
    /// past a line's first stop cancels every trip there).
    static func tripCalling(at stopCode: String, of lineKey: String, in board: [DTO.Visit]) -> [DTO.TripStop]? {
        let calling = board.filter { visit in
            visit.lineKey == lineKey
                && (visit.Stops?.Stop ?? []).dropFirst().contains { ($0.mainMastExtId ?? $0.extId) == stopCode }
        }
        return (calling.first { $0.cancelled != true } ?? calling.first)?.Stops?.Stop
    }

    // MARK: - Shapes

    /// The trip's own line comes with `journeyDetail` (VBB), so drawing it costs nothing more.
    func routePatternWithShape(for line: TransitLine) async throws -> (pattern: RoutePattern, shape: RouteShape?) {
        try await trip(of: line)
    }

    /// Only asked for when the pattern was kept from before shapes were: the pattern's calls
    /// again, and no trip soon (at night) means ask again next time. Without trip details
    /// (Luxembourg) there is no polyline at all.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        guard network.hasJourneyDetail else { throw TransitError.unsupported("route shapes") }
        guard let shape = try await trip(of: line, noDeparture: TransitError.tryLater).shape, !shape.isEmpty else {
            throw TransitError.notFound("shape of \(line.shortName)")
        }
        return shape
    }

    /// HAFAS names a trip's stops by station, at the station's centre: VBB's Philharmonie stands
    /// 182 m from the 200's road, Potsdamer Platz 140 m (the line itself lies within 6.5 m of the
    /// GTFS shape).
    var shapeTolerance: ShapeTolerance { .stopAreas }

    // MARK: - Live

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }

    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let cutoff = Date().addingTimeInterval(-60)
        return try await board(at: stop.code, minutes: Self.horizonMinutes, passlist: false)
            .filter { $0.lineKey == line.id && $0.cancelled != true }
            .compactMap { departure -> Arrival? in
                let planned = Self.date(departure.date, departure.time, in: network.timeZone)
                let predicted = Self.date(departure.rtDate ?? departure.date, departure.rtTime, in: network.timeZone)
                guard let expected = predicted ?? planned, expected >= cutoff else { return nil }
                return Arrival(expectedAt: expected, scheduledAt: planned, isRealtime: predicted != nil,
                               tripId: departure.JourneyDetailRef?.ref)
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    // MARK: - Requests

    private func hafas<T: Decodable & Sendable>(_ type: T.Type, _ path: String, query: [String: String]) async throws -> T {
        let target = try endpoint.resolve()
        let response = try await http.get(T.self, target.baseURL, path,
                                          query: query.merging(["format": "json"]) { a, _ in a }
                                              .merging(target.authQuery) { a, _ in a })
        if let error = (response as? DTO.Failing)?.errorCode {
            throw TransitError.badResponse("\(path): \(error)")
        }
        return response
    }

    /// The station's bus and tram departures, soonest first.
    private func board(at stopCode: String, minutes: Int, passlist: Bool) async throws -> [DTO.Visit] {
        try await hafas(DTO.Board.self, "/departureBoard", query: [
            "id": stopCode, "duration": String(minutes), "maxJourneys": "200",
            "products": String(network.surfaceProducts), "passlist": passlist ? "1" : "0",
        ]).Departure ?? []
    }

    /// The whole stop list, from the session cache or one `location.nearbystops` call.
    private func allStations() async throws -> [Station] {
        guard case let .wholeList(center, radius) = network.stopSearch else { return [] }
        return try await HafasStopListCache.shared.stations(id) {
            let found = try await hafas(DTO.Locations.self, "/location.nearbystops", query: [
                "originCoordLat": String(center.lat), "originCoordLong": String(center.lon),
                "r": String(radius), "maxNo": "5000", "type": "SE",
            ])
            return Self.stations(found.stops.filter { ($0.products ?? 0) & network.surfaceProducts != 0 })
        }
    }

    // MARK: - Helpers

    nonisolated struct Station: Sendable {
        var stop: TransitStop
        /// Lower-cased, accent-folded name, for local search.
        var folded: String
        /// HAFAS's own importance of the stop (a town's bus station outranks a stop near it).
        var weight: Int = 0
        /// Distinct lines calling at any of its platforms (each platform lists its own).
        var lines: Set<String> = []
    }

    /// Platforms gathered into their station, at the station's place, in the order first seen.
    static func stations(_ platforms: [DTO.Place]) -> [Station] {
        var order: [String] = []
        var byCode: [String: Station] = [:]
        for platform in platforms {
            let code = platform.mainMastExtId ?? platform.extId
            let lines = Set((platform.productAtStop ?? []).compactMap { $0.lineId ?? $0.line })
            if var station = byCode[code] {
                station.weight = max(station.weight, platform.weight ?? 0)
                station.lines.formUnion(lines)
                byCode[code] = station
                continue
            }
            let location = GeoPoint(lat: platform.mainMastLat ?? platform.lat, lon: platform.mainMastLon ?? platform.lon)
            let name = platform.mainMast?.name ?? platform.name
            order.append(code)
            byCode[code] = Station(stop: TransitStop(code: code, name: name, city: nil, location: location),
                                   folded: fold(name), weight: platform.weight ?? 0, lines: lines)
        }
        return order.compactMap { byCode[$0] }
    }

    /// Every word of the query in the name (in any order), or the station id itself. Names are
    /// "Place, Stop": a match on the place comes first, then on the stop; within each, the stop
    /// HAFAS weighs more, then the one with more lines.
    static func search(_ query: String, in stations: [Station]) -> [TransitStop] {
        if query.allSatisfy(\.isNumber), let exact = stations.first(where: { $0.stop.code == query }) {
            return [exact.stop]
        }
        let words = fold(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return [] }
        let matches = stations.filter { station in words.allSatisfy { station.folded.contains($0) } }
        let ranked = matches.sorted { a, b in
            // The place first ("Clervaux, …"), then the stop part ("…, Clervauxer Strooss"), then anywhere.
            let rank = { (s: Station) in
                s.folded.hasPrefix(words[0]) ? 0 : s.folded.contains(", " + words[0]) ? 1 : 2
            }
            return (rank(a), -a.weight, -a.lines.count, a.stop.name) < (rank(b), -b.weight, -b.lines.count, b.stop.name)
        }
        return ranked.prefix(20).map(\.stop)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// A trip's stops as a pattern. The rider's platform becomes the rider's station, so the board
    /// finds it; every other stop is named by its station where the server says which that is.
    /// With no platform known (a trip read from elsewhere), the first call at the station is it.
    ///
    /// The rider's station is in the pattern once, where they board: a loop or an out-and-back trip
    /// that comes by it again keeps that later call under the platform's own id, or the board could
    /// not tell which of the two is the rider's.
    static func patternStops(_ trip: [DTO.TripStop], boardingPlatform: String?, riderStop: String) -> [PatternStop] {
        var stops: [TransitStop] = []
        var boarded = false
        for stop in trip {
            var code = stop.mainMastExtId ?? stop.extId
            if !boarded, boardingPlatform.map { stop.extId == $0 } ?? (code == riderStop) {
                code = riderStop
                boarded = true
            } else if code == riderStop {
                code = stop.extId
            }
            guard stops.last?.code != code else { continue }
            stops.append(TransitStop(code: code, name: stop.name, city: nil, location: GeoPoint(lat: stop.lat, lon: stop.lon)))
        }
        return stops.enumerated().map { PatternStop(stop: $1, sequence: $0 + 1, distanceAlongRoute: nil) }
    }

    /// "2026-10-01" + "14:57:00", in the network's time zone.
    static func date(_ day: String?, _ time: String?, in timeZone: TimeZone) -> Date? {
        guard let day, let time else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: "\(day) \(time)")
    }
}

nonisolated extension HafasProvider.Network {
    /// Key granted by ATP (opendata-api@atp.etat.lu, 2026-09-30). CC BY 4.0, credit the source.
    /// Products: bus, night bus, city bus, CBEA = 32; tram = 256 (rail: 1, 2, 4).
    static let luxembourg = Self(
        id: "mobiliteit-lu",
        displayName: "mobiliteit.lu (Luxembourg)",
        attribution: "Data: Administration des transports publics / mobiliteit.lu, CC BY 4.0",
        endpoint: .keyed("https://cdt.hafas.de/opendata/apiserver", keyParameter: "accessId",
                         keyName: "MOBILITEIT_LU_KEY", proxyAgency: "mobiliteit"),
        timeZone: TimeZone(identifier: "Europe/Luxembourg")!,
        surfaceProducts: 32 | 256,
        stopSearch: .wholeList(center: GeoPoint(lat: 49.77723, lon: 6.09528), radiusMeters: 100_000),
        hasJourneyDetail: false
    )

    /// Production access granted by VBB (api@vbb.de, 2026-10-02). VBB asks to be named as the
    /// timetable source. Products: tram = 4, bus = 8.
    static let vbb = Self(
        id: "vbb",
        displayName: "VBB (Berlin-Brandenburg)",
        attribution: "Timetable data: VBB Verkehrsverbund Berlin-Brandenburg GmbH",
        endpoint: .keyed("https://fahrinfo.vbb.de/restproxy/latest", keyParameter: "accessId",
                         keyName: "VBB_KEY", proxyAgency: "vbb"),
        timeZone: TimeZone(identifier: "Europe/Berlin")!,
        surfaceProducts: 4 | 8,
        stopSearch: .byName,
        hasJourneyDetail: true
    )
}

/// Each network's stop list, once per session. A failed load is forgotten so the next call retries.
private actor HafasStopListCache {
    static let shared = HafasStopListCache()
    private var tasks: [String: Task<[HafasProvider.Station], any Error>] = [:]

    func stations(_ id: String, load: @escaping @Sendable () async throws -> [HafasProvider.Station]) async throws -> [HafasProvider.Station] {
        if let task = tasks[id] { return try await task.value }
        let task = Task { try await load() }
        tasks[id] = task
        do { return try await task.value } catch { tasks[id] = nil; throw error }
    }
}

// MARK: - Wire format

/// Field names are HAFAS's own, capitals included (`Departure`, `ProductAtStop`).
nonisolated extension HafasProvider {
    enum DTO {
        /// Any reply may instead carry `errorCode`/`errorText` (with HTTP 200 on some servers).
        protocol Failing { var errorCode: String? { get } }

        struct Locations: Decodable, Sendable, Failing {
            var stopLocationOrCoordLocation: [Entry]?
            var errorCode: String?

            struct Entry: Decodable, Sendable { var StopLocation: Place? }

            var stops: [Place] { (stopLocationOrCoordLocation ?? []).compactMap(\.StopLocation) }
        }

        struct MainMast: Decodable, Sendable { var name: String? }

        struct Place: Decodable, Sendable {
            var extId: String
            var name: String
            var lat: Double
            var lon: Double
            var products: Int?
            var weight: Int?
            var productAtStop: [Product]?
            var mainMast: MainMast?
            var mainMastExtId: String?
            var mainMastLat: Double?
            var mainMastLon: Double?
        }

        struct Board: Decodable, Sendable, Failing {
            var Departure: [Visit]?
            var errorCode: String?
        }

        struct Product: Decodable, Sendable {
            var line: String?
            var lineId: String?
            var name: String?
            var `operator`: String?
        }

        struct Ref: Decodable, Sendable { var ref: String }

        struct Visit: Decodable, Sendable {
            var name: String?
            var direction: String?
            var directionFlag: String?
            var date: String?
            var time: String?
            var rtDate: String?
            var rtTime: String?
            var cancelled: Bool?
            var stopExtId: String?
            var ProductAtStop: Product?
            var JourneyDetailRef: Ref?
            var Stops: TripStops?

            /// "29", or the product's name without its category ("Bus 29" → "29").
            var lineName: String? {
                let line = ProductAtStop?.line ?? ProductAtStop?.name ?? name
                return line.map { $0.split(separator: " ").last.map(String.init) ?? $0 }.flatMap { $0.isEmpty ? nil : $0 }
            }

            /// One line in one direction. `directionFlag` is "1" or "2" where the server has it; else
            /// the destination stands in.
            var lineKey: String? {
                guard let line = ProductAtStop?.lineId ?? lineName else { return nil }
                guard let way = directionFlag ?? direction else { return line }
                return "\(line)|\(way)"
            }
        }

        struct TripStops: Decodable, Sendable { var Stop: [TripStop]? }

        struct TripStop: Decodable, Sendable {
            var extId: String
            var name: String
            var lat: Double
            var lon: Double
            var mainMastExtId: String?
        }

        struct Journey: Decodable, Sendable, Failing {
            var Stops: TripStops?
            /// With `poly=1`: the trip's line along the roads.
            var PolylineGroup: Polylines?
            var errorCode: String?
        }

        /// `crd` is flat `[lon, lat, lon, lat, …]` (VBB sends absolute values to 6 decimals); with
        /// `delta` every pair after the first is an offset.
        struct Polylines: Decodable, Sendable {
            struct Description: Decodable, Sendable {
                var crd: [Double]?
                var delta: Bool?

                var points: [GeoPoint] {
                    guard let crd, crd.count >= 4 else { return [] }
                    var points: [GeoPoint] = []
                    var lon = 0.0, lat = 0.0
                    for index in stride(from: 0, to: crd.count - 1, by: 2) {
                        if delta == true && !points.isEmpty {
                            lon += crd[index]; lat += crd[index + 1]
                        } else {
                            lon = crd[index]; lat = crd[index + 1]
                        }
                        points.append(GeoPoint(lat: lat, lon: lon))
                    }
                    return points
                }
            }

            var polylineDesc: [Description]?

            var shape: RouteShape? {
                let lines = ShapeCheck.chained((polylineDesc ?? []).map(\.points))
                return lines.isEmpty ? nil : RouteShape(branches: lines)
            }
        }
    }
}
