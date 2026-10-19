import Foundation

/// Kraków, Poland — MPK Kraków's TTSS ("Tram and Train Sorting System", Trapeze's passenger web
/// service), the unofficial backend of the operator's own live-departures site. Keyless, with no
/// published terms or rate limits, so the region is experimental. See docs/research/worldwide-apis.md §6.8.
///
/// Buses only. The bus TTSS (`ttss.mpk.krakow.pl`) carries every MPK and agglomeration bus line;
/// trams live on a separate TTSS (`www.ttss.krakow.pl`), which refused connections from every vantage
/// tried in September 2026. The bus host's search does list tram-only stops, but they have no
/// passages there, so stops come from its stop layer instead, which is buses only.
///
/// Calls, all JSON on `/internetservice`:
/// - `geoserviceDispatcher/services/stopinfo/stops?left=&bottom=&right=&top=` over the whole world:
///   every bus stop with its coordinates (~255 KB, ~53 KB gzipped), fetched once per service day. Search
///   and nearby are answered from it, so the rider's location never leaves the phone.
/// - `services/passageInfo/stopPassages/stop?stop=&mode=departure&timeFrame=` (~6–15 KB): the stop's
///   routes and its departures of the next ~90 minutes, each with its trip, predicted or planned.
/// - `services/tripInfo/tripPassages?tripId=` (~3 KB): the stops a trip still has ahead of it — its
///   whole pattern while it has not yet left the first one.
/// - `geoserviceDispatcher/services/vehicleinfo/vehicles` (~125 KB, ~29 KB gzipped): the whole fleet.
///   There is no per-route or bounding-box variant. ZTP's official GTFS-RT (`VehiclePositions_A.pb`,
///   ~50 KB, served uncompressed) is larger on the wire and its trip ids are GTFS ones that TTSS
///   never mentions, so it cannot be tied to a TTSS line.
///
/// A "stop" is a stop area coded by its TTSS short name ("125"), the number `stopPassages` takes.
/// Coordinates are integer milliarcseconds (degrees × 3,600,000); times are "HH:mm", Warsaw time.
nonisolated struct KrakowProvider: TransitProvider {
    let id = "mpk-krakow"
    let displayName = "MPK Kraków (TTSS)"
    /// No licence is published; the source is credited all the same, as for Tallinn.
    let attribution: String? = "Dane: MPK S.A. w Krakowie (ttss.mpk.krakow.pl)"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .scheduledArrivals, .nearbyStops,
    ]
    /// The vehicle layer moves on every few seconds; one fleet-wide call (~29 KB gzipped) per poll.
    let suggestedRefreshInterval: Duration = .seconds(20)

    var http = HTTPClient()

    static let timeZone = TimeZone(identifier: "Europe/Warsaw")!
    fileprivate static let base = "https://ttss.mpk.krakow.pl/internetservice"

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let directory = try await KrakowStops.shared.today(http)
        if let exact = directory.byCode[query] { return [exact.stop] }
        let words = KrakowStops.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let needle = words.joined(separator: " ")
        return directory.all
            .filter { entry in words.allSatisfy { entry.folded.contains($0) } }
            .sorted { a, b in
                let aPrefix = a.folded.hasPrefix(needle), bPrefix = b.folded.hasPrefix(needle)
                if aPrefix != bPrefix { return aPrefix }
                return (a.stop.name, a.stop.code) < (b.stop.name, b.stop.code)
            }
            .prefix(60)
            .map(\.stop)
    }

    /// One line per route and direction among the stop's departures of the next ~90 minutes. A line
    /// that does not run in that window — at night, or a rare working — cannot be picked until it does.
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        Self.lines(from: try await passages(stop: stop.code), stopCode: stop.code)
    }

    /// The stops of the line's pattern trip. TTSS only lists the stops a trip still has ahead, so the
    /// trip picked is the latest one seen at the stop; when that one has set off after all (or was
    /// yesterday's), the stop is asked again for a fresh one.
    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let ref = try Ref(line)
        let directory = try await KrakowStops.shared.today(http)
        var stops = try await patternStops(trip: ref.trip, directory: directory)
        if stops.first?.sequence != 1, let stopCode = ref.stop {
            let fresh = Self.lines(from: try await passages(stop: stopCode), stopCode: stopCode)
                .first { $0.id == line.id }?.providerRefs["trip"]
            if let fresh, fresh != ref.trip {
                let retried = try await patternStops(trip: fresh, directory: directory)
                if retried.count > stops.count { stops = retried }
            }
        }
        guard stops.count >= 2 else { throw TransitError.notFound("stops for line \(line.id)") }
        return RoutePattern(line: line, stops: stops)
    }

    /// The whole fleet, kept to this line. A vehicle's `name` is its line and headsign ("124 Os.
    /// Podwawelskie", sometimes with "przez: …" after it), but it can already show the next working,
    /// so the trips due at the rider's stop are matched too.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let ref = try Ref(line)
        async let fleetCall = http.get(DTO.Vehicles.self, Self.base, "/geoserviceDispatcher/services/vehicleinfo/vehicles")
        var trips: Set<String> = []
        if let stopCode = ref.stop, let passages = try? await passages(stop: stopCode) {
            trips = Set((passages.actual + passages.old).filter { $0.routeId == ref.route && $0.direction == ref.direction }
                .compactMap(\.tripId))
        }
        let label = "\(line.shortName) \(ref.direction)"
        return try await fleetCall.vehicles.compactMap { vehicle -> VehiclePosition? in
            guard vehicle.isDeleted != true, let lat = vehicle.latitude, let lon = vehicle.longitude,
                  let name = vehicle.name else { return nil }
            let onTrip = vehicle.tripId.map(trips.contains) ?? false
            guard onTrip || name == label || name.hasPrefix(label + " ") else { return nil }
            return VehiclePosition(
                location: DTO.point(lat, lon),
                recordedAt: nil,
                tripId: vehicle.tripId,
                bearing: vehicle.heading
            )
        }
    }

    /// `PREDICTED` and `STOPPING` passages are tracked; `PLANNED` ones are the timetable.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let ref = try Ref(line)
        let now = Date()
        return try await passages(stop: stop.code).actual
            .compactMap { passage -> Arrival? in
                guard passage.routeId == ref.route, passage.direction == ref.direction,
                      passage.status != "DEPARTED", let relative = passage.actualRelativeTime,
                      relative > -120 else { return nil }
                let expected = now.addingTimeInterval(TimeInterval(relative))
                return Arrival(
                    expectedAt: expected,
                    scheduledAt: passage.plannedTime.flatMap { DTO.clockTime($0, near: expected) },
                    isRealtime: passage.status == "PREDICTED" || passage.status == "STOPPING",
                    tripId: passage.tripId
                )
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// Stops within the radius from the day's stop layer; the lines of the nearest dozen come from
    /// their departures, one small call each. Stops with nothing departing are skipped.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let directory = try await KrakowStops.shared.today(http)
        let candidates = directory.all
            .map { ($0.stop, RouteGeometry.meters(point, $0.stop.location)) }
            .filter { $0.1 <= radiusMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(12)
        let found = try await withThrowingTaskGroup(of: NearbyStop?.self) { group in
            for (stop, distance) in candidates {
                group.addTask {
                    let lines = Self.lines(from: try await passages(stop: stop.code, minutes: 30), stopCode: stop.code)
                    return lines.isEmpty ? nil : NearbyStop(stop: stop, distanceMeters: distance, lines: lines)
                }
            }
            var result: [NearbyStop] = []
            for try await stop in group { if let stop { result.append(stop) } }
            return result
        }
        return found.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    // MARK: - Helpers

    /// The stop's passages. Without `timeFrame` TTSS answers ~20 minutes; it caps a larger one at ~90.
    private func passages(stop code: String, minutes: Int = 120) async throws -> DTO.StopPassages {
        try await http.get(DTO.StopPassages.self, Self.base, "/services/passageInfo/stopPassages/stop",
                           query: ["stop": code, "mode": "departure", "timeFrame": String(minutes)])
    }

    private func patternStops(trip: String, directory: KrakowStops.Day) async throws -> [PatternStop] {
        let response = try await http.get(DTO.TripPassages.self, Self.base, "/services/tripInfo/tripPassages",
                                          query: ["tripId": trip, "mode": "departure"])
        var seen = Set<Int>()
        return (response.old + response.actual)
            .compactMap { passage -> PatternStop? in
                // Stops the stop layer does not know (tram-only platforms, depots) have no coordinates.
                guard let sequence = passage.stopSeqNum.flatMap(Int.init), seen.insert(sequence).inserted,
                      let code = passage.stop?.shortName, let stop = directory.byCode[code]?.stop else { return nil }
                return PatternStop(stop: stop, sequence: sequence, distanceAlongRoute: nil)
            }
            .sorted { $0.sequence < $1.sequence }
    }

    /// Workings that carry no passengers: depot runs and positioning moves.
    private static let technicalDirections: Set<String> = [
        "Wyjazd na linię", "Zjazd do zajezdni", "Przejazd techniczny", "Zajezdnia Nowa Huta", "Zajezdnia Podgórze",
    ]

    private static func lines(from passages: DTO.StopPassages, stopCode: String) -> [TransitLine] {
        var groups: [String: [DTO.Passage]] = [:]
        var order: [String] = []
        for passage in passages.actual {
            guard let route = passage.routeId, let direction = passage.direction, passage.tripId != nil,
                  !technicalDirections.contains(direction) else { continue }
            let key = "\(route)-\(direction)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(passage)
        }
        let routes = Dictionary((passages.routes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return order.compactMap { key -> TransitLine? in
            // Passages come soonest first, so the last one is the trip least likely to have set off.
            guard let group = groups[key], let first = group.first, let last = group.last,
                  let route = first.routeId, let direction = first.direction, let trip = last.tripId else { return nil }
            let shortName = first.patternText ?? routes[route]?.shortName ?? routes[route]?.name ?? route
            return TransitLine(
                id: key,
                shortName: shortName,
                headsign: direction,
                agency: "MPK Kraków",
                destination: direction,
                providerRefs: ["route": route, "direction": direction, "trip": trip, "stop": stopCode]
            )
        }
    }

    /// Route, direction and pattern trip of a line. Line ids are `{routeId}-{direction}`.
    private nonisolated struct Ref {
        var route: String
        var direction: String
        var trip: String
        var stop: String?

        init(_ line: TransitLine) throws {
            guard let route = line.providerRefs["route"], let direction = line.providerRefs["direction"],
                  let trip = line.providerRefs["trip"] else {
                throw TransitError.unsupported("line \(line.id) has no TTSS refs (was it loaded from another provider?)")
            }
            self.route = route
            self.direction = direction
            self.trip = trip
            self.stop = line.providerRefs["stop"]
        }
    }
}

/// The bus stop layer (~255 KB of JSON), fetched once per Warsaw service date and shared by every
/// call. A failed load is forgotten so the next call retries.
private actor KrakowStops {
    static let shared = KrakowStops()

    nonisolated struct Entry: Sendable {
        var stop: TransitStop
        var folded: String
    }

    nonisolated struct Day: Sendable {
        var all: [Entry]
        var byCode: [String: Entry]
    }

    private var loaded: (date: String, task: Task<Day, any Error>)?

    nonisolated static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .replacingOccurrences(of: "ł", with: "l")
    }

    func today(_ http: HTTPClient) async throws -> Day {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = KrakowProvider.timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: Date())
        let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        if let loaded, loaded.date == date { return try await loaded.task.value }
        let task = Task { try await Self.load(http) }
        loaded = (date, task)
        do { return try await task.value } catch { loaded = nil; throw error }
    }

    /// The layer is a bounding-box query; the whole world's box returns every stop, and carries no
    /// location of the rider's.
    private static func load(_ http: HTTPClient) async throws -> Day {
        let response = try await http.get(
            DTO.Stops.self, KrakowProvider.base, "/geoserviceDispatcher/services/stopinfo/stops",
            query: ["left": "-648000000", "bottom": "-324000000", "right": "648000000", "top": "324000000"]
        )
        var byCode: [String: Entry] = [:]
        for s in response.stops {
            guard let code = s.shortName, let name = s.name, let lat = s.latitude, let lon = s.longitude,
                  byCode[code] == nil else { continue }
            let stop = TransitStop(code: code, name: name, city: nil, location: DTO.point(lat, lon))
            byCode[code] = Entry(stop: stop, folded: fold(name))
        }
        return Day(all: Array(byCode.values), byCode: byCode)
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct Stops: Decodable, Sendable { var stops: [Stop] }

    struct Stop: Decodable, Sendable {
        var shortName: String?
        var name: String?
        var latitude: Double?
        var longitude: Double?
    }

    struct StopPassages: Decodable, Sendable {
        var actual: [Passage]
        var old: [Passage]
        var routes: [Route]?
    }

    struct Route: Decodable, Sendable {
        var id: String
        var name: String?
        var shortName: String?
    }

    struct Passage: Decodable, Sendable {
        var routeId: String?
        var patternText: String?
        var direction: String?
        var tripId: String?
        var status: String?
        var plannedTime: String?
        var actualRelativeTime: Int?
    }

    struct TripPassages: Decodable, Sendable {
        var actual: [TripPassage]
        var old: [TripPassage]
    }

    struct TripPassage: Decodable, Sendable {
        struct Stop: Decodable, Sendable { var shortName: String? }
        var stop: Stop?
        var stopSeqNum: String?

        enum CodingKeys: String, CodingKey {
            case stop
            case stopSeqNum = "stop_seq_num"
        }
    }

    struct Vehicles: Decodable, Sendable { var vehicles: [Vehicle] }

    struct Vehicle: Decodable, Sendable {
        var isDeleted: Bool?
        var name: String?
        var tripId: String?
        var latitude: Double?
        var longitude: Double?
        var heading: Double?
    }

    /// Milliarcseconds to degrees.
    static func point(_ lat: Double, _ lon: Double) -> GeoPoint {
        GeoPoint(lat: lat / 3_600_000, lon: lon / 3_600_000)
    }

    /// "15:47", Warsaw time, as the instant nearest `reference` — a planned time can fall on either
    /// side of midnight from the prediction.
    static func clockTime(_ string: String, near reference: Date) -> Date? {
        let parts = string.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = KrakowProvider.timeZone
        let candidates = [-1, 0, 1].compactMap { offset -> Date? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: reference) else { return nil }
            return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
        }
        return candidates.min { abs($0.timeIntervalSince(reference)) < abs($1.timeIntervalSince(reference)) }
    }
}
