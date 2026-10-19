import Foundation

/// Great Britain — bustimes.org, a volunteer-run site (one developer, source MPL-2.0 on GitHub) that
/// aggregates the DfT Bus Open Data Service, TNDS, NaPTAN and operators' own feeds. UNOFFICIAL: it
/// publishes no API terms, SLA or rate limit; its `/api/` is a Django REST browsable API that
/// `robots.txt` asks crawlers to stay out of, and its data-sources page only says "Contains public
/// sector information licensed under the Open Government Licence v3.0". It may change, rate-limit
/// or put Cloudflare in front of these endpoints at any time. See docs/research/worldwide-apis.md §6.2.
///
/// A "stop" is a NaPTAN stop point coded by its ATCO code ("1800SB04911"); search also accepts the
/// NaPTAN/SMS code printed on the flag ("MANGPJMT"). There is no name search in the API.
///
/// The stop's departures board sits behind a Cloudflare challenge, so arrivals are *estimated*
/// here: each live bus of the line (`vehicles.json?service=`) is placed on its trip's timetable
/// (`api/trips/{id}/`, ~16 KB gzipped, cached — a trip never changes), its lateness read off where
/// it is against when it was due there, and that lateness carried forward to the rider's stop. Only
/// buses already running make an estimate; there are no timetable-only arrivals.
///
/// Services run both ways, so a *line* here is a service in the direction that serves the stop,
/// told apart by the stop that follows it. Discovering them reads the day's trips of every service
/// at the stop and one trip per destination — tens of requests, done once at setup and cached by
/// the app. Times are Europe/London.
nonisolated struct BustimesProvider: TransitProvider {
    let id = "bustimes"
    let displayName = "bustimes.org (Great Britain, unofficial)"
    let attribution: String? = "Data: bustimes.org. Contains public sector information licensed under the Open Government Licence v3.0."
    let capabilities: ProviderCapabilities = [
        .stopSearchByCode, .linesAtStop, .routePattern, .vehiclePositions, .realtimeArrivals, .nearbyStops,
    ]
    /// A volunteer's server with no stated limit: one small `vehicles.json` per line per poll.
    let suggestedRefreshInterval: Duration = .seconds(30)

    var http = HTTPClient()

    static let timeZone = TimeZone(identifier: "Europe/London")!
    fileprivate static let base = "https://bustimes.org"

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !query.contains(" ") else { return [] }
        for filter in ["atco_code__iexact", "naptan_code__iexact"] {
            let page = try await http.get(DTO.Page<DTO.Stop>.self, Self.base, "/api/stops/", query: [filter: query])
            let stops = page.results.compactMap(\.stop)
            if !stops.isEmpty { return stops }
        }
        return []
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let services = try await http.get(
            DTO.Page<DTO.Service>.self, Self.base, "/api/services/", query: ["stops": stop.code, "limit": "100"]
        ).results.filter { ($0.mode ?? "bus") == "bus" }
        var lines: [TransitLine] = []
        // Four services at a time: the site is one volunteer's server.
        for chunk in stride(from: 0, to: services.count, by: 4).map({ Array(services[$0..<min($0 + 4, services.count)]) }) {
            let found = try await withThrowingTaskGroup(of: [TransitLine].self) { group in
                for service in chunk {
                    group.addTask { try await directions(of: service, at: stop.code) }
                }
                var result: [TransitLine] = []
                for try await lines in group { result += lines }
                return result
            }
            lines += found
        }
        return lines
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let ref = try await resolve(line)
        let trip: DTO.Trip
        do {
            trip = try await BustimesTrips.shared.trip(ref.trip, http)
        } catch {
            // Trip ids go when a timetable is re-imported; find the direction again from today's trips.
            guard let fresh = try await directions(of: DTO.Service(id: ref.service, lineName: line.shortName), at: ref.stop)
                .first(where: { $0.providerRefs["next"] == ref.next }),
                  let id = fresh.providerRefs["trip"].flatMap(Int.init) else { throw error }
            trip = try await BustimesTrips.shared.trip(id, http)
        }
        var stops: [PatternStop] = []
        for call in trip.times {
            guard let stop = call.stop?.stop, stops.last?.stop.code != stop.code else { continue }
            stops.append(PatternStop(stop: stop, sequence: stops.count + 1, distanceAlongRoute: nil))
        }
        guard stops.count >= 2 else { throw TransitError.notFound("stops for line \(line.id)") }
        return RoutePattern(line: line, stops: stops)
    }

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let ref = try await resolve(line)
        return try await running(ref).map(\.position)
    }

    /// Estimated from each running bus's lateness where it is now (see the type's note), soonest first.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let ref = try await resolve(line)
        let now = Date()
        return try await running(ref)
            .compactMap { bus -> Arrival? in
                guard let schedule = bus.schedule, let target = schedule.index(of: stop.code),
                      let placed = schedule.place(bus.position.location), placed.progress < Double(target),
                      let due = schedule.times[target] else { return nil }
                let seen = bus.position.recordedAt ?? now
                var delay = seen.timeIntervalSince(placed.aimed)
                // A bus waiting at its first stop before time is not early; it will leave on time.
                if placed.progress < 0.05 { delay = max(delay, 0) }
                return Arrival(expectedAt: due.addingTimeInterval(delay), scheduledAt: due, isRealtime: true,
                               tripId: bus.position.tripId, vehicleLocation: bus.position.location)
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// `stops.json` answers a bounding box with every stop and the service names calling there. Those
    /// lines are labels only; picking the stop runs `lines(atStop:)` for the real, directional ones.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let dLat = radiusMeters / 111_320
        let dLon = radiusMeters / (111_320 * max(cos(point.lat * .pi / 180), 0.1))
        let collection = try await http.get(
            DTO.StopCollection.self, Self.base, "/stops.json",
            query: ["ymin": String(point.lat - dLat), "ymax": String(point.lat + dLat),
                    "xmin": String(point.lon - dLon), "xmax": String(point.lon + dLon)]
        )
        return collection.features
            .compactMap { feature -> NearbyStop? in
                guard let stop = feature.stop, let services = feature.properties.services, !services.isEmpty else { return nil }
                let distance = RouteGeometry.meters(point, stop.location)
                guard distance <= radiusMeters else { return nil }
                let lines = services.map { name in
                    TransitLine(id: "\(name)@\(stop.code)", shortName: name, providerRefs: ["stop": stop.code])
                }
                return NearbyStop(stop: stop, distanceMeters: distance, lines: lines)
            }
            .sorted { $0.distanceMeters < $1.distanceMeters }
    }

    // MARK: - Directions

    /// The directions of one service that call at the stop (and do not end there), from one trip
    /// per destination among today's trips. Destinations whose trips leave the stop for the same
    /// next stop are one direction; its pattern is the longest of them and its headsign the
    /// commonest.
    private func directions(of service: DTO.Service, at atco: String) async throws -> [TransitLine] {
        let trips = try await todaysTrips(service: service.id)
        var byHeadsign: [String: [DTO.TripSummary]] = [:]
        for trip in trips { byHeadsign[trip.headsign ?? "", default: []].append(trip) }
        let samples = byHeadsign.sorted { $0.value.count > $1.value.count }.prefix(6)

        nonisolated struct Candidate { var headsign: String; var count: Int; var trip: DTO.Trip; var next: String }
        let candidates = try await withThrowingTaskGroup(of: Candidate?.self) { group in
            for (headsign, trips) in samples {
                group.addTask {
                    let trip = try await BustimesTrips.shared.trip(trips[0].id, http)
                    let atcos = trip.times.compactMap { $0.stop?.atcoCode }
                    guard let index = trip.times.firstIndex(where: { $0.stop?.atcoCode == atco && $0.pickUp != false }),
                          let next = trip.times[(index + 1)...].compactMap({ $0.stop?.atcoCode }).first(where: { $0 != atco }),
                          atcos.count >= 2 else { return nil }
                    return Candidate(headsign: headsign, count: trips.count, trip: trip, next: next)
                }
            }
            var result: [Candidate] = []
            for try await candidate in group { if let candidate { result.append(candidate) } }
            return result
        }

        return Dictionary(grouping: candidates, by: \.next)
            .sorted { $0.value.map(\.count).reduce(0, +) > $1.value.map(\.count).reduce(0, +) }
            .compactMap { next, group -> TransitLine? in
                guard let main = group.max(by: { $0.count < $1.count }),
                      let longest = group.max(by: { $0.trip.times.count < $1.trip.times.count }) else { return nil }
                let names = longest.trip.times.compactMap { $0.stop?.name }
                return TransitLine(
                    id: "\(service.id)@\(atco)>\(next)",
                    shortName: service.lineName ?? longest.trip.service?.lineName ?? String(service.id),
                    headsign: main.headsign.isEmpty ? names.last : main.headsign,
                    agency: longest.trip.operator?.name,
                    origin: names.first,
                    destination: names.last,
                    providerRefs: ["service": String(service.id), "stop": atco, "next": next,
                                   "trip": String(longest.trip.id),
                                   "headsigns": group.map(\.headsign).joined(separator: "|")]
                )
            }
    }

    /// Today's trips of a service, every page (a busy service runs to ~5 pages of 100).
    private func todaysTrips(service: Int) async throws -> [DTO.TripSummary] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.timeZone
        let d = calendar.dateComponents([.year, .month, .day], from: Date())
        let date = String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
        var page = try await http.get(DTO.Page<DTO.TripSummary>.self, Self.base, "/api/trips/",
                                      query: ["service": String(service), "date": date])
        var trips = page.results
        var pages = 1
        while let next = page.next, pages < 8 {
            page = try await http.get(DTO.Page<DTO.TripSummary>.self, "", next)
            trips += page.results
            pages += 1
        }
        return trips
    }

    // MARK: - Live buses

    private nonisolated struct Bus {
        var position: VehiclePosition
        var schedule: Schedule?
    }

    /// Live buses of the service in this line's direction: those whose trip calls at the rider's
    /// stop and leaves it for the same next stop. A bus with no trip is kept when its destination is
    /// one of the line's. Fixes older than 15 minutes are dropped.
    private func running(_ ref: Ref) async throws -> [Bus] {
        let vehicles = try await http.get([DTO.Vehicle].self, Self.base, "/vehicles.json", query: ["service": String(ref.service)])
        let now = Date()
        return try await withThrowingTaskGroup(of: Bus?.self) { group in
            for vehicle in vehicles {
                group.addTask {
                    guard let coordinates = vehicle.coordinates, coordinates.count == 2 else { return nil }
                    let recorded = vehicle.datetime.flatMap(DTO.parseDate)
                    if let recorded, now.timeIntervalSince(recorded) > 15 * 60 { return nil }
                    var position = VehiclePosition(
                        location: GeoPoint(lat: coordinates[1], lon: coordinates[0]),
                        recordedAt: recorded,
                        tripId: vehicle.tripId.map(String.init),
                        plateNumber: vehicle.vehicle?.registration,
                        bearing: vehicle.heading
                    )
                    guard let tripID = vehicle.tripId else {
                        return ref.headsigns.contains(vehicle.destination ?? "\u{0}") ? Bus(position: position) : nil
                    }
                    guard let trip = try? await BustimesTrips.shared.trip(tripID, http),
                          let index = trip.times.firstIndex(where: { $0.stop?.atcoCode == ref.stop }),
                          trip.times[(index + 1)...].compactMap({ $0.stop?.atcoCode }).first(where: { $0 != ref.stop }) == ref.next
                    else { return nil }
                    let schedule = Schedule(trip: trip, serviceDate: vehicle.date)
                    position.aimedDeparture = schedule.times.first ?? nil
                    return Bus(position: position, schedule: schedule)
                }
            }
            var result: [Bus] = []
            for try await bus in group { if let bus { result.append(bus) } }
            return result
        }
    }

    /// A trip's stops with their aimed times as dates on the service day, for placing a bus on it.
    private nonisolated struct Schedule {
        var codes: [String?]
        var points: [GeoPoint?]
        var times: [Date?]

        init(trip: DTO.Trip, serviceDate: String?) {
            codes = trip.times.map { $0.stop?.atcoCode }
            points = trip.times.map { $0.stop?.point }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = BustimesProvider.timeZone
            let day = serviceDate.flatMap(DTO.parseDay) ?? calendar.startOfDay(for: Date())
            var previous: Date?
            times = trip.times.map { call in
                guard let hhmm = call.aimedArrivalTime ?? call.aimedDepartureTime else { return nil }
                let parts = hhmm.split(separator: ":").compactMap { Int($0) }
                guard parts.count >= 2,
                      var date = calendar.date(bySettingHour: parts[0] % 24, minute: parts[1], second: 0, of: day) else { return nil }
                if parts[0] >= 24 { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
                // Past midnight the clock starts again at 00:00.
                while let previous, date < previous.addingTimeInterval(-3 * 3600) {
                    date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
                }
                previous = date
                return date
            }
        }

        func index(of atco: String) -> Int? { codes.firstIndex(of: atco) }

        /// Where the bus is along the trip (stop index plus fraction of the next leg) and when it
        /// was due there, from the leg it is closest to — within 1.5 km, or not at all.
        func place(_ p: GeoPoint) -> (progress: Double, aimed: Date)? {
            let legs = zip(points.indices, points.indices.dropFirst())
            var best: (distance: Double, progress: Double, aimed: Date)?
            for (i, j) in legs {
                guard let a = points[i], let b = points[j], let ta = times[i], let tb = times[j] else { continue }
                let (distance, t) = Self.project(p, a, b)
                if best == nil || distance < best!.distance {
                    best = (distance, Double(i) + t, ta.addingTimeInterval(t * tb.timeIntervalSince(ta)))
                }
            }
            guard let best, best.distance < 1_500 else { return nil }
            return (best.progress, best.aimed)
        }

        /// Distance in metres from p to segment ab, and how far along it (0…1) the nearest point is.
        private static func project(_ p: GeoPoint, _ a: GeoPoint, _ b: GeoPoint) -> (Double, Double) {
            let k = cos(a.lat * .pi / 180)
            let ax = a.lon * k, ay = a.lat, bx = b.lon * k, by = b.lat, px = p.lon * k, py = p.lat
            let dx = bx - ax, dy = by - ay
            let length = dx * dx + dy * dy
            let t = length == 0 ? 0 : min(max(((px - ax) * dx + (py - ay) * dy) / length, 0), 1)
            let nearest = GeoPoint(lat: ay + t * dy, lon: (ax + t * dx) / k)
            return (RouteGeometry.meters(p, nearest), t)
        }
    }

    // MARK: - Line references

    private nonisolated struct Ref {
        var service: Int
        var stop: String
        var next: String
        var trip: Int
        var headsigns: Set<String>
    }

    /// A line from `lines(atStop:)` carries everything; a label from the nearby list is looked up
    /// at its stop by name first.
    private func resolve(_ line: TransitLine) async throws -> Ref {
        var refs = line.providerRefs
        if refs["service"] == nil, let atco = refs["stop"] {
            let stop = TransitStop(code: atco, name: atco, location: GeoPoint(lat: 0, lon: 0))
            guard let found = try await lines(atStop: stop).first(where: { $0.shortName == line.shortName }) else {
                throw TransitError.notFound("line \(line.shortName) at stop \(atco)")
            }
            refs = found.providerRefs
        }
        guard let service = refs["service"].flatMap(Int.init), let stop = refs["stop"], let next = refs["next"],
              let trip = refs["trip"].flatMap(Int.init) else {
            throw TransitError.unsupported("line \(line.id) has no bustimes.org refs (was it loaded from another provider?)")
        }
        let headsigns = Set((refs["headsigns"] ?? "").split(separator: "|").map(String.init))
        return Ref(service: service, stop: stop, next: next, trip: trip, headsigns: headsigns)
    }
}

/// Trip timetables by id. A trip's stops and times never change, so each is fetched once and
/// kept (up to a few hundred, ~50 KB of JSON each); concurrent asks for one trip share a request.
private actor BustimesTrips {
    static let shared = BustimesTrips()
    private var trips: [Int: Task<DTO.Trip, any Error>] = [:]

    func trip(_ id: Int, _ http: HTTPClient) async throws -> DTO.Trip {
        if let task = trips[id] { return try await task.value }
        if trips.count > 300 { trips.removeAll() }
        let task = Task { try await http.get(DTO.Trip.self, BustimesProvider.base, "/api/trips/\(id)/") }
        trips[id] = task
        do { return try await task.value } catch { trips[id] = nil; throw error }
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct Page<T: Decodable & Sendable>: Decodable, Sendable {
        var next: String?
        var results: [T]
    }

    struct Stop: Decodable, Sendable {
        var atcoCode: String
        var name: String?
        var longName: String?
        var location: [Double]?

        enum CodingKeys: String, CodingKey { case atcoCode = "atco_code", name, longName = "long_name", location }

        var stop: TransitStop? {
            guard let location, location.count == 2 else { return nil }
            return TransitStop(code: atcoCode, name: longName ?? name ?? atcoCode, city: nil,
                               location: GeoPoint(lat: location[1], lon: location[0]))
        }
    }

    struct Service: Decodable, Sendable {
        var id: Int
        var lineName: String?
        var mode: String?

        enum CodingKeys: String, CodingKey { case id, lineName = "line_name", mode }

        init(id: Int, lineName: String?) {
            self.id = id
            self.lineName = lineName
        }
    }

    struct TripSummary: Decodable, Sendable {
        var id: Int
        var headsign: String?
    }

    struct Trip: Decodable, Sendable {
        struct ServiceRef: Decodable, Sendable {
            var lineName: String?
            enum CodingKeys: String, CodingKey { case lineName = "line_name" }
        }
        struct Operator: Decodable, Sendable { var name: String? }

        var id: Int
        var headsign: String?
        var service: ServiceRef?
        var `operator`: Operator?
        var times: [Call]
    }

    struct Call: Decodable, Sendable {
        struct CallStop: Decodable, Sendable {
            var atcoCode: String?
            var name: String?
            var location: [Double]?

            enum CodingKeys: String, CodingKey { case atcoCode = "atco_code", name, location }

            var point: GeoPoint? {
                guard let location, location.count == 2 else { return nil }
                return GeoPoint(lat: location[1], lon: location[0])
            }

            var stop: TransitStop? {
                guard let atcoCode, let point else { return nil }
                return TransitStop(code: atcoCode, name: name ?? atcoCode, city: nil, location: point)
            }
        }

        var stop: CallStop?
        var aimedArrivalTime: String?
        var aimedDepartureTime: String?
        var pickUp: Bool?

        enum CodingKeys: String, CodingKey {
            case stop, aimedArrivalTime = "aimed_arrival_time", aimedDepartureTime = "aimed_departure_time", pickUp = "pick_up"
        }
    }

    struct Vehicle: Decodable, Sendable {
        struct Details: Decodable, Sendable {
            var name: String?
            /// "13175 - OE62 ZRD": the registration follows the fleet number.
            var registration: String? {
                name.map { $0.components(separatedBy: " - ").last ?? $0 }
            }
        }

        var coordinates: [Double]?
        var heading: Double?
        var datetime: String?
        var destination: String?
        var date: String?
        var tripId: Int?
        var vehicle: Details?

        enum CodingKeys: String, CodingKey {
            case coordinates, heading, datetime, destination, date, vehicle, tripId = "trip_id"
        }
    }

    struct StopCollection: Decodable, Sendable {
        struct Feature: Decodable, Sendable {
            struct Geometry: Decodable, Sendable { var coordinates: [Double] }
            struct Properties: Decodable, Sendable {
                var name: String?
                var url: String?
                var services: [String]?
            }
            var geometry: Geometry
            var properties: Properties

            var stop: TransitStop? {
                guard let url = properties.url, url.hasPrefix("/stops/"), geometry.coordinates.count == 2 else { return nil }
                let atco = String(url.dropFirst("/stops/".count))
                return TransitStop(code: atco, name: properties.name ?? atco, city: nil,
                                   location: GeoPoint(lat: geometry.coordinates[1], lon: geometry.coordinates[0]))
            }
        }
        var features: [Feature]
    }

    /// "2026-09-22T13:33:31+01:00"
    static func parseDate(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }

    /// "2026-09-22" → midnight in London.
    static func parseDay(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = BustimesProvider.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}
