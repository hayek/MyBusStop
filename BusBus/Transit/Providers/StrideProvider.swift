import Foundation

/// Israel — Open Bus Stride API by Hasadna (open-bus-stride-api.hasadna.org.il).
/// Documented, keyless, free, volunteer-run (no SLA). Vehicle positions lag ~12–18 min behind
/// real time, so this is a fallback / comparison source, not a live one. See research §3.1.3.
nonisolated struct StrideProvider: TransitProvider {
    let id = "stride"
    let displayName = "Stride by Hasadna (~15 min delayed)"
    let attribution: String? = "Data: Open Bus Stride by Hasadna, from Israel Ministry of Transport open data"
    let capabilities: ProviderCapabilities = [
        .stopSearchByCode, .linesAtStop, .routePattern, .vehiclePositions, .scheduledArrivals, .routeShape,
    ]
    let suggestedRefreshInterval: Duration = .seconds(60)

    var http = HTTPClient(timeout: 60)
    /// How far back to look for vehicle positions — must exceed the ETL lag.
    var vehicleLookback: TimeInterval = 40 * 60
    /// Replay history instead of "now" — handy for testing at night. Positions older than this are returned.
    var replayAt: Date?

    private let base = "https://open-bus-stride-api.hasadna.org.il"
    private let departures = DepartureCache()

    /// Stride has no shapes, but its line refs are bus.gov.il's route ids: one cached shape serves both.
    var shapeDatasetID: String { BusGovILProvider.shapeDatasetID }

    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        try await BusGovILProvider().routeShape(for: line, pattern: pattern)
    }

    func searchStops(query: String) async throws -> [TransitStop] {
        let code = query.trimmingCharacters(in: .whitespaces)
        guard Int(code) != nil else {
            throw TransitError.unsupported("name search — Stride can only look up a stop code")
        }
        let stops = try await firstNonEmpty { day in
            try await http.get([DTO.GtfsStop].self, base, "/gtfs_stops/list", query: [
                "code": code, "date_from": day.dateString, "date_to": day.dateString, "limit": "1",
            ])
        }
        return stops.map(\.stop)
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        // Scans a whole service day of ride-stops at this stop (~0.5 s with the GTFS dates, 6–20 s without).
        let rideStops = try await firstNonEmpty { day in
            try await http.get([DTO.GtfsRideStop].self, base, "/gtfs_ride_stops/list", query: [
                "gtfs_stop__code": stop.code,
                "arrival_time_from": day.startUTC, "arrival_time_to": day.endUTC,
                "limit": "1000",
            ].merging(day.gtfsDates) { $1 })
        }
        var seen = Set<Int>()
        return rideStops.compactMap { rideStop -> TransitLine? in
            guard let lineRef = rideStop.gtfs_route__line_ref, seen.insert(lineRef).inserted else { return nil }
            let longName = rideStop.gtfs_route__route_long_name.map(IsraelRouteLongName.init)
            return TransitLine(
                id: String(lineRef),
                shortName: rideStop.gtfs_route__route_short_name ?? "?",
                headsign: longName?.destination,
                agency: rideStop.gtfs_route__agency_name,
                origin: longName?.origin,
                destination: longName?.destination
            )
        }
        .sorted { $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending }
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        // Today's rides can be loaded before their stops, so retry the whole lookup on the previous day.
        let rideStops = try await firstNonEmpty { day -> [DTO.GtfsRideStop] in
            let rides = try await http.get([DTO.GtfsRide].self, base, "/gtfs_rides/list", query: [
                "gtfs_route__line_refs": line.id,
                "gtfs_route__date_from": day.dateString, "gtfs_route__date_to": day.dateString,
                "limit": "1",
            ])
            guard let ride = rides.first else { return [] }
            return try await http.get([DTO.GtfsRideStop].self, base, "/gtfs_ride_stops/list", query: [
                "gtfs_ride_ids": String(ride.id),
                "arrival_time_from": day.startUTC, "arrival_time_to": day.endUTC(plusDays: 1),
                "order_by": "stop_sequence asc", "limit": "500",
            ].merging(day.gtfsDates) { $1 })
        }
        guard !rideStops.isEmpty else { throw TransitError.notFound("stops for line \(line.id)") }
        return RoutePattern(line: line, stops: rideStops.map {
            PatternStop(stop: $0.stop, sequence: $0.stop_sequence, distanceAlongRoute: $0.shape_dist_traveled ?? ($0.stop_sequence == 1 ? 0 : nil))
        })
    }

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let until = replayAt ?? Date()
        let formatter = ISO8601DateFormatter()
        let locations = try await http.get([DTO.VehicleLocation].self, base, "/siri_vehicle_locations/list", query: [
            "siri_routes__line_ref": line.id,
            "recorded_at_time_from": formatter.string(from: until.addingTimeInterval(-vehicleLookback)),
            "recorded_at_time_to": formatter.string(from: until),
            // Loose as a filter (no ride runs 12 h), but it lets the database narrow by ride first:
            // the same reply in a third of the time, where 15–35 s was common without it.
            "siri_rides__scheduled_start_time_from": formatter.string(from: until.addingTimeInterval(-12 * 3600)),
            "siri_rides__scheduled_start_time_to": formatter.string(from: until.addingTimeInterval(3600)),
            "order_by": "recorded_at_time desc",
            "limit": "500",
        ])
        // Keep only the newest fix per ride.
        var seenRides = Set<Int>()
        let latest = locations.filter { seenRides.insert($0.siri_ride__id ?? $0.id).inserted }

        return await withTaskGroup(of: VehiclePosition.self) { group in
            for location in latest {
                group.addTask {
                    let aimed = location.siri_ride__scheduled_start_time.flatMap(DTO.parseISO)
                    return VehiclePosition(
                        location: GeoPoint(lat: location.lat, lon: location.lon),
                        recordedAt: DTO.parseISO(location.recorded_at_time),
                        distanceAlongRoute: location.distance_from_journey_start.map(Double.init),
                        tripId: location.siri_ride__journey_ref,
                        plateNumber: location.siri_ride__vehicle_ref,
                        bearing: location.bearing.map(Double.init),
                        speedKmh: location.velocity.map(Double.init),
                        aimedDeparture: aimed,
                        actualDeparture: try? await actualDeparture(rideId: location.siri_ride__id, aimed: aimed)
                    )
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
    }

    /// Time of the ride's first GPS sample away from the origin (distance along route > 0).
    /// Samples arrive about once a minute, so this can be up to a minute late. Cached per ride.
    private func actualDeparture(rideId: Int?, aimed: Date?) async throws -> Date? {
        guard let rideId, let aimed else { return nil }
        if let cached = await departures.get(rideId) { return cached }

        let formatter = ISO8601DateFormatter()
        let samples = try await http.get([DTO.VehicleLocation].self, base, "/siri_vehicle_locations/list", query: [
            "siri_rides__ids": String(rideId),
            // A bounded window keeps this query fast; open-ended ones can hang.
            "recorded_at_time_from": formatter.string(from: aimed.addingTimeInterval(-20 * 60)),
            "recorded_at_time_to": formatter.string(from: aimed.addingTimeInterval(60 * 60)),
            "order_by": "recorded_at_time asc",
            "limit": "30",
        ])
        guard let departed = samples.first(where: { ($0.distance_from_journey_start ?? 0) > 0 }),
              let date = DTO.parseISO(departed.recorded_at_time) else { return nil }
        await departures.set(rideId, date)
        return date
    }

    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        // Schedule only: Stride has no live predictions.
        let now = Date()
        let until = now.addingTimeInterval(3 * 3600)
        // From yesterday's service day, whose rides run past midnight, to the one the window ends in.
        let dates = IsraelServiceDay.today.previous.gtfsDates(through: .containing(until))
        let rideStops = try await http.get([DTO.GtfsRideStop].self, base, "/gtfs_ride_stops/list", query: [
            "gtfs_stop__code": stop.code,
            "gtfs_route__line_refs": line.id,
            "arrival_time_from": ISO8601DateFormatter().string(from: now.addingTimeInterval(-5 * 60)),
            "arrival_time_to": ISO8601DateFormatter().string(from: until),
            "order_by": "arrival_time asc", "limit": "20",
        ].merging(dates) { $1 })
        return rideStops.compactMap { rideStop in
            guard let time = rideStop.arrival_time.flatMap(DTO.parseISO) else { return nil }
            return Arrival(expectedAt: time, scheduledAt: time, isRealtime: false, tripId: rideStop.gtfs_ride__journey_ref)
        }
    }
}

private actor DepartureCache {
    private var byRide: [Int: Date] = [:]
    func get(_ rideId: Int) -> Date? { byRide[rideId] }
    func set(_ rideId: Int, _ date: Date) { byRide[rideId] = date }
}

/// Stride loads each day's GTFS some hours after midnight; until then today's queries come back empty.
private nonisolated func firstNonEmpty<T>(_ fetch: (IsraelServiceDay) async throws -> [T]) async throws -> [T] {
    let today = IsraelServiceDay.today
    let results = try await fetch(today)
    return results.isEmpty ? try await fetch(today.previous) : results
}

/// Israeli service day expressed as a UTC window, since Stride filters take UTC timestamps.
private nonisolated struct IsraelServiceDay {
    let start: Date

    static var today: IsraelServiceDay { containing(Date()) }

    static func containing(_ date: Date) -> IsraelServiceDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        return IsraelServiceDay(start: calendar.startOfDay(for: date))
    }

    var previous: IsraelServiceDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        return IsraelServiceDay(start: calendar.date(byAdding: .day, value: -1, to: start)!)
    }

    var dateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Jerusalem")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: start)
    }

    /// The GTFS dates of the stop and route rows, which hasadna asks every ride-stop query to carry
    /// (hasadna/open-bus-stride-api#26): the same rows come back, over ten times faster.
    var gtfsDates: [String: String] { gtfsDates(through: self) }
    func gtfsDates(through last: IsraelServiceDay) -> [String: String] {
        ["gtfs_stop__date_from": dateString, "gtfs_stop__date_to": last.dateString,
         "gtfs_route__date_from": dateString, "gtfs_route__date_to": last.dateString]
    }

    var startUTC: String { ISO8601DateFormatter().string(from: start) }
    var endUTC: String { endUTC(plusDays: 0) }
    func endUTC(plusDays days: Int) -> String {
        ISO8601DateFormatter().string(from: start.addingTimeInterval(Double(days + 1) * 86_400))
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct GtfsStop: Decodable, Sendable {
        var code: Int
        var name: String?
        var city: String?
        var lat: Double
        var lon: Double

        var stop: TransitStop {
            TransitStop(code: String(code), name: name ?? String(code), city: city, location: GeoPoint(lat: lat, lon: lon))
        }
    }

    struct GtfsRide: Decodable, Sendable {
        var id: Int
    }

    struct GtfsRideStop: Decodable, Sendable {
        var stop_sequence: Int
        var arrival_time: String?
        var shape_dist_traveled: Double?
        var gtfs_ride__journey_ref: String?
        var gtfs_stop__code: Int
        var gtfs_stop__name: String?
        var gtfs_stop__city: String?
        var gtfs_stop__lat: Double
        var gtfs_stop__lon: Double
        var gtfs_route__line_ref: Int?
        var gtfs_route__route_short_name: String?
        var gtfs_route__route_long_name: String?
        var gtfs_route__agency_name: String?

        var stop: TransitStop {
            TransitStop(
                code: String(gtfs_stop__code), name: gtfs_stop__name ?? String(gtfs_stop__code),
                city: gtfs_stop__city, location: GeoPoint(lat: gtfs_stop__lat, lon: gtfs_stop__lon)
            )
        }
    }

    struct VehicleLocation: Decodable, Sendable {
        var id: Int
        var recorded_at_time: String
        var lat: Double
        var lon: Double
        var bearing: Int?
        var distance_from_journey_start: Int?
        var siri_ride__id: Int?
        var siri_ride__journey_ref: String?
        var siri_ride__vehicle_ref: String?
        var siri_ride__scheduled_start_time: String?
        var velocity: Int?
    }

    static func parseISO(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }
}
