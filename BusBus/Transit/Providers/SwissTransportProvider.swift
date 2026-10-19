import Foundation

/// Switzerland — transport.opendata.ch, the community Transport API over search.ch's timetable.
/// Keyless and unofficial ("The aim of this inofficial API is to cover public transport within
/// Switzerland"); the official alternative, opentransportdata.swiss, caps a key at 20,000 calls a
/// day for every user of the app. See docs/research/worldwide-apis.md §5.6.
///
/// Rate limit: "constraint by the rate limit of timetable.search.ch", which caps a client at
/// "1000 Routensuchen und 10080 Abfahrtstabellen" a day. Everything here is a station board (the
/// looser budget; route searches are never used), and each call asks only for the fields it reads
/// (`fields[]`), which shrinks a board from ~230 KB to a few KB.
///
/// ARRIVALS-ONLY: boards carry scheduled times and, where the operator feeds them, a `prognosis`;
/// no vehicle positions. Stops are DIDOK station ids ("8591105"); a board never names a line or a
/// direction, so a line is its public number plus the destination it shows ("72 → Zürich,
/// Milchbuck"), and one number may give several lines when trips short-turn.
nonisolated struct SwissTransportProvider: TransitProvider {
    let id = "ch-opendata"
    let displayName = "Swiss public transport"
    let attribution: String? = "Data: transport.opendata.ch / search.ch"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .realtimeArrivals, .scheduledArrivals, .nearbyStops,
    ]
    /// One small board per poll: 2,880 a day at 30 s, well inside search.ch's 10,080.
    let suggestedRefreshInterval: Duration = .seconds(30)

    var http = HTTPClient()

    private let base = "https://transport.opendata.ch/v1"

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        // A numeric query is matched as a station id, so codes need no separate path.
        let response = try await http.get(DTO.Locations.self, base, "/locations",
                                          query: ["query": query, "type": "station"])
        return response.stations.filter(\.isSurface).compactMap(\.stop)
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let board = try await board(at: stop.code, types: ["bus", "tram"], limit: 80,
                                    fields: ["stationboard/category", "stationboard/number",
                                             "stationboard/operator", "stationboard/to"])
        var seen: Set<String> = []
        return board.stationboard.compactMap { entry -> TransitLine? in
            guard let number = entry.number, let to = entry.to else { return nil }
            let key = Self.lineID(number: number, to: to)
            guard seen.insert(key).inserted else { return nil }
            return TransitLine(
                id: key,
                shortName: number,
                headsign: to,
                agency: entry.operator?.split(separator: " ").first.map(String.init),
                destination: to,
                providerRefs: ["stop": stop.code, "number": number, "to": to, "type": Self.type(of: entry.category)]
            )
        }
    }

    /// A board lists each trip's onward stops (`passList`). The stops before the rider's come from a
    /// second board at the line's other end — the destination the opposite direction shows here —
    /// where a trip of this line and destination that passes the rider's stop is listed whole. When
    /// that fails (one-way loops, no opposite trip soon) the pattern starts at the rider's stop.
    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        guard let stopCode = line.providerRefs["stop"], let number = line.providerRefs["number"],
              let to = line.providerRefs["to"] else { throw TransitError.notFound("stop of line \(line.id)") }
        let types = [line.providerRefs["type"] ?? "bus"]
        let fields = ["station", "stationboard/number", "stationboard/to",
                      "stationboard/passList/station/id", "stationboard/passList/station/name",
                      "stationboard/passList/station/coordinate"]
        let here = try await board(at: stopCode, types: types, limit: 40, fields: fields)
        guard let trip = here.stationboard.first(where: { $0.number == number && $0.to == to }) else {
            throw TransitError.notFound("a trip of \(number) → \(to) at \(stopCode)")
        }
        let onward = Self.stops(trip.passList ?? [], boardStation: here.station)

        let opposite = here.stationboard
            .filter { $0.number == number && $0.to != to }
            .max { ($0.passList?.count ?? 0) < ($1.passList?.count ?? 0) }
        if let originID = opposite?.passList?.last?.station?.id, originID != stopCode,
           let there = try? await board(at: originID, types: types, limit: 30, fields: fields),
           let whole = there.stationboard.first(where: { entry in
               entry.number == number && entry.to == to && (entry.passList ?? []).contains { $0.station?.id == stopCode }
           }) {
            let stops = Self.stops(whole.passList ?? [], boardStation: there.station)
            if stops.count >= 2 { return RoutePattern(line: line, stops: Self.sequenced(stops)) }
        }
        guard onward.count >= 2 else { throw TransitError.notFound("stops of \(number) → \(to)") }
        return RoutePattern(line: line, stops: Self.sequenced(onward))
    }

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }

    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let number = line.providerRefs["number"], to = line.providerRefs["to"]
        let board = try await board(at: stop.code, types: [line.providerRefs["type"] ?? "bus"], limit: 40,
                                    fields: ["stationboard/number", "stationboard/to", "stationboard/name",
                                             "stationboard/stop/departure", "stationboard/stop/prognosis/departure"])
        let cutoff = Date().addingTimeInterval(-60)
        return board.stationboard
            .filter { $0.number == number && $0.to == to }
            .compactMap { entry -> Arrival? in
                let planned = entry.stop?.departure.flatMap(DTO.parseDate)
                let predicted = entry.stop?.prognosis?.departure.flatMap(DTO.parseDate)
                guard let expected = predicted ?? planned, expected >= cutoff else { return nil }
                return Arrival(expectedAt: expected, scheduledAt: planned, isRealtime: predicted != nil,
                               tripId: entry.name)
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// `/locations` with a point answers nearest-first with distances; the lines of the closest few
    /// stops cost one small board each.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let response = try await http.get(DTO.Locations.self, base, "/locations",
                                          query: ["x": String(point.lat), "y": String(point.lon), "type": "station"])
        let stops = response.stations
            .filter(\.isSurface)
            .compactMap { station -> (TransitStop, Double)? in
                guard let stop = station.stop else { return nil }
                let distance = station.distance ?? RouteGeometry.meters(point, stop.location)
                return distance <= radiusMeters ? (stop, distance) : nil
            }
            .sorted { $0.1 < $1.1 }
            .prefix(5)
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

    private func board(at stationID: String, types: [String], limit: Int, fields: [String]) async throws -> DTO.Board {
        // Repeated `name[]=` keys don't fit HTTPClient's dictionary query, so the URL is built here.
        var components = URLComponents(string: base + "/stationboard")!
        components.queryItems = [URLQueryItem(name: "id", value: stationID), URLQueryItem(name: "limit", value: String(limit))]
            + types.map { URLQueryItem(name: "transportations[]", value: $0) }
            + fields.map { URLQueryItem(name: "fields[]", value: $0) }
        guard let url = components.url else { throw TransitError.badResponse("stationboard URL") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BusBus-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await http.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else { throw TransitError.badResponse("HTTP \(status) for /stationboard") }
        do {
            return try JSONDecoder().decode(DTO.Board.self, from: data)
        } catch {
            throw TransitError.badResponse("decoding /stationboard: \(error)")
        }
    }

    private static func lineID(number: String, to: String) -> String { "\(number)>\(to)" }

    /// Board categories: T/NFT are trams, everything else asked for here is a bus.
    private static func type(of category: String?) -> String {
        ["T", "NFT", "TRAM"].contains(category?.uppercased() ?? "") ? "tram" : "bus"
    }

    /// A `passList` opens with the boarding stop under a wrong id and no name or place, so the
    /// board's own station stands in for it. Stops without coordinates are dropped.
    private static func stops(_ passList: [DTO.Pass], boardStation: DTO.Station?) -> [TransitStop] {
        var list = passList.compactMap(\.station)
        if let boardStation, !list.isEmpty { list[0] = boardStation }
        var stops: [TransitStop] = []
        for station in list {
            guard let stop = station.stop, stops.last?.code != stop.code else { continue }
            stops.append(stop)
        }
        return stops
    }

    private static func sequenced(_ stops: [TransitStop]) -> [PatternStop] {
        stops.enumerated().map { PatternStop(stop: $1, sequence: $0 + 1, distanceAlongRoute: nil) }
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct Locations: Decodable, Sendable {
        var stations: [Station]
    }

    struct Station: Decodable, Sendable {
        var id: String?
        var name: String?
        var coordinate: Coordinate?
        var distance: Double?
        var icon: String?

        /// `x` is the latitude, `y` the longitude.
        struct Coordinate: Decodable, Sendable {
            var x: Double?
            var y: Double?
        }

        /// Addresses and POIs come back without an id; boat piers are no bus stop.
        var isSurface: Bool { id != nil && icon != "ship" }

        /// Names are "Place, Stop" ("Zürich, Bellevue") and kept whole, as signs and boards print them.
        var stop: TransitStop? {
            guard let id, let lat = coordinate?.x, let lon = coordinate?.y else { return nil }
            return TransitStop(code: id, name: name ?? id, city: nil, location: GeoPoint(lat: lat, lon: lon))
        }
    }

    struct Board: Decodable, Sendable {
        var station: Station?
        var stationboard: [Entry]
    }

    struct Entry: Decodable, Sendable {
        var name: String?
        var category: String?
        var number: String?
        var `operator`: String?
        var to: String?
        var stop: Stop?
        var passList: [Pass]?
    }

    struct Stop: Decodable, Sendable {
        var departure: String?
        var prognosis: Prognosis?
        struct Prognosis: Decodable, Sendable { var departure: String? }
    }

    struct Pass: Decodable, Sendable {
        var station: Station?
    }

    /// "2026-09-22T14:38:00+0200".
    static func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Zurich")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.date(from: string)
    }
}
