import Foundation

/// Germany, Nuremberg — VAG's PULS web API (start.vag.de/dm/api/v1), keyless, the backend of VAG's
/// own departure monitor. See docs/research/worldwide-apis.md §5.7.
///
/// Licence: VAG-OpenData publishes the API ("Fahrplan | Echtzeitabfahrtsmonitor:
/// Schnittstellenbeschreibung API") under cc-by-4.0, so the credit names VAG and the licence. The
/// portal states no separate API terms and no rate limit, hence experimental.
///
/// ARRIVALS-ONLY: departures carry live times (`AbfahrtszeitIst`, `Prognose`) and the operational
/// vehicle number, but no vehicle positions.
///
/// Stops are VGN ids ("704", Plärrer), which cover VAG's city network (Nuremberg, Fürth, the 20/30
/// buses to Erlangen) and the VGN regional buses that feed PULS. The API has no line or route
/// catalogue: a line is a board entry's product, number and direction ("Tram 4, Richtung2"), and its
/// ordered stops are one live trip of it, read whole from the Fahrten API.
nonisolated struct VAGProvider: TransitProvider {
    let id = "vag-nuernberg"
    let displayName = "VAG (Nuremberg)"
    let attribution: String? = "Daten: VAG Verkehrs-Aktiengesellschaft Nürnberg, CC BY 4.0"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .linesAtStop, .routePattern,
        .realtimeArrivals, .scheduledArrivals, .nearbyStops,
    ]
    /// No limit is published; one departures call per poll.
    let suggestedRefreshInterval: Duration = .seconds(30)

    var http = HTTPClient()

    private let base = "https://start.vag.de/dm/api/v1"
    /// PULS products a bus board is for; U-Bahn, S-Bahn and regional-train departures are left out.
    fileprivate static let surfaceProducts: Set<String> = ["Bus", "Tram"]

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let response = try await http.get(DTO.Stops.self, base, "/haltestellen/VAG", query: ["name": query])
        return Self.unique(response.stops.filter(\.isSurface).compactMap(\.stop))
    }

    /// One board of 40 surface departures (an hour or more at a busy stop) gives the lines and
    /// directions that serve it.
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let departures = try await board(at: stop.code, line: nil, limit: 40)
        var order: [String] = []
        var byKey: [String: [DTO.Departure]] = [:]
        for departure in departures {
            guard let key = departure.lineKey else { continue }
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(departure)
        }
        return order.compactMap { key -> TransitLine? in
            guard let group = byKey[key], let first = group.first,
                  let name = first.line, let product = first.product, let direction = first.direction else { return nil }
            let headsign = Self.mostCommon(group.compactMap(\.destination))
            var refs = ["stop": stop.code, "product": product, "name": name, "direction": direction]
            refs["headsign"] = headsign
            refs["trip"] = first.trip.map(String.init)
            refs["day"] = first.day
            return TransitLine(id: key, shortName: name, headsign: headsign, agency: "VAG",
                               destination: headsign, providerRefs: refs)
        }
    }

    /// The Fahrten API returns a trip's whole stop list, first stop to last, passed stops included.
    /// The trip is the line's next one at the rider's stop, one showing the line's usual destination
    /// when there is one (short workings end early); the trip seen when the lines were listed stands
    /// in when the board has none left.
    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        guard let stopCode = line.providerRefs["stop"], let product = line.providerRefs["product"],
              let name = line.providerRefs["name"] else { throw TransitError.notFound("stop of line \(line.id)") }
        var candidates: [(trip: String, day: String?)] = []
        if let departures = try? await board(at: stopCode, line: name, product: product, limit: 20) {
            let own = departures.filter { $0.lineKey == line.id }
            let preferred = own.filter { $0.destination == line.headsign } + own.filter { $0.destination != line.headsign }
            candidates += preferred.prefix(2).compactMap { departure in departure.trip.map { (String($0), departure.day) } }
        }
        if let trip = line.providerRefs["trip"] { candidates.append((trip, line.providerRefs["day"])) }

        for candidate in candidates {
            // With the operating day the trip is found after it has ended, too.
            let path = [product, candidate.day, candidate.trip].compactMap { $0 }.map(Self.segment).joined(separator: "/")
            guard let trip = try? await http.get(DTO.Trip.self, base, "/fahrten/" + path) else { continue }
            var stops: [TransitStop] = []
            for call in trip.calls ?? [] {
                guard let stop = call.stop, stops.last?.code != stop.code else { continue }
                stops.append(stop)
            }
            guard stops.count >= 2 else { continue }
            return RoutePattern(line: line, stops: stops.enumerated().map {
                PatternStop(stop: $1, sequence: $0 + 1, distanceAlongRoute: nil)
            })
        }
        throw TransitError.notFound("a trip of \(name) at \(stopCode)")
    }

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }

    /// The board is asked for the one line (a path segment PULS filters on), and its direction
    /// picked out.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        guard let name = line.providerRefs["name"] else { throw TransitError.notFound("number of line \(line.id)") }
        let departures = try await board(at: stop.code, line: name, product: line.providerRefs["product"], limit: 20)
        let cutoff = Date().addingTimeInterval(-60)
        return departures
            .filter { $0.lineKey == line.id }
            .compactMap { departure -> Arrival? in
                let planned = departure.planned.flatMap(DTO.parseDate)
                guard let expected = departure.predicted.flatMap(DTO.parseDate) ?? planned,
                      expected >= cutoff else { return nil }
                return Arrival(expectedAt: expected, scheduledAt: planned, isRealtime: departure.isPredicted == true,
                               tripId: departure.trip.map(String.init))
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// The radius search (`distance`, in metres) gives stops without distances; the lines of the
    /// closest few cost one board each.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let response = try await http.get(
            DTO.Stops.self, base, "/haltestellen/VAG/location",
            query: ["lat": String(point.lat), "lon": String(point.lon), "distance": String(Int(radiusMeters))]
        )
        let stops = Self.unique(response.stops.filter(\.isSurface).compactMap(\.stop))
            .map { ($0, RouteGeometry.meters(point, $0.location)) }
            .filter { $0.1 <= radiusMeters }
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

    /// Surface departures at a VGN stop, of one line when given. Without `limitcount` PULS answers
    /// with eight.
    private func board(at stopCode: String, line: String?, product: String? = nil, limit: Int) async throws -> [DTO.Departure] {
        let path = "/abfahrten/VGN/" + Self.segment(stopCode) + (line.map { "/" + Self.segment($0) } ?? "")
        let products = product.map { [$0] } ?? Self.surfaceProducts.sorted()
        let response = try await http.get(DTO.Board.self, base, path,
                                          query: ["product": products.joined(separator: ","), "limitcount": String(limit)])
        return (response.departures ?? []).filter { $0.product.map(Self.surfaceProducts.contains) ?? false }
    }

    private static func segment(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? string
    }

    /// PULS lists one stop under several VAG ids ("FL", "FLUGHA"), all with the same VGN id.
    private static func unique(_ stops: [TransitStop]) -> [TransitStop] {
        var seen: Set<String> = []
        return stops.filter { seen.insert($0.code).inserted }
    }

    /// The most frequent value, the earliest seen on a tie.
    private static func mostCommon(_ values: [String]) -> String? {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        guard let top = counts.values.max() else { return nil }
        return values.first { counts[$0] == top }
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct Stops: Decodable, Sendable {
        var stops: [Stop]
        enum CodingKeys: String, CodingKey { case stops = "Haltestellen" }
    }

    /// A stop of a search, or a call of a trip (which has no `Produkte`).
    struct Stop: Decodable, Sendable {
        var name: String?
        var vgnID: Int?
        var latitude: Double?
        var longitude: Double?
        /// "Bus,Tram,UBahn"; missing for stops VAG itself does not serve.
        var products: String?

        enum CodingKeys: String, CodingKey {
            case name = "Haltestellenname", vgnID = "VGNKennung", latitude = "Latitude", longitude = "Longitude",
                 products = "Produkte"
        }

        var isSurface: Bool {
            guard let products else { return true }
            return products.split(separator: ",").contains { VAGProvider.surfaceProducts.contains(String($0)) }
        }

        var stop: TransitStop? {
            guard let vgnID, let latitude, let longitude else { return nil }
            let (stopName, city) = DTO.split(name ?? String(vgnID))
            return TransitStop(code: String(vgnID), name: stopName, city: city,
                               location: GeoPoint(lat: latitude, lon: longitude))
        }
    }

    struct Board: Decodable, Sendable {
        var departures: [Departure]?
        enum CodingKeys: String, CodingKey { case departures = "Abfahrten" }
    }

    struct Departure: Decodable, Sendable {
        var line: String?
        /// "Richtung1" or "Richtung2".
        var direction: String?
        var destination: String?
        var planned: String?
        /// Equal to the planned time when `isPredicted` is false.
        var predicted: String?
        /// "Bus", "Tram", "UBahn", "SBahn", "RBahn".
        var product: String?
        var trip: Int?
        /// The operating day, "2026-09-28".
        var day: String?
        var isPredicted: Bool?

        enum CodingKeys: String, CodingKey {
            case line = "Linienname", direction = "Richtung", destination = "Richtungstext",
                 planned = "AbfahrtszeitSoll", predicted = "AbfahrtszeitIst", product = "Produkt",
                 trip = "Fahrtnummer", day = "Betriebstag", isPredicted = "Prognose"
        }

        /// "Tram:4:Richtung2" — the line id, one per direction.
        var lineKey: String? {
            guard let product, let line, let direction else { return nil }
            return "\(product):\(line):\(direction)"
        }
    }

    struct Trip: Decodable, Sendable {
        var calls: [Stop]?
        enum CodingKeys: String, CodingKey { case calls = "Fahrtverlauf" }
    }

    /// "Hauptbahnhof (Fürth (Bayern))" → ("Hauptbahnhof", "Fürth (Bayern)"): the place is the last
    /// bracket, which may hold one of its own.
    static func split(_ full: String) -> (String, String?) {
        guard full.hasSuffix(")") else { return (full, nil) }
        var depth = 0
        for index in full.indices.reversed() {
            switch full[index] {
            case ")": depth += 1
            case "(":
                depth -= 1
                guard depth == 0 else { continue }
                let name = full[..<index].trimmingCharacters(in: .whitespaces)
                let city = full[full.index(after: index)..<full.index(before: full.endIndex)]
                    .trimmingCharacters(in: .whitespaces)
                return (name.isEmpty ? full : name, city.isEmpty ? nil : city)
            default: continue
            }
        }
        return (full, nil)
    }

    /// "2026-09-28T15:47:00+02:00".
    static func parseDate(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }
}
