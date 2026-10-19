import Foundation

/// Gdańsk, Sopot and parts of Gdynia, Poland — ZTM w Gdańsku open data ("Otwarte dane ZTM w
/// Gdańsku", ckan.multimediagdansk.pl), official and keyless. The terms (Regulamin, 2024-01-08) ask
/// reusers to name the source — Zarząd Transportu Miejskiego w Gdańsku, with the portal's URL where
/// possible — and say nothing about rate limits. See docs/research/worldwide-apis.md §6.8.
///
/// The published ordered-pattern file (`stopsintrip.json`) is a 31.8 MB, fourteen-day dump that the
/// server neither compresses nor serves by range, so it is never touched. The same backend answers
/// three undocumented but light per-day calls instead, which is what this adapter uses:
/// - `stops?date=` (~1.2 MB, every bollard in use that day, Gdynia's ZKM ones included) and
///   `trips?date=` (~280 KB, every route variant with its direction), fetched once per service day;
/// - `stopsInTrip?date=&routeId=&tripId=` (~8 KB), the ordered stops of one variant.
///
/// There is no stop → lines index short of that dump, so the lines at a stop are the ones in its
/// live departures (`departures?stopId=`, the next ~30 minutes). A line that does not run in that
/// window — at night, or a rare variant — cannot be picked until it does.
///
/// A "stop" is one bollard (słupek), coded by its numeric `stopId`: the number the departures call
/// takes and the one printed on the post. Times on the wire are UTC (`…Z`).
nonisolated struct GdanskProvider: TransitProvider {
    let id = "ztm-gdansk"
    let displayName = "ZTM Gdańsk (Gdańsk, Sopot)"
    let attribution: String? = "Źródło danych: Zarząd Transportu Miejskiego w Gdańsku (ztm.gda.pl/otwarty_ztm)"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .scheduledArrivals, .nearbyStops, .routeShape,
    ]
    /// `gpsPositions` is regenerated every ~10–20 s; one fleet-wide call (~115 KB) per poll.
    let suggestedRefreshInterval: Duration = .seconds(20)

    var http = HTTPClient()

    static let timeZone = TimeZone(identifier: "Europe/Warsaw")!
    fileprivate static let base = "https://ckan2.multimediagdansk.pl"

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let data = try await GdanskReference.shared.today(http)
        if let id = Int(query) {
            return data.stops[id].map { [$0.stop] } ?? []
        }
        let words = GdanskReference.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let needle = words.joined(separator: " ")
        return data.passengerStops
            .filter { entry in words.allSatisfy { entry.folded.contains($0) } }
            .sorted { a, b in
                let aPrefix = a.folded.hasPrefix(needle), bPrefix = b.folded.hasPrefix(needle)
                if aPrefix != bPrefix { return aPrefix }
                return (a.stop.name, a.stop.code) < (b.stop.name, b.stop.code)
            }
            .prefix(60)
            .map(\.stop)
    }

    /// One line per route and direction among the stop's upcoming departures. Its pattern is the
    /// variant seen departing — the route's MAIN variant when that one is among them, so short
    /// workings and depot runs do not stand in for the whole line.
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        guard let stopID = Int(stop.code) else { return [] }
        async let departuresCall = departures(stopID: stopID)
        let data = try await GdanskReference.shared.today(http)
        let departures = try await departuresCall
        return Self.lines(from: departures, stopID: stopID, data: data)
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let ref = try Ref(line)
        let data = try await GdanskReference.shared.today(http)
        let response = try await http.get(
            DTO.StopsInTrip.self, Self.base, "/stopsInTrip",
            query: ["date": data.date, "routeId": String(ref.route), "tripId": String(ref.trip)]
        )
        // Non-passenger points (depot approaches, technical stops) are left out; `passenger` is
        // null for ordinary stops, so only an explicit false drops one.
        let ordered = response.stopsInTrip
            .filter { $0.passenger != false }
            .sorted { $0.stopSequence < $1.stopSequence }
        var seen = Set<Int>()
        let stops = ordered.compactMap { entry -> PatternStop? in
            guard seen.insert(entry.stopSequence).inserted, let stop = data.stops[entry.stopId]?.stop else { return nil }
            return PatternStop(stop: stop, sequence: entry.stopSequence, distanceAlongRoute: nil)
        }
        guard stops.count >= 2 else { throw TransitError.notFound("stops for line \(line.id)") }
        return RoutePattern(line: line, stops: stops)
    }

    /// The variant's own course (`shapes?date=&routeId=&tripId=`, ~15–19 KB, sent uncompressed),
    /// the very triple the stop list was asked with. The operator lists these URLs as its official
    /// "Lista przebiegów tras". GeoJSON, so lon,lat.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        let ref = try Ref(line)
        let date = GdanskReference.serviceDate()
        let response = try await http.get(DTO.Shape.self, Self.base, "/shapes",
                                          query: ["date": date, "routeId": String(ref.route), "tripId": String(ref.trip)])
        let points = response.coordinates.compactMap { $0.count >= 2 ? GeoPoint(lat: $0[1], lon: $0[0]) : nil }
        return RouteShape(points, version: "\(ref.route)/\(ref.trip)")
    }

    /// Every vehicle in the network (~350, ~115 KB), kept to this route and direction; the variant
    /// a vehicle runs (`tripId`) gives its direction through the day's trip list.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let ref = try Ref(line)
        async let positions = http.get(DTO.Positions.self, Self.base, "/gpsPositions", query: ["v": "2"])
        let data = try await GdanskReference.shared.today(http)
        return try await positions.vehicles.compactMap { vehicle -> VehiclePosition? in
            guard vehicle.routeId == ref.route,
                  data.direction(route: vehicle.routeId, trip: vehicle.tripId) == ref.direction,
                  let lat = vehicle.lat, let lon = vehicle.lon else { return nil }
            return VehiclePosition(
                location: GeoPoint(lat: lat, lon: lon),
                recordedAt: vehicle.generated.flatMap(DTO.parseDate),
                tripId: vehicle.tripId.map { String($0) },
                plateNumber: vehicle.vehicleCode,
                bearing: vehicle.direction,
                speedKmh: vehicle.speed,
                aimedDeparture: vehicle.scheduledTripStartTime.flatMap(DTO.parseDate)
            )
        }
    }

    /// `status` is REALTIME when the estimate comes from a tracked vehicle, SCHEDULED otherwise
    /// (the estimate is then the timetable).
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let ref = try Ref(line)
        guard let stopID = Int(stop.code) else { return [] }
        async let departuresCall = departures(stopID: stopID)
        let data = try await GdanskReference.shared.today(http)
        return try await departuresCall
            .compactMap { departure -> Arrival? in
                guard departure.routeId == ref.route,
                      data.direction(route: departure.routeId, trip: departure.tripId) == ref.direction,
                      data.isBoardable(route: departure.routeId, trip: departure.tripId, at: stopID),
                      let theoretical = departure.theoreticalTime.flatMap(DTO.parseDate) else { return nil }
                let isRealtime = departure.status == "REALTIME"
                let estimated = departure.estimatedTime.flatMap(DTO.parseDate)
                return Arrival(
                    expectedAt: (isRealtime ? estimated : nil) ?? theoretical,
                    scheduledAt: theoretical,
                    isRealtime: isRealtime,
                    tripId: departure.trip.map { String($0) }
                )
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// Bollards within the radius from the day's stop list; the lines of the nearest dozen come
    /// from their live departures, one small call each. Stops with nothing departing are skipped.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let data = try await GdanskReference.shared.today(http)
        let candidates = data.passengerStops
            .map { ($0, RouteGeometry.meters(point, $0.stop.location)) }
            .filter { $0.1 <= radiusMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(12)
        let found = try await withThrowingTaskGroup(of: NearbyStop?.self) { group in
            for (entry, distance) in candidates {
                group.addTask {
                    let departures = try await departures(stopID: entry.id)
                    let lines = Self.lines(from: departures, stopID: entry.id, data: data)
                    return lines.isEmpty ? nil : NearbyStop(stop: entry.stop, distanceMeters: distance, lines: lines)
                }
            }
            var result: [NearbyStop] = []
            for try await stop in group { if let stop { result.append(stop) } }
            return result
        }
        return found.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    // MARK: - Helpers

    private func departures(stopID: Int) async throws -> [DTO.Departure] {
        try await http.get(DTO.Departures.self, Self.base, "/departures", query: ["stopId": String(stopID)]).departures
    }

    private static func lines(from departures: [DTO.Departure], stopID: Int, data: GdanskReference.Day) -> [TransitLine] {
        var groups: [String: [DTO.Departure]] = [:]
        var order: [String] = []
        for departure in departures {
            guard let route = departure.routeId, let trip = departure.tripId,
                  data.isBoardable(route: route, trip: trip, at: stopID) else { continue }
            let direction = data.direction(route: route, trip: trip) ?? "v\(trip)"
            let key = "\(route)-\(direction)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(departure)
        }
        return order.compactMap { key -> TransitLine? in
            guard let group = groups[key], let first = group.first, let route = first.routeId else { return nil }
            let direction = String(key.dropFirst(String(route).count + 1))
            let variants = group.compactMap(\.tripId)
            let variant = variants.first { data.trips[GdanskReference.key(route, $0)]?.type == "MAIN" }
                ?? mostCommon(variants) ?? variants[0]
            let headsign = mostCommon(group.compactMap(\.headsign))
            let ends = data.trips[GdanskReference.key(route, variant)]?.ends
            return TransitLine(
                id: key,
                shortName: first.routeShortName ?? String(route),
                headsign: headsign,
                agency: "ZTM Gdańsk",
                origin: ends?.origin,
                destination: ends?.destination ?? headsign,
                providerRefs: ["route": String(route), "direction": direction, "trip": String(variant),
                               "stop": String(stopID)]
            )
        }
    }

    private static func mostCommon<T: Hashable>(_ values: [T]) -> T? {
        var counts: [T: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return values.max { counts[$0]! < counts[$1]! }
    }

    /// Route, direction and pattern variant of a line. Line ids are `{routeId}-{direction}`.
    private nonisolated struct Ref {
        var route: Int
        var direction: String
        var trip: Int

        init(_ line: TransitLine) throws {
            guard let route = line.providerRefs["route"].flatMap(Int.init),
                  let direction = line.providerRefs["direction"],
                  let trip = line.providerRefs["trip"].flatMap(Int.init) else {
                throw TransitError.unsupported("line \(line.id) has no ZTM Gdańsk refs (was it loaded from another provider?)")
            }
            self.route = route
            self.direction = direction
            self.trip = trip
        }
    }
}

/// The day's stop and trip lists (~1.2 MB + ~280 KB of JSON), fetched once per Warsaw service
/// date and shared by every call. A failed load is forgotten so the next call retries.
private actor GdanskReference {
    static let shared = GdanskReference()

    nonisolated struct StopEntry: Sendable {
        var id: Int
        var stop: TransitStop
        var folded: String
        var forPassengers: Bool
    }

    nonisolated struct TripEntry: Sendable {
        var direction: String
        var type: String?
        var ends: (origin: String?, destination: String?)
        /// The bollard the variant ends at, from the "(1016)" its headsign closes with.
        var lastStopID: Int?
    }

    nonisolated struct Day: Sendable {
        var date: String
        var stops: [Int: StopEntry]
        var passengerStops: [StopEntry]
        var trips: [String: TripEntry]

        func direction(route: Int?, trip: Int?) -> String? {
            guard let route, let trip else { return nil }
            return trips[GdanskReference.key(route, trip)]?.direction
        }

        /// The departures list also shows buses that end at the stop and depot runs; neither can
        /// be boarded there, so neither makes a line or an arrival.
        func isBoardable(route: Int?, trip: Int?, at stopID: Int) -> Bool {
            guard let route, let trip, let entry = trips[GdanskReference.key(route, trip)] else { return true }
            return entry.type != "NON_PASSENGER" && entry.lastStopID != stopID
        }
    }

    private var loaded: (date: String, task: Task<Day, any Error>)?

    nonisolated static func key(_ route: Int, _ trip: Int) -> String { "\(route):\(trip)" }

    nonisolated static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .replacingOccurrences(of: "ł", with: "l")
    }

    /// Today in Warsaw, "yyyy-MM-dd": what every per-day call takes.
    nonisolated static func serviceDate() -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = GdanskProvider.timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func today(_ http: HTTPClient) async throws -> Day {
        let date = Self.serviceDate()
        if let loaded, loaded.date == date { return try await loaded.task.value }
        let task = Task { try await Self.load(date: date, http: http) }
        loaded = (date, task)
        do { return try await task.value } catch { loaded = nil; throw error }
    }

    private static func load(date: String, http: HTTPClient) async throws -> Day {
        async let stopsCall = http.get(DTO.Stops.self, GdanskProvider.base, "/stops", query: ["date": date])
        async let tripsCall = http.get(DTO.Trips.self, GdanskProvider.base, "/trips", query: ["date": date])
        let (stopList, tripList) = try await (stopsCall.stops, tripsCall.trips)

        var stops: [Int: StopEntry] = [:]
        for s in stopList {
            guard let lat = s.stopLat, let lon = s.stopLon else { continue }
            // Several bollards share a name; the two-digit post number tells them apart.
            let base = s.stopName ?? s.stopDesc ?? String(s.stopId)
            let name = [base, s.stopCode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            let stop = TransitStop(code: String(s.stopId), name: name, city: s.zoneName,
                                   location: GeoPoint(lat: lat, lon: lon))
            let forPassengers = s.nonpassenger != 1 && s.depot != 1 && s.virtual != 1
            stops[s.stopId] = StopEntry(id: s.stopId, stop: stop,
                                        folded: fold([name, s.stopDesc].compactMap { $0 }.joined(separator: " ")),
                                        forPassengers: forPassengers)
        }
        var trips: [String: TripEntry] = [:]
        for t in tripList {
            guard let route = t.routeId, let trip = t.tripId else { continue }
            trips[key(route, trip)] = TripEntry(direction: t.directionId.map { String($0) } ?? "v\(trip)",
                                                type: t.type, ends: DTO.ends(of: t.tripHeadsign),
                                                lastStopID: DTO.lastStopID(of: t.tripHeadsign))
        }
        return Day(date: date, stops: stops, passengerStops: stops.values.filter(\.forPassengers), trips: trips)
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct Stops: Decodable, Sendable { var stops: [Stop] }

    struct Stop: Decodable, Sendable {
        var stopId: Int
        var stopCode: String?
        var stopName: String?
        var stopDesc: String?
        var zoneName: String?
        var stopLat: Double?
        var stopLon: Double?
        var nonpassenger: Int?
        var depot: Int?
        var virtual: Int?
    }

    struct Trips: Decodable, Sendable { var trips: [Trip] }

    struct Trip: Decodable, Sendable {
        var routeId: Int?
        var tripId: Int?
        var tripHeadsign: String?
        var directionId: Int?
        var type: String?
    }

    struct StopsInTrip: Decodable, Sendable { var stopsInTrip: [StopInTrip] }

    struct StopInTrip: Decodable, Sendable {
        var stopId: Int
        var stopSequence: Int
        var passenger: Bool?
    }

    /// A GeoJSON LineString: `[[lon, lat], …]`.
    struct Shape: Decodable, Sendable { var coordinates: [[Double]] }

    struct Departures: Decodable, Sendable { var departures: [Departure] }

    struct Departure: Decodable, Sendable {
        var routeId: Int?
        var routeShortName: String?
        var tripId: Int?
        var trip: Int?
        var headsign: String?
        var theoreticalTime: String?
        var estimatedTime: String?
        var status: String?
    }

    struct Positions: Decodable, Sendable { var vehicles: [Vehicle] }

    struct Vehicle: Decodable, Sendable {
        var generated: String?
        var routeId: Int?
        var tripId: Int?
        var vehicleCode: String?
        var speed: Double?
        var direction: Double?
        var scheduledTripStartTime: String?
        var lat: Double?
        var lon: Double?
    }

    /// "Baza Hallera(300) - Pruszcz Komarowo(171)" → the two ends, without their stop numbers.
    static func ends(of headsign: String?) -> (origin: String?, destination: String?) {
        guard let headsign else { return (nil, nil) }
        let parts = headsign.components(separatedBy: " - ").map { part in
            part.replacingOccurrences(of: #"\(\d+\)\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        guard parts.count >= 2 else { return (nil, parts.first) }
        return (parts.first, parts.last)
    }

    static func lastStopID(of headsign: String?) -> Int? {
        guard let headsign, let range = headsign.range(of: #"\((\d+)\)\s*$"#, options: .regularExpression) else { return nil }
        return Int(headsign[range].filter(\.isNumber))
    }

    /// "2026-09-22T12:41:57Z"
    static func parseDate(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }
}
