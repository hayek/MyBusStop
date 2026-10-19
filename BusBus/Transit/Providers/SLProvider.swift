import Foundation

/// Stockholm, Sweden — SL (Storstockholms Lokaltrafik) Transport API
/// (transport.integration.sl.se/v1), official and keyless: "This API does not require the use of an
/// API key. You should however not make excessive requests" (Trafiklab). No licence is named for
/// it, so the credit line only names the source. See docs/research/worldwide-apis.md §5.3.
///
/// ARRIVALS-ONLY: keyless SL has departures per site but no vehicle positions (those are Trafiklab
/// GTFS-RT behind a per-developer key with a 30k/month quota) and no stop list per line
/// (`journeys/{id}` answers 404). Buses only.
///
/// A "stop" is an SL *site* — every platform of one named place — coded by its site id, which the
/// departures call takes. Sites (~6,500; ~370 KB gzipped, 1.6 MB of JSON) come in one list with no
/// name filter, so it is fetched once per session and searched on the phone.
///
/// Patterns come from the keyless SL Journey-planner v2 (an EFA planner): a trip from the site to
/// the line's destination, with no changes and buses only, lists the stops the line calls at *from
/// the rider's stop on*. The planner cannot be told which line to use, so when none of its three
/// proposals rides this line the pattern falls back to just the two ends — the rider's stop and the
/// destination — rather than someone else's route. Times on the wire are Stockholm local time with
/// no offset.
nonisolated struct SLProvider: TransitProvider {
    let id = "sl"
    let displayName = "SL (Stockholm)"
    let attribution: String? = "Data: SL (Storstockholms Lokaltrafik) via Trafiklab"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .realtimeArrivals, .scheduledArrivals, .nearbyStops,
    ]
    /// No published limit, only a request not to poll excessively; one small call per line per poll.
    let suggestedRefreshInterval: Duration = .seconds(30)

    var http = HTTPClient()

    static let timeZone = TimeZone(identifier: "Europe/Stockholm")!
    fileprivate static let base = "https://transport.integration.sl.se/v1"
    private static let planner = "https://journeyplanner.integration.sl.se/v2"

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let sites = try await SLSites.shared.index(http)
        if let id = Int(query) {
            return sites.byID[id].map { [$0.stop] } ?? []
        }
        let words = SLSites.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let needle = words.joined(separator: " ")
        return sites.all
            .filter { site in words.allSatisfy { site.folded.contains($0) } }
            .sorted { a, b in
                let aRank = a.folded == needle ? 0 : a.folded.hasPrefix(needle) ? 1 : 2
                let bRank = b.folded == needle ? 0 : b.folded.hasPrefix(needle) ? 1 : 2
                if aRank != bRank { return aRank < bRank }
                return (a.stop.name, a.stop.code) < (b.stop.name, b.stop.code)
            }
            .prefix(60)
            .map(\.stop)
    }

    /// One line per SL line and direction among the site's bus departures over the next 20 hours
    /// (`forecast` tops out at 1,200 minutes), so a line with no bus in that window is not offered.
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        try await Self.lines(from: departures(site: stop.code, forecast: 1200), site: stop.code)
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let ref = try Ref(line)
        let sites = try await SLSites.shared.index(http)
        guard let site = Int(ref.site).flatMap({ sites.byID[$0] }) else {
            throw TransitError.notFound("site \(ref.site)")
        }
        let finder = try await http.get(
            DTO.StopFinder.self, Self.planner, "/stop-finder",
            query: ["name_sf": ref.destination, "type_sf": "any", "any_obj_filter_sf": "2"]
        )
        let candidates = (finder.locations ?? []).filter { $0.type == "stop" && $0.id != nil }
        guard let end = candidates.first(where: { $0.productClasses?.contains(5) ?? false }) ?? candidates.first,
              let endID = end.id else {
            throw TransitError.notFound("destination \(ref.destination) of line \(line.shortName)")
        }

        let trips = try? await http.get(
            DTO.Trips.self, Self.planner, "/trips",
            query: ["type_origin": "any", "name_origin": String(site.gid),
                    "type_destination": "any", "name_destination": endID,
                    "calc_number_of_trips": "3", "max_changes": "0", "gen_c": "false",
                    "incl_mot_0": "false", "incl_mot_2": "false", "incl_mot_4": "false",
                    "incl_mot_9": "false", "incl_mot_14": "false"]
        )
        let leg = (trips?.journeys ?? [])
            .flatMap(\.legs)
            .first { $0.transportation?.disassembledName == ref.designation && ($0.stopSequence?.count ?? 0) >= 2 }

        var stops: [TransitStop]
        if let sequence = leg?.stopSequence {
            stops = sequence.compactMap { $0.stop(sites: sites) }
        } else {
            stops = end.point.map { [TransitStop(code: endID, name: end.disassembledName ?? end.name ?? ref.destination,
                                                 city: end.parent?.name, location: $0)] } ?? []
            stops.insert(site.stop, at: 0)
        }
        // The planner starts at one platform of the site; the board finds the rider's stop by code.
        if !stops.isEmpty { stops[0] = site.stop }
        // Two platforms of one site in a row read as the same stop once named after the site.
        stops = stops.enumerated().filter { $0.offset == 0 || stops[$0.offset - 1].code != $0.element.code }.map(\.element)
        guard stops.count >= 2 else { throw TransitError.notFound("stops for line \(line.id)") }
        return RoutePattern(
            line: line,
            stops: stops.enumerated().map { PatternStop(stop: $1, sequence: $0 + 1, distanceAlongRoute: nil) }
        )
    }

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }

    /// Departures of this line and direction at the site. `expected` is a prediction only when the
    /// journey carries a `prediction_state` (it is running and tracked); otherwise it just repeats
    /// the timetable.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let ref = try Ref(line)
        return try await departures(site: stop.code, forecast: 180, line: ref.line)
            .compactMap { departure -> Arrival? in
                guard departure.line?.id.map(String.init) == ref.line,
                      departure.directionCode.map(String.init) == ref.direction,
                      !departure.isCancelled,
                      let scheduled = departure.scheduled.flatMap(DTO.parseLocal) else { return nil }
                // "LOSTCONTACT" is the last prediction before the bus went quiet: timetable it is.
                let isRealtime = departure.journey?.predictionState.map { $0 != "LOSTCONTACT" } ?? false
                let expected = departure.expected.flatMap(DTO.parseLocal)
                return Arrival(
                    expectedAt: (isRealtime ? expected : nil) ?? scheduled,
                    scheduledAt: scheduled,
                    isRealtime: isRealtime,
                    tripId: departure.journey?.id.map(String.init)
                )
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// Sites within the radius from the cached list; the bus lines of the nearest eight come from
    /// their next hour of departures, one call each. Sites with no bus in that hour are skipped.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let sites = try await SLSites.shared.index(http)
        let candidates = sites.all
            .map { ($0, RouteGeometry.meters(point, $0.stop.location)) }
            .filter { $0.1 <= radiusMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(8)
        let found = try await withThrowingTaskGroup(of: NearbyStop?.self) { group in
            for (site, distance) in candidates {
                group.addTask {
                    let lines = try await Self.lines(from: departures(site: site.stop.code, forecast: 60), site: site.stop.code)
                    return lines.isEmpty ? nil : NearbyStop(stop: site.stop, distanceMeters: distance, lines: lines)
                }
            }
            var result: [NearbyStop] = []
            for try await stop in group { if let stop { result.append(stop) } }
            return result
        }
        return found.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    // MARK: - Helpers

    private func departures(site: String, forecast: Int, line: String? = nil) async throws -> [DTO.Departure] {
        var query = ["transport": "BUS", "forecast": String(forecast)]
        if let line { query["line"] = line }
        return try await http.get(DTO.Departures.self, Self.base, "/sites/\(site)/departures", query: query).departures ?? []
    }

    private static func lines(from departures: [DTO.Departure], site: String) -> [TransitLine] {
        var groups: [String: [DTO.Departure]] = [:]
        var order: [String] = []
        for departure in departures {
            guard let lineID = departure.line?.id, let direction = departure.directionCode,
                  departure.line?.transportMode == nil || departure.line?.transportMode == "BUS" else { continue }
            let key = "\(lineID)-\(direction)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(departure)
        }
        return order.compactMap { key -> TransitLine? in
            guard let group = groups[key], let first = group.first, let lineID = first.line?.id,
                  let direction = first.directionCode else { return nil }
            let destinations = group.compactMap(\.destination)
            let destination = mostCommon(destinations) ?? first.direction ?? ""
            let designation = first.line?.designation ?? String(lineID)
            return TransitLine(
                id: key,
                shortName: designation,
                headsign: destination,
                agency: "SL",
                origin: first.stopArea?.name,
                destination: destination,
                providerRefs: ["line": String(lineID), "direction": String(direction), "designation": designation,
                               "destination": destination, "site": site]
            )
        }
    }

    private static func mostCommon(_ values: [String]) -> String? {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return values.max { counts[$0]! < counts[$1]! }
    }

    private nonisolated struct Ref {
        var line: String
        var direction: String
        var designation: String
        var destination: String
        var site: String

        init(_ line: TransitLine) throws {
            guard let id = line.providerRefs["line"], let direction = line.providerRefs["direction"],
                  let site = line.providerRefs["site"] else {
                throw TransitError.unsupported("line \(line.id) has no SL refs (was it loaded from another provider?)")
            }
            self.line = id
            self.direction = direction
            self.site = site
            designation = line.providerRefs["designation"] ?? line.shortName
            destination = line.providerRefs["destination"] ?? line.headsign ?? ""
        }
    }
}

/// Every SL site, fetched once per session (see the provider's note on size). A failed load is
/// forgotten so the next call retries.
private actor SLSites {
    static let shared = SLSites()

    nonisolated struct Site: Sendable {
        var stop: TransitStop
        var gid: Int64
        var folded: String
    }

    nonisolated struct Index: Sendable {
        var all: [Site]
        var byID: [Int: Site]
        /// Stop-area id → site, to name the planner's stops by the site riders pick.
        var siteOfArea: [Int: Site]
    }

    private var task: Task<Index, any Error>?

    nonisolated static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "sv_SE"))
    }

    func index(_ http: HTTPClient) async throws -> Index {
        if let task { return try await task.value }
        let task = Task {
            let raw = try await http.get([DTO.Site].self, SLProvider.base, "/sites", query: ["expand": "true"])
            var byID: [Int: Site] = [:]
            var siteOfArea: [Int: Site] = [:]
            for s in raw {
                guard let lat = s.lat, let lon = s.lon, let name = s.name else { continue }
                let site = Site(stop: TransitStop(code: String(s.id), name: name, city: s.note, location: GeoPoint(lat: lat, lon: lon)),
                                gid: s.gid ?? (9_091_001_000_000_000 + Int64(s.id)), folded: Self.fold(name))
                byID[s.id] = site
                for area in s.stopAreas ?? [] where siteOfArea[area] == nil { siteOfArea[area] = site }
            }
            return Index(all: Array(byID.values), byID: byID, siteOfArea: siteOfArea)
        }
        self.task = task
        do { return try await task.value } catch { self.task = nil; throw error }
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct Site: Decodable, Sendable {
        var id: Int
        var gid: Int64?
        var name: String?
        var note: String?
        var lat: Double?
        var lon: Double?
        var stopAreas: [Int]?

        enum CodingKeys: String, CodingKey { case id, gid, name, note, lat, lon, stopAreas = "stop_areas" }
    }

    struct Departures: Decodable, Sendable { var departures: [Departure]? }

    struct Departure: Decodable, Sendable {
        struct Journey: Decodable, Sendable {
            var id: Int64?
            var state: String?
            var predictionState: String?
            enum CodingKeys: String, CodingKey { case id, state, predictionState = "prediction_state" }
        }
        struct Line: Decodable, Sendable {
            var id: Int?
            var designation: String?
            var transportMode: String?
            enum CodingKeys: String, CodingKey { case id, designation, transportMode = "transport_mode" }
        }
        struct Area: Decodable, Sendable { var name: String? }

        var destination: String?
        var direction: String?
        var directionCode: Int?
        var state: String?
        var scheduled: String?
        var expected: String?
        var journey: Journey?
        var line: Line?
        var stopArea: Area?

        enum CodingKeys: String, CodingKey {
            case destination, direction, state, scheduled, expected, journey, line
            case directionCode = "direction_code", stopArea = "stop_area"
        }

        /// PubTrans states (as listed by trafiklab-sl): NOTCALLED is a skipped stop, REPLACED a
        /// departure run by another journey; a journey NOTEXPECTED/NOTRUN/ABORTED will not come.
        var isCancelled: Bool {
            ["CANCELLED", "INHIBITED", "NOTEXPECTED", "NOTCALLED", "REPLACED"].contains(state ?? "")
                || ["CANCELLED", "NOTEXPECTED", "NOTRUN", "ABORTED"].contains(journey?.state ?? "")
        }
    }

    struct StopFinder: Decodable, Sendable { var locations: [Location]? }

    struct Parent: Decodable, Sendable {
        struct Properties: Decodable, Sendable { var stopId: String? }
        var id: String?
        var name: String?
        var disassembledName: String?
        var properties: Properties?
    }

    struct Location: Decodable, Sendable {
        var id: String?
        var name: String?
        var disassembledName: String?
        var type: String?
        var coord: [Double]?
        var productClasses: [Int]?
        var parent: Parent?

        /// EFA puts latitude first.
        var point: GeoPoint? {
            guard let coord, coord.count == 2 else { return nil }
            return GeoPoint(lat: coord[0], lon: coord[1])
        }

        /// A platform of the planner, named after the SL site its stop area belongs to when there
        /// is one ("18010591" is stop area 10591).
        func stop(sites: SLSites.Index) -> TransitStop? {
            let area = (parent?.properties?.stopId).flatMap(Int.init).map { $0 - 18_000_000 }
            if let area, let site = sites.siteOfArea[area] { return site.stop }
            guard let point, let code = parent?.id ?? id else { return nil }
            return TransitStop(code: code, name: parent?.disassembledName ?? disassembledName ?? name ?? code,
                               city: nil, location: point)
        }
    }

    struct Trips: Decodable, Sendable {
        struct Journey: Decodable, Sendable { var legs: [Leg] }
        struct Leg: Decodable, Sendable {
            struct Transportation: Decodable, Sendable { var disassembledName: String? }
            var transportation: Transportation?
            var stopSequence: [Location]?
        }
        var journeys: [Journey]?
    }

    /// "2026-09-22T14:35:00", Stockholm local time.
    static func parseLocal(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = SLProvider.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: string)
    }
}
