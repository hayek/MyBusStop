import Foundation
import MapKit

/// US, New York City — MTA Bus Time (bustime.mta.info), official, free key (`MTA_BUSTIME_KEY`).
/// Release goes through our key-holding proxy (`TransitProxy`, route `mta`); Debug calls MTA
/// directly when a local key is present (see `APIKeys`, `KeyedEndpoint.keyed`).
///
/// Two APIs on one host and one key: SIRI (`/api/siri/…`, JSON) for live vehicles and stop
/// predictions, and a OneBusAway "where" subset (`/api/where/…`) for stops and routes. Every call
/// here is filtered by line (and direction) or by stop: MTA revokes keys that fetch every vehicle in
/// the system "at less than 30 second intervals", and the board's poll stays at 30 s regardless.
///
/// Stop codes are the six-digit numbers on the bus-stop signs (OBA id `MTA_<code>`). A line is one
/// route in one GTFS direction (`MTA NYCT_M15|0`). The where API has no text search, so names are
/// geocoded on the device (MapKit) and the stops around the result listed.
///
/// Terms (mta.info/developers/terms-and-conditions): no statement or implication that the app is
/// licensed by the MTA; the data may be credited as obtained from the MTA. The same terms ask for
/// the feed to be re-served from a non-MTA server rather than called from the app directly.
nonisolated struct MTABusTimeProvider: TransitProvider {
    let id = "mta-bustime"
    let displayName = "MTA Bus Time (New York)"
    let attribution: String? = "Bus data obtained from MTA Bus Time. Not endorsed by the MTA."
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .nearbyStops, .routeShape,
    ]
    /// MTA's guidance is no faster than 30 s; buses report every 5–15 s.
    let suggestedRefreshInterval: Duration = .seconds(30)
    var requiredAPIKey: String? { endpoint.unmetKey }

    /// The where API parses numbers in the request's `Accept-Language`: under `he-IL` a negative
    /// longitude is "Invalid field value" (HTTP 400). Every request asks for English, which is the
    /// only language it publishes anyway.
    var http = HTTPClient(headers: ["Accept-Language": "en-US"])
    var endpoint = KeyedEndpoint.keyed("https://bustime.mta.info/api", keyParameter: "key",
                                       keyName: "MTA_BUSTIME_KEY", proxyAgency: "mta")
    /// All five boroughs, for the geocoder.
    private static let city = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.70, longitude: -73.95),
        latitudinalMeters: 60_000, longitudinalMeters: 60_000)

    // MARK: - Stops

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        if query.allSatisfy(\.isNumber), let stop = try await stop(code: query) { return [stop] }

        // The geocoder reads "1st Avenue & East 86th Street" far better than the signs' "1 AV/E 86 ST",
        // so both spellings are asked, and the stops around the best two places of each listed.
        var places: [GeoPoint] = []
        for text in Set([Self.spelledOut(query), query]).sorted(by: >) {
            let address = "\(text.replacingOccurrences(of: "/", with: " & ")), New York, NY"
            places += try await MTAGeocodeCache.shared.places(address) { try await Self.geocode(address) }.prefix(2)
        }
        guard let first = places.first else { return [] }
        var found: [String: (stop: TransitStop, meters: Double)] = [:]
        for place in places {
            for stop in try await stopsAround(place, radiusMeters: 250) {
                let meters = RouteGeometry.meters(first, stop.location)
                if found[stop.code].map({ $0.meters > meters }) ?? true { found[stop.code] = (stop, meters) }
            }
        }
        // Stops whose own name matches every word of the query first, then nearest the first place.
        let words = Self.words(query)
        return found.values
            .sorted { a, b in
                let (am, bm) = (Self.matches(words, a.stop.name), Self.matches(words, b.stop.name))
                return am != bm ? am : a.meters < b.meters
            }
            .prefix(20)
            .map(\.stop)
    }

    /// One call for the stops (each listing its routes), then each route's stop groups — cached
    /// for the session — to learn which directions serve which stop.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let stops = try await stopList(around: point, radiusMeters: Int(radiusMeters))
        let nearest = stops
            .map { (stop: $0, meters: RouteGeometry.meters(point, GeoPoint(lat: $0.lat, lon: $0.lon))) }
            .sorted { $0.meters < $1.meters }
            .prefix(12)
        let routeIDs = Set(nearest.flatMap { $0.stop.routes?.map(\.id) ?? [] })
        let routes = await routes(Array(routeIDs))
        return nearest.compactMap { entry in
            let lines = Self.lines(atStopID: entry.stop.id, of: entry.stop.routes?.compactMap { routes[$0.id] } ?? [])
            guard !lines.isEmpty else { return nil }
            return NearbyStop(stop: entry.stop.transitStop, distanceMeters: entry.meters, lines: lines)
        }
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        guard let found = try await oba(DTO.Stop.self, "/where/stop/\(Self.stopID(stop.code)).json", query: [:]) else {
            throw TransitError.notFound("stop \(stop.code)")
        }
        let ids = found.routes?.map(\.id) ?? []
        let routes = await routes(ids)
        if routes.isEmpty, !ids.isEmpty { throw TransitError.badResponse("no route of stop \(stop.code) loaded") }
        return Self.lines(atStopID: found.id, of: ids.compactMap { routes[$0] })
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
        guard let shape = OneBusAwayProvider.shape(pieces: direction.polylines) else {
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

    // MARK: - Live

    /// SIRI VehicleMonitoring for the line in one direction. Each bus's next stop (`MonitoredCall`)
    /// comes with the metres still to go to it along the road (`DistanceFromCall`); counted back
    /// from that stop's place on the pattern, it gives the bus's distance along the route without
    /// snapping. Buses still finishing a previous trip (`ProgressStatus` prevTrip, layover) are on
    /// another route shape, so they are left to be snapped or discarded. A bus not transmitting
    /// (`spooking`) is placed by its timetable, not by GPS; that is not a bus report, so it is left out.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let ref = Ref(line)
        let delivery = try await siri("/siri/vehicle-monitoring.json",
                                      query: ["LineRef": ref.route, "DirectionRef": ref.direction,
                                              "VehicleMonitoringDetailLevel": "normal"])
        guard let activity = delivery.vehicleMonitoringDelivery?.first else { return [] }
        if let error = activity.errorCondition { throw TransitError.badResponse("SIRI: \(error.description ?? "error")") }
        let journeys = (activity.vehicleActivity ?? []).compactMap { a in a.monitoredVehicleJourney.map { (a, $0) } }
        guard !journeys.isEmpty else { return [] }
        let geometry = (try? await routePattern(for: line)).map(RouteGeometry.init)

        return journeys.compactMap { activity, journey in
            guard journey.directionRef == nil || journey.directionRef == ref.direction, journey.isTracked,
                  let location = journey.vehicleLocation?.point else { return nil }
            return VehiclePosition(
                location: location,
                recordedAt: activity.recordedAtTime.flatMap(DTO.parseDate),
                distanceAlongRoute: geometry.flatMap { Self.distanceAlong(journey, on: $0) },
                tripId: journey.framedVehicleJourneyRef?.datedVehicleJourneyRef,
                plateNumber: journey.vehicleRef.map(Self.fleetNumber),
                bearing: journey.bearing.map(Self.compassBearing),
                aimedDeparture: journey.originAimedDepartureTime.flatMap(DTO.parseDate)
            )
        }
    }

    /// SIRI StopMonitoring for one line and direction at the stop. Visits by a bus still on its
    /// previous trip have no `ExpectedArrivalTime` and are skipped. A visit by a bus that is not
    /// transmitting (`spooking`) is timed from the timetable, as MTA's own site marks it, so it is
    /// not live. `AimedArrivalTime` is left out:
    /// on MTA it often belongs to an earlier slot of the same block, which would read as a bus
    /// running most of an hour late.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let ref = Ref(line)
        let stopID = Self.stopID(stop.code)
        let delivery = try await siri("/siri/stop-monitoring.json",
                                      query: ["MonitoringRef": stopID, "LineRef": ref.route,
                                              "DirectionRef": ref.direction, "MaximumStopVisits": "10"])
        guard let monitoring = delivery.stopMonitoringDelivery?.first else { return [] }
        if let error = monitoring.errorCondition { throw TransitError.badResponse("SIRI: \(error.description ?? "error")") }
        return (monitoring.monitoredStopVisit ?? [])
            .compactMap { visit -> Arrival? in
                guard let journey = visit.monitoredVehicleJourney, let call = journey.monitoredCall,
                      call.stopPointRef == nil || call.stopPointRef == stopID,
                      let expected = (call.expectedArrivalTime ?? call.expectedDepartureTime).flatMap(DTO.parseDate)
                else { return nil }
                return Arrival(
                    expectedAt: expected,
                    scheduledAt: nil,
                    isRealtime: journey.isTracked,
                    tripId: journey.framedVehicleJourneyRef?.datedVehicleJourneyRef,
                    vehicleLocation: journey.isTracked ? journey.vehicleLocation?.point : nil
                )
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    // MARK: - Requests

    /// A where-API call's `data`. Nil for an unknown stop, which answers HTTP 200 with a bare `null`
    /// (an unknown route is an HTTP 404).
    private func oba<T: Decodable & Sendable>(_ type: T.Type, _ path: String, query: [String: String]) async throws -> T? {
        let target = try endpoint.resolve()
        return try await http.get(DTO.Envelope<T>?.self, target.baseURL, path,
                                  query: query.merging(target.authQuery) { a, _ in a })?.data
    }

    private func stopList(around point: GeoPoint, radiusMeters: Int) async throws -> [DTO.Stop] {
        let path = "/where/stops-for-location.json"
        guard let list = try await oba(DTO.StopList.self, path, query: ["lat": String(point.lat), "lon": String(point.lon),
                                                                         "radius": String(radiusMeters)]) else {
            throw TransitError.badResponse("\(path): no data")
        }
        return list.stops
    }

    private func siri(_ path: String, query: [String: String]) async throws -> DTO.ServiceDelivery {
        let target = try endpoint.resolve()
        return try await http.get(DTO.SiriEnvelope.self, target.baseURL, path,
                           query: query.merging(target.authQuery) { a, _ in a }
                               .merging(["OperatorRef": "MTA"]) { a, _ in a }).siri.serviceDelivery
    }

    private func stop(code: String) async throws -> TransitStop? {
        try await oba(DTO.Stop.self, "/where/stop/\(Self.stopID(code)).json", query: [:])?.transitStop
    }

    private func stopsAround(_ point: GeoPoint, radiusMeters: Int) async throws -> [TransitStop] {
        try await stopList(around: point, radiusMeters: radiusMeters).map(\.transitStop)
    }

    /// A route's directions and stops, from the session cache or one `stops-for-route` call
    /// (~30 KB, ~6 KB gzipped, without polylines). With `polylines` the reply also carries each
    /// direction's shape (M15: about 2 KB more gzipped, and slower) and is kept under its own key.
    private func route(_ routeID: String, polylines: Bool = false) async throws -> RouteInfo {
        try await MTARouteCache.shared.route(polylines ? "\(routeID)#shape" : routeID) {
            guard let response = try await oba(DTO.RouteStops.self, "/where/stops-for-route/\(Self.pathSegment(routeID)).json",
                                               query: ["includePolylines": String(polylines), "version": "2"]) else {
                throw TransitError.notFound("route \(routeID)")
            }
            return RouteInfo(routeID, response)
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

    /// Metres along the pattern: the next stop's place minus the road distance still to go, kept
    /// between the previous stop and that one. Nil when the bus is not on this trip yet or the stop
    /// is not on the pattern.
    private static func distanceAlong(_ journey: DTO.Journey, on geometry: RouteGeometry) -> Double? {
        guard journey.progressStatus == nil,
              let call = journey.monitoredCall, let stopRef = call.stopPointRef,
              let remaining = call.extensions?.distances?.distanceFromCall, remaining >= 0,
              let index = geometry.pattern.stops.firstIndex(where: { stopID($0.stop.code) == stopRef }) else { return nil }
        let at = geometry.stopDistances[index]
        let previous = index > 0 ? geometry.stopDistances[index - 1] : 0
        return max(previous, at - remaining)
    }

    /// MTA's SIRI `Bearing` counts degrees counter-clockwise from east; the app wants a compass heading.
    static func compassBearing(_ bearing: Double) -> Double {
        let heading = (90 - bearing).truncatingRemainder(dividingBy: 360)
        return heading < 0 ? heading + 360 : heading
    }

    /// "MTA NYCT_6113" → "6113", the fleet number painted on the bus.
    private static func fleetNumber(_ vehicleRef: String) -> String {
        vehicleRef.split(separator: "_").last.map(String.init) ?? vehicleRef
    }

    private static func stopID(_ code: String) -> String { "MTA_\(code)" }

    /// Route ids contain a space and sometimes "+" ("MTA NYCT_M86+"), both escaped in a path.
    private static func pathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }

    private static func words(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static let streetTypes = [
        "av": "Avenue", "ave": "Avenue", "st": "Street", "blvd": "Boulevard", "bl": "Boulevard",
        "pkwy": "Parkway", "pl": "Place", "rd": "Road", "dr": "Drive", "la": "Lane", "ln": "Lane",
        "tpke": "Turnpike", "hwy": "Highway", "expy": "Expressway", "sq": "Square", "ct": "Court",
    ]
    private static let compass = ["e": "East", "w": "West", "n": "North", "s": "South"]

    /// "1 AV/E 86 ST" → "1st Avenue/East 86th Street": each side of the "/" or "&" on its own, a
    /// leading "ST" read as Saint, and a number before a street type made an ordinal.
    static func spelledOut(_ query: String) -> String {
        query.components(separatedBy: CharacterSet(charactersIn: "/&")).map { part in
            let tokens = part.split(separator: " ").map(String.init)
            return tokens.enumerated().map { index, token in
                let lower = token.lowercased()
                let isLast = index == tokens.count - 1
                if index == 0, !isLast, lower == "st" { return "Saint" }
                if index == 0, !isLast, let direction = compass[lower] { return direction }
                if let type = streetTypes[lower], index > 0 { return type }
                if let number = Int(token), !isLast, streetTypes[tokens[index + 1].lowercased()] != nil {
                    return "\(number)" + ordinalSuffix(number)
                }
                return token
            }.joined(separator: " ")
        }.joined(separator: " & ")
    }

    private static func ordinalSuffix(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "th" }
        return [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
    }

    /// Every query word appears in the stop name, allowing the signs' abbreviations ("AV", "ST").
    private static func matches(_ words: [String], _ name: String) -> Bool {
        let name = Self.words(name)
        let skip: Set<String> = ["and", "at", "of", "the"]
        // Either may be the abbreviation: "86th"/"86", "avenue"/"av", "st"/"street".
        return words.filter { !skip.contains($0) }.allSatisfy { word in
            name.contains { word.hasPrefix($0) || $0.hasPrefix(word) }
        }
    }

    /// Places in New York matching the text, best first; none when nothing matches.
    @MainActor private static func geocode(_ text: String) async throws -> [GeoPoint] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.region = city
        request.regionPriority = .required
        request.resultTypes = [.address, .pointOfInterest]
        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.prefix(3).map {
                GeoPoint(lat: $0.location.coordinate.latitude, lon: $0.location.coordinate.longitude)
            }
        } catch let error as MKError where error.code == .placemarkNotFound {
            return []
        } catch let error as NSError where error.domain == NSURLErrorDomain {
            // Apple's geocoder timing out is the network's weather, not a broken feed: say so.
            throw URLError(URLError.Code(rawValue: error.code))
        }
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
            /// Encoded pieces of the direction's shape (see `OneBusAwayProvider.shape(pieces:)`); empty unless asked for.
            var polylines: [String]
        }

        var id: String
        var shortName: String
        var agency: String?
        var directions: [Direction]

        init(_ routeID: String, _ response: DTO.RouteStops) {
            let refs = response.references
            let route = refs?.routes?.first { $0.id == routeID }
            let agencies = Dictionary((refs?.agencies ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            let stops = Dictionary((refs?.stops ?? []).map { ($0.id, $0.transitStop) }, uniquingKeysWith: { a, _ in a })
            id = routeID
            shortName = route?.shortName ?? routeID.split(separator: "_").last.map(String.init) ?? routeID
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

/// Geocoder answers per address, for the session: Apple throttles MapKit searches, and setup asks
/// the same text again on every keystroke pause and retry.
private actor MTAGeocodeCache {
    static let shared = MTAGeocodeCache()
    private var places: [String: [GeoPoint]] = [:]

    func places(_ address: String, load: @Sendable () async throws -> [GeoPoint]) async throws -> [GeoPoint] {
        if let cached = places[address] { return cached }
        let found = try await load()
        places[address] = found
        return found
    }
}

/// Each route's stop groups, once per session (a few KB each once parsed). A failed load is
/// forgotten so the next call retries.
private actor MTARouteCache {
    static let shared = MTARouteCache()
    private var tasks: [String: Task<MTABusTimeProvider.RouteInfo, any Error>] = [:]

    func route(_ id: String, load: @escaping @Sendable () async throws -> MTABusTimeProvider.RouteInfo) async throws -> MTABusTimeProvider.RouteInfo {
        if let task = tasks[id] { return try await task.value }
        let task = Task { try await load() }
        tasks[id] = task
        do { return try await task.value } catch { tasks[id] = nil; throw error }
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    // OneBusAway "where" API

    struct Envelope<T: Decodable & Sendable>: Decodable, Sendable {
        var code: Int?
        var text: String?
        var data: T?
    }

    struct StopList: Decodable, Sendable {
        var stops: [Stop]
    }

    struct Stop: Decodable, Sendable {
        var id: String
        var code: String?
        var name: String
        var lat: Double
        var lon: Double
        var routes: [Route]?

        var transitStop: TransitStop {
            let code = code ?? id.replacingOccurrences(of: "MTA_", with: "")
            return TransitStop(code: code, name: name, city: nil, location: GeoPoint(lat: lat, lon: lon))
        }
    }

    struct Route: Decodable, Sendable {
        var id: String
        var shortName: String?
        var agencyId: String?
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

        struct References: Decodable, Sendable {
            struct Agency: Decodable, Sendable { var id: String; var name: String? }
            var agencies: [Agency]?
            var routes: [Route]?
            var stops: [Stop]?
        }
    }

    // SIRI (MTA's JSON rendering: PascalCase keys)

    struct SiriEnvelope: Decodable, Sendable {
        var siri: Siri
        enum CodingKeys: String, CodingKey { case siri = "Siri" }

        struct Siri: Decodable, Sendable {
            var serviceDelivery: ServiceDelivery
            enum CodingKeys: String, CodingKey { case serviceDelivery = "ServiceDelivery" }
        }
    }

    struct ServiceDelivery: Decodable, Sendable {
        var vehicleMonitoringDelivery: [VehicleDelivery]?
        var stopMonitoringDelivery: [StopDelivery]?
        enum CodingKeys: String, CodingKey {
            case vehicleMonitoringDelivery = "VehicleMonitoringDelivery"
            case stopMonitoringDelivery = "StopMonitoringDelivery"
        }
    }

    struct ErrorCondition: Decodable, Sendable {
        var description: String?
        enum CodingKeys: String, CodingKey { case description = "Description" }
    }

    struct VehicleDelivery: Decodable, Sendable {
        var vehicleActivity: [Activity]?
        var errorCondition: ErrorCondition?
        enum CodingKeys: String, CodingKey {
            case vehicleActivity = "VehicleActivity", errorCondition = "ErrorCondition"
        }
    }

    struct Activity: Decodable, Sendable {
        var monitoredVehicleJourney: Journey?
        var recordedAtTime: String?
        enum CodingKeys: String, CodingKey {
            case monitoredVehicleJourney = "MonitoredVehicleJourney", recordedAtTime = "RecordedAtTime"
        }
    }

    struct StopDelivery: Decodable, Sendable {
        var monitoredStopVisit: [Activity]?
        var errorCondition: ErrorCondition?
        enum CodingKeys: String, CodingKey {
            case monitoredStopVisit = "MonitoredStopVisit", errorCondition = "ErrorCondition"
        }
    }

    struct Journey: Decodable, Sendable {
        struct Framed: Decodable, Sendable {
            var datedVehicleJourneyRef: String?
            enum CodingKeys: String, CodingKey { case datedVehicleJourneyRef = "DatedVehicleJourneyRef" }
        }

        struct Location: Decodable, Sendable {
            var latitude: Double?
            var longitude: Double?
            enum CodingKeys: String, CodingKey { case latitude = "Latitude", longitude = "Longitude" }

            var point: GeoPoint? { latitude.flatMap { lat in longitude.map { GeoPoint(lat: lat, lon: $0) } } }
        }

        var directionRef: String?
        var framedVehicleJourneyRef: Framed?
        var vehicleLocation: Location?
        var bearing: Double?
        var vehicleRef: String?
        /// Absent while the bus is running this trip; otherwise a comma-joined list of "layover",
        /// "prevTrip" and "spooking" (onebusaway-nyc `SiriSupport.getProgressStatus`).
        var progressStatus: String?
        var monitored: Bool?
        var originAimedDepartureTime: String?
        var monitoredCall: Call?

        enum CodingKeys: String, CodingKey {
            case directionRef = "DirectionRef", framedVehicleJourneyRef = "FramedVehicleJourneyRef"
            case vehicleLocation = "VehicleLocation", bearing = "Bearing", vehicleRef = "VehicleRef"
            case progressStatus = "ProgressStatus", originAimedDepartureTime = "OriginAimedDepartureTime"
            case monitoredCall = "MonitoredCall", monitored = "Monitored"
        }

        /// Reported by the bus itself: MTA's site counts a journey as live only when it is
        /// `Monitored` and not `spooking` (in revenue service but not transmitting, placed by the
        /// timetable).
        var isTracked: Bool {
            monitored != false && !(progressStatus ?? "").split(separator: ",").contains("spooking")
        }
    }

    struct Call: Decodable, Sendable {
        struct Extensions: Decodable, Sendable {
            var distances: Distances?
            enum CodingKeys: String, CodingKey { case distances = "Distances" }
        }

        struct Distances: Decodable, Sendable {
            /// Metres along the road from the bus to this stop.
            var distanceFromCall: Double?
            enum CodingKeys: String, CodingKey { case distanceFromCall = "DistanceFromCall" }
        }

        var stopPointRef: String?
        var expectedArrivalTime: String?
        var expectedDepartureTime: String?
        var extensions: Extensions?

        enum CodingKeys: String, CodingKey {
            case stopPointRef = "StopPointRef", expectedArrivalTime = "ExpectedArrivalTime"
            case expectedDepartureTime = "ExpectedDepartureTime", extensions = "Extensions"
        }
    }

    /// "2026-09-22T11:42:02.552-04:00" — New York offset, with or without milliseconds.
    static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
