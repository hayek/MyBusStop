import Foundation

/// OneBusAway deployments, official, each with a free key by e-mail. One adapter, one `Region` each:
///
/// - **Puget Sound** (api.pugetsound.onebusaway.org, `OBA_PUGETSOUND_KEY`): King County Metro, Sound
///   Transit, Community Transit, Pierce Transit, Intercity, Everett Transit and the Seattle Streetcar.
/// - **Tampa** (api.tampa.onebusawaycloud.com, hosted by the Open Transit Software Foundation,
///   `OBA_TAMPA_KEY`): HART (Hillsborough Area Regional Transit) and the airport's own shuttles.
///
/// Release goes through our key-holding proxy (`TransitProxy`, one route per region); Debug calls
/// OneBusAway directly when a local key is present (see `APIKeys`, `KeyedEndpoint.keyed`).
///
/// Ids carry their agency: stop `1_11133`, route `1_102615` (in both regions the main bus agency is
/// agency 1, whose sign numbers are the stop codes riders see). A line is one route in one GTFS
/// direction (`1_102615|0`). Live vehicles come per route from `trips-for-route`, never the whole
/// fleet (`vehicles-for-agency`, ~0.5 MB).
nonisolated struct OneBusAwayProvider: TransitProvider {
    nonisolated struct Region: Sendable {
        var id: String
        var displayName: String
        var attribution: String?
        var endpoint: KeyedEndpoint
        /// The centre a stop-number search looks around.
        var center: GeoPoint
        /// How far from `center` a stop-number search reaches.
        var searchRadiusMeters: Int
        /// The agency whose stop numbers are the ones printed on the signs.
        var signAgency: String
    }

    var region: Region
    var id: String { region.id }
    var displayName: String { region.displayName }
    var attribution: String? { region.attribution }
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .scheduledArrivals, .nearbyStops, .routeShape,
    ]
    /// Buses report every 30 s or so; the proxy shares one fetch between riders for 10 s.
    let suggestedRefreshInterval: Duration = .seconds(30)
    var requiredAPIKey: String? { endpoint.unmetKey }

    var http = HTTPClient()
    var endpoint: KeyedEndpoint

    init(_ region: Region) {
        self.region = region
        endpoint = region.endpoint
    }

    // MARK: - Stops

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        if query.allSatisfy(\.isNumber) {
            // A sign number can belong to more than one agency; every match within the region is offered.
            let found = try await stopList("/where/stops-for-location.json", query: [
                "lat": String(region.center.lat), "lon": String(region.center.lon),
                "radius": String(region.searchRadiusMeters), "query": query,
            ])
            if !found.stops.isEmpty { return found.stops.map(transitStop) }
        }
        let found = try await searchByName(query)
        // Link stations are named without the word ("Capitol Hill"), which riders tend to add.
        if found.isEmpty, let bare = query.range(of: " station", options: [.caseInsensitive, .anchored, .backwards]) {
            return try await searchByName(String(query[..<bare.lowerBound]))
        }
        return found
    }

    /// The search answers "nothing matches" with HTTP 404 rather than an empty list.
    private func searchByName(_ text: String) async throws -> [TransitStop] {
        do {
            return try await stopList("/where/search/stop.json", query: ["input": text]).stops.prefix(20).map(transitStop)
        } catch let error as ResponseError where error.status == 404 {
            return []
        }
    }

    /// One call for the stops (with every route they serve in its references), then each route's
    /// stop groups — cached for the session — to learn which directions serve which stop.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let found = try await stopList("/where/stops-for-location.json", query: [
            "lat": String(point.lat), "lon": String(point.lon), "radius": String(Int(radiusMeters)),
        ])
        let nearest = found.stops
            .map { (stop: $0, meters: RouteGeometry.meters(point, GeoPoint(lat: $0.lat, lon: $0.lon))) }
            .sorted { $0.meters < $1.meters }
            .prefix(12)
        let routes = await routes(Array(Set(nearest.flatMap(\.stop.routeIds))))
        return nearest.compactMap { entry in
            let lines = Self.lines(atStopID: entry.stop.id, of: entry.stop.routeIds.compactMap { routes[$0] })
            guard !lines.isEmpty else { return nil }
            return NearbyStop(stop: transitStop(entry.stop), distanceMeters: entry.meters, lines: lines)
        }
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let stopID = obaStopID(stop.code)
        guard let found = try await oba(DTO.StopEntry.self, "/where/stop/\(stopID).json", query: [:]) else {
            throw TransitError.notFound("stop \(stop.code)")
        }
        let ids = found.entry.routeIds
        let routes = await routes(ids)
        if routes.isEmpty, !ids.isEmpty { throw TransitError.badResponse("no route of stop \(stop.code) loaded") }
        return Self.lines(atStopID: stopID, of: ids.compactMap { routes[$0] })
    }

    // MARK: - Patterns

    /// The direction's stop group from `stops-for-route`: every stop of the route's variants in that
    /// direction, in travel order. It carries no distances, so progress is measured stop to stop.
    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        Self.pattern(line, try await direction(of: line, in: route(Ref(line).route)))
    }

    /// One `stops-for-route` call of its own with `includePolylines=true`, kept for the session
    /// apart from the plain reply: setup and the nearby screen load every route at a stop, and
    /// only a line the rider opens needs its geometry. The other direction's card reuses it.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        let direction = try await direction(of: line, in: route(Ref(line).route, polylines: true))
        guard let shape = Self.shape(pieces: direction.polylines) else {
            throw TransitError.notFound("shape of \(line.id)")
        }
        return shape
    }

    private func direction(of line: TransitLine, in route: RouteInfo) throws -> RouteInfo.Direction {
        let ref = Ref(line)
        guard let direction = route.directions.first(where: { $0.id == ref.direction }), direction.stops.count >= 2 else {
            throw TransitError.notFound("direction \(ref.direction) of \(ref.route)")
        }
        return direction
    }

    private static func pattern(_ line: TransitLine, _ direction: RouteInfo.Direction) -> RoutePattern {
        RoutePattern(
            line: line,
            stops: direction.stops.enumerated().map { PatternStop(stop: $1, sequence: $0 + 1, distanceAlongRoute: nil) }
        )
    }

    /// A direction's `polylines` (Google, precision 5) are its trips' shapes merged and cut wherever
    /// variants part or meet: each piece already runs the buses' way, but they come in no order.
    /// Pieces that meet end to end are joined; the rest stay branches of their own, since the
    /// direction's stop group is the union of its variants and a stop only one variant serves must
    /// still lie on the drawing. MTA Bus Time sends the same. docs/research/route-shapes/north-america.md
    static func shape(pieces: [String]) -> RouteShape? {
        let decoded = pieces.compactMap { try? Polyline.decode($0, precision: 5) }
        let shape = RouteShape(branches: ShapeCheck.chained(decoded))
        return shape.isEmpty ? nil : shape
    }

    // MARK: - Live

    /// The route's active trips in the line's direction. A trip with no bus reporting still comes
    /// with the place its timetable puts it (`predicted` false, no vehicle): that is not a bus, so it
    /// is left out. So is a bus past the end of its trip, laid over for the next one. Its distance
    /// along the trip is measured on the trip's shape, not on the stop-to-stop pattern, so the
    /// position is snapped instead.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let ref = Ref(line)
        guard let found = try await oba(DTO.TripList.self, "/where/trips-for-route/\(ref.route).json",
                                        query: ["includeStatus": "true", "includeSchedule": "false"]) else { return [] }
        let trips = Dictionary((found.references?.trips ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return found.list.compactMap { details in
            guard let status = details.status, status.predicted == true, !DTO.isCanceled(status.status),
                  let vehicleID = status.vehicleId, !vehicleID.isEmpty,
                  let trip = trips[status.activeTripId ?? details.tripId],
                  trip.routeId == ref.route, trip.directionId == ref.direction,
                  let position = status.lastKnownLocation ?? status.position,
                  !Self.isPastEnd(status) else { return nil }
            let updated = [status.lastLocationUpdateTime, status.lastUpdateTime].compactMap { $0 }.first { $0 > 0 }
            return VehiclePosition(
                location: GeoPoint(lat: position.lat, lon: position.lon),
                recordedAt: updated.map(DTO.date),
                distanceAlongRoute: nil,
                tripId: trip.id,
                plateNumber: Self.fleetNumber(vehicleID),
                bearing: status.orientation.map(Self.compassBearing)
            )
        }
    }

    /// The stop's arrivals for the next 90 minutes, of this route in this direction. A predicted
    /// one is live; the rest are the timetable's, and say so. A cancelled trip still comes with
    /// times (and `predicted` true) under `status` "CANCELED", so it is left out.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let ref = Ref(line)
        let stopID = obaStopID(stop.code)
        guard let found = try await oba(DTO.StopArrivals.self, "/where/arrivals-and-departures-for-stop/\(stopID).json",
                                        query: ["minutesBefore": "0", "minutesAfter": "90"]) else {
            throw TransitError.notFound("stop \(stop.code)")
        }
        let trips = Dictionary((found.references?.trips ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return found.entry.arrivalsAndDepartures
            .compactMap { visit -> Arrival? in
                guard visit.routeId == ref.route, trips[visit.tripId]?.directionId ?? ref.direction == ref.direction,
                      !DTO.isCanceled(visit.status) else { return nil }
                // The first stop of a trip is only departed from.
                let predicted = visit.arrivalEnabled == false ? visit.predictedDepartureTime : visit.predictedArrivalTime
                let scheduled = visit.arrivalEnabled == false ? visit.scheduledDepartureTime : visit.scheduledArrivalTime
                let isRealtime = visit.predicted == true && (predicted ?? 0) > 0
                guard let expected = isRealtime ? predicted : scheduled, expected > 0 else { return nil }
                return Arrival(
                    expectedAt: DTO.date(expected),
                    scheduledAt: scheduled.flatMap { $0 > 0 ? DTO.date($0) : nil },
                    isRealtime: isRealtime,
                    tripId: visit.tripId,
                    vehicleLocation: isRealtime ? visit.tripStatus?.position.map { GeoPoint(lat: $0.lat, lon: $0.lon) } : nil
                )
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    // MARK: - Requests

    /// A where-API call's `data`. Nil when the API answers with none.
    private func oba<T: Decodable & Sendable>(_ type: T.Type, _ path: String, query: [String: String]) async throws -> T? {
        let target = try endpoint.resolve()
        let envelope = try await http.get(DTO.Envelope<T>.self, target.baseURL, path,
                                          query: query.merging(target.authQuery) { a, _ in a })
        if let code = envelope.code, code != 200 {
            throw TransitError.badResponse("\(path): \(code) \(envelope.text ?? "")")
        }
        return envelope.data
    }

    private func stopList(_ path: String, query: [String: String]) async throws -> DTO.StopList {
        guard let list = try await oba(DTO.StopList.self, path, query: query) else {
            throw TransitError.badResponse("\(path): no data")
        }
        return list
    }

    /// A route's directions and stops, from the session cache or one `stops-for-route` call. With
    /// `polylines` the reply also carries each direction's shape (the E Line: 6 KB gzipped instead
    /// of 4 KB) and is kept under its own key.
    private func route(_ routeID: String, polylines: Bool = false) async throws -> RouteInfo {
        try await OneBusAwayRouteCache.shared.route("\(id)/\(routeID)\(polylines ? "#shape" : "")") {
            guard let response = try await oba(DTO.RouteStops.self, "/where/stops-for-route/\(routeID).json",
                                               query: ["includePolylines": String(polylines), "version": "2"]) else {
                throw TransitError.notFound("route \(routeID)")
            }
            return RouteInfo(routeID, response, stop: transitStop)
        }
    }

    /// Whatever routes load; one failing route must not hide a stop's other lines.
    private func routes(_ ids: [String]) async -> [String: RouteInfo] {
        await withTaskGroup(of: RouteInfo?.self) { group in
            for id in ids { group.addTask { try? await route(id) } }
            var result: [String: RouteInfo] = [:]
            for await info in group { if let info { result[info.id] = info } }
            return result
        }
    }

    // MARK: - Helpers

    /// Every direction of the given routes that serves the stop. A direction that only *ends* there
    /// is dropped unless nothing else serves it (a terminus).
    private static func lines(atStopID stopID: String, of routes: [RouteInfo]) -> [TransitLine] {
        let serving = routes.flatMap { route in
            route.directions.filter { $0.stopIDs.contains(stopID) }.map { (route, $0) }
        }
        let boarding = serving.filter { $0.1.stopIDs.last != stopID || $0.1.stopIDs.dropLast().contains(stopID) }
        return (boarding.isEmpty ? serving : boarding)
            .sorted { ($0.0.shortName, $0.1.id) < ($1.0.shortName, $1.1.id) }
            .map { route, direction in
                TransitLine(
                    id: "\(route.id)|\(direction.id)",
                    shortName: route.shortName,
                    headsign: direction.name,
                    agency: route.agency,
                    origin: direction.stops.first?.name,
                    destination: direction.stops.last?.name,
                    providerRefs: ["route": route.id, "direction": direction.id]
                )
            }
    }

    /// A bus whose distance along its trip has reached the trip's length is at the far terminal.
    private static func isPastEnd(_ status: DTO.TripStatus) -> Bool {
        guard let along = status.distanceAlongTrip, let total = status.totalDistanceAlongTrip, total > 0 else { return false }
        return along >= total
    }

    /// OneBusAway's `orientation` counts degrees counter-clockwise from east; the app wants a compass heading.
    static func compassBearing(_ orientation: Double) -> Double {
        let heading = (90 - orientation).truncatingRemainder(dividingBy: 360)
        return heading < 0 ? heading + 360 : heading
    }

    /// "1_4325" → "4325", the fleet number painted on the bus.
    private static func fleetNumber(_ vehicleID: String) -> String {
        vehicleID.split(separator: "_", maxSplits: 1).last.map(String.init) ?? vehicleID
    }

    /// The code a rider sees: the sign agency's stop number ("11133"), or the full id for the other
    /// agencies ("40_C08"), whose numbers could otherwise collide with the sign agency's.
    static func stopCode(_ id: String, signAgency: String) -> String {
        let parts = id.split(separator: "_", maxSplits: 1).map(String.init)
        return parts.count == 2 && parts[0] == signAgency ? parts[1] : id
    }

    /// The inverse of `stopCode`.
    static func stopID(_ code: String, signAgency: String) -> String {
        code.contains("_") ? code : "\(signAgency)_\(code)"
    }

    private func obaStopID(_ code: String) -> String { Self.stopID(code, signAgency: region.signAgency) }

    private func transitStop(_ stop: DTO.Stop) -> TransitStop {
        TransitStop(code: Self.stopCode(stop.id, signAgency: region.signAgency), name: stop.name, city: nil,
                    location: GeoPoint(lat: stop.lat, lon: stop.lon))
    }

    // MARK: - Types

    private nonisolated struct Ref {
        var route: String
        var direction: String

        init(_ line: TransitLine) {
            let parts = line.id.split(separator: "|").map(String.init)
            route = line.providerRefs["route"] ?? parts.first ?? line.id
            direction = line.providerRefs["direction"] ?? (parts.count > 1 ? parts[1] : "0")
        }
    }

    fileprivate nonisolated struct RouteInfo: Sendable {
        struct Direction: Sendable {
            var id: String
            var name: String?
            var stopIDs: [String]
            var stops: [TransitStop]
            /// Encoded pieces of the direction's shape (see `shape(pieces:)`); empty unless asked for.
            var polylines: [String]
        }

        var id: String
        var shortName: String
        var agency: String?
        var directions: [Direction]

        init(_ routeID: String, _ response: DTO.RouteStops, stop transitStop: (DTO.Stop) -> TransitStop) {
            let refs = response.references
            let route = refs?.routes?.first { $0.id == routeID }
            let agencies = Dictionary((refs?.agencies ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            let stops = Dictionary((refs?.stops ?? []).map { ($0.id, transitStop($0)) }, uniquingKeysWith: { a, _ in a })
            id = routeID
            shortName = route?.displayName ?? routeID.split(separator: "_").last.map(String.init) ?? routeID
            agency = route?.agencyId.flatMap { agencies[$0] ?? nil }
            let grouping = response.entry.stopGroupings?.first { $0.type == "direction" } ?? response.entry.stopGroupings?.first
            directions = (grouping?.stopGroups ?? []).map { group in
                Direction(id: group.id, name: group.name?.name, stopIDs: group.stopIds ?? [],
                          stops: (group.stopIds ?? []).compactMap { stops[$0] },
                          polylines: (group.polylines ?? []).map(\.points))
            }
        }
    }
}

nonisolated extension OneBusAwayProvider.Region {
    /// Sound Transit's terms (soundtransit.org, Transit Data Terms of Use): free use, paid apps
    /// included; no agency name or mark in the app's name; the data identified as provided "AS IS"
    /// by the agencies; the terms passed on to riders (the credit line links them); the data not
    /// changed and the most current used (the proxy holds live answers for 10 s); usage metrics to
    /// Sound Transit on request.
    static let pugetSound = Self(
        id: "oba-pugetsound",
        displayName: "OneBusAway Puget Sound (Seattle)",
        attribution: "Transit data provided \"AS IS\" by King County Metro, Sound Transit and the Puget Sound "
            + "transit agencies, under the Transit Data Terms of Use: "
            + "https://www.soundtransit.org/help-contacts/business-information/open-transit-data-otd/transit-data-terms-use",
        endpoint: .keyed("https://api.pugetsound.onebusaway.org/api", keyParameter: "key",
                         keyName: "OBA_PUGETSOUND_KEY", proxyAgency: "pugetsound"),
        center: GeoPoint(lat: 47.6062, lon: -122.3321),
        searchRadiusMeters: 60_000,
        signAgency: "1"
    )

    /// Key granted by the Open Transit Software Foundation (2026-09-28), which runs the server for
    /// HART. No terms beyond the key were set; HART is credited as the source.
    static let tampa = Self(
        id: "oba-tampa",
        displayName: "OneBusAway Tampa (HART)",
        attribution: "Transit data: HART (Hillsborough Area Regional Transit), via OneBusAway",
        endpoint: .keyed("https://api.tampa.onebusawaycloud.com/api", keyParameter: "key",
                         keyName: "OBA_TAMPA_KEY", proxyAgency: "tampa"),
        center: GeoPoint(lat: 27.9506, lon: -82.4572),
        searchRadiusMeters: 50_000,
        signAgency: "1"
    )
}

/// Each route's stop groups, once per session, keyed "<provider>/<route>" since route ids repeat
/// across regions (`1_8` is a route in Seattle and in Tampa). A failed load is forgotten so the
/// next call retries.
private actor OneBusAwayRouteCache {
    static let shared = OneBusAwayRouteCache()
    private var tasks: [String: Task<OneBusAwayProvider.RouteInfo, any Error>] = [:]

    func route(_ id: String, load: @escaping @Sendable () async throws -> OneBusAwayProvider.RouteInfo) async throws -> OneBusAwayProvider.RouteInfo {
        if let task = tasks[id] { return try await task.value }
        let task = Task { try await load() }
        tasks[id] = task
        do { return try await task.value } catch { tasks[id] = nil; throw error }
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    /// OneBusAway times are milliseconds since the epoch.
    static func date(_ milliseconds: Double) -> Date { Date(timeIntervalSince1970: milliseconds / 1000) }

    /// `status` of an arrival or trip: "default", or "CANCELED" (and the legacy "cancelled") for a
    /// trip the agency called off (onebusaway-application-modules `TransitDataConstants`).
    static func isCanceled(_ status: String?) -> Bool {
        ["canceled", "cancelled"].contains(status?.lowercased() ?? "")
    }

    struct Envelope<T: Decodable & Sendable>: Decodable, Sendable {
        var code: Int?
        var text: String?
        var data: T?
    }

    struct Point: Decodable, Sendable {
        var lat: Double
        var lon: Double
    }

    struct Stop: Decodable, Sendable {
        var id: String
        var name: String
        var lat: Double
        var lon: Double
        var routeIds: [String] = []

        enum CodingKeys: String, CodingKey { case id, name, lat, lon, routeIds }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            lat = try c.decode(Double.self, forKey: .lat)
            lon = try c.decode(Double.self, forKey: .lon)
            routeIds = try c.decodeIfPresent([String].self, forKey: .routeIds) ?? []
        }
    }

    struct Route: Decodable, Sendable {
        var id: String
        var shortName: String?
        var nullSafeShortName: String?
        var agencyId: String?

        /// Sound Transit's Link lines have no short name of their own ("1 Line" is `nullSafeShortName`).
        var displayName: String? { [shortName, nullSafeShortName].compactMap { $0 }.first { !$0.isEmpty } }
    }

    struct Agency: Decodable, Sendable {
        var id: String
        var name: String?
    }

    struct Trip: Decodable, Sendable {
        var id: String
        var routeId: String?
        var directionId: String?
    }

    struct References: Decodable, Sendable {
        var agencies: [Agency]?
        var routes: [Route]?
        var stops: [Stop]?
        var trips: [Trip]?
    }

    struct StopList: Decodable, Sendable {
        var list: [Stop]
        var references: References?

        var stops: [Stop] { list }
    }

    struct StopEntry: Decodable, Sendable {
        var entry: Stop
    }

    struct RouteStops: Decodable, Sendable {
        var entry: Entry
        var references: References?

        struct Entry: Decodable, Sendable {
            var stopGroupings: [Grouping]?
        }

        struct Grouping: Decodable, Sendable {
            var type: String?
            var stopGroups: [Group]?
        }

        struct Group: Decodable, Sendable {
            struct Name: Decodable, Sendable { var name: String? }
            var id: String
            var name: Name?
            var stopIds: [String]?
            /// The direction's own shape pieces; the entry's top-level `polylines` mix both directions.
            var polylines: [EncodedPolyline]?
        }

        struct EncodedPolyline: Decodable, Sendable {
            var points: String
        }
    }

    struct TripStatus: Decodable, Sendable {
        var activeTripId: String?
        var status: String?
        var predicted: Bool?
        var vehicleId: String?
        var position: Point?
        var lastKnownLocation: Point?
        var orientation: Double?
        var lastUpdateTime: Double?
        var lastLocationUpdateTime: Double?
        var distanceAlongTrip: Double?
        var totalDistanceAlongTrip: Double?
    }

    struct TripList: Decodable, Sendable {
        struct Details: Decodable, Sendable {
            var tripId: String
            var status: TripStatus?
        }

        var list: [Details]
        var references: References?
    }

    struct StopArrivals: Decodable, Sendable {
        struct Entry: Decodable, Sendable {
            var arrivalsAndDepartures: [Visit]
        }

        struct Visit: Decodable, Sendable {
            var routeId: String
            var tripId: String
            var predicted: Bool?
            var status: String?
            var arrivalEnabled: Bool?
            var predictedArrivalTime: Double?
            var predictedDepartureTime: Double?
            var scheduledArrivalTime: Double?
            var scheduledDepartureTime: Double?
            var tripStatus: TripStatus?
        }

        var entry: Entry
        var references: References?
    }
}
