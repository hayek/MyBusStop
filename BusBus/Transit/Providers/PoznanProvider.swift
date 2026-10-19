import Foundation

/// Poznań, Poland — ZTM Poznań. Three keyless sources stitched together:
/// - PEKA Virtual Monitor (`peka.poznan.pl/vm/method.vm`): a POST form API (`method=…&p0=<json>`)
///   for the stops of a stop point, the ordered bollards of a line, and live departures.
/// - The city map's stop layer (`poznan.pl/mim/plan/map_service.html`): every bollard with its
///   coordinates, which PEKA never returns. ~670 KB JSON (~82 KB gzipped), fetched once per session.
/// - ZTM's GTFS-RT `vehicle_positions.pb` (~29 KB, every vehicle in the network) for bus positions.
/// No published rate limit or terms beyond ZTM's open-data page. See docs/research/worldwide-apis.md §6.8.
///
/// A "stop" here is a single bollard (słupek), coded by its PEKA `tag` ("RKAP73"): that is the
/// symbol `getTimes` takes and the id the map layer uses. PEKA's own `symbol` field is an internal
/// id that `getTimes` does not accept.
nonisolated struct PoznanProvider: TransitProvider {
    let id = "ztm-poznan"
    let displayName = "ZTM Poznań (PEKA)"
    let attribution: String? = "Dane: ZTM Poznań (PEKA, GTFS-RT), poznan.pl"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .nearbyStops,
    ]
    /// The GTFS-RT feed is regenerated roughly every 10–30 s.
    let suggestedRefreshInterval: Duration = .seconds(20)

    static let timeZone = TimeZone(identifier: "Europe/Warsaw")!

    private var cache: PoznanCache { .shared }

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let stops = try await cache.stops()
        if let exact = stops.byTag[query.uppercased()] { return [exact.stop] }
        let needle = PoznanText.fold(query)
        return stops.all
            .filter { $0.folded.contains(needle) }
            .sorted { a, b in
                let aPrefix = a.folded.hasPrefix(needle), bPrefix = b.folded.hasPrefix(needle)
                if aPrefix != bPrefix { return aPrefix }
                return (a.stop.name, a.stop.code) < (b.stop.name, b.stop.code)
            }
            .prefix(60)
            .map(\.stop)
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let name = try await cache.stops().byTag[stop.code]?.stop.name ?? stop.name
        return try await cache.linesByStopName(name)[stop.code] ?? []
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        guard let lineName = line.providerRefs["line"], let patternName = line.providerRefs["pattern"] else {
            throw TransitError.unsupported("line \(line.id) has no PEKA refs (was it loaded from another provider?)")
        }
        let directions = try await cache.directions(ofLine: lineName)
        guard let direction = directions.first(where: { $0.name == patternName }) else {
            throw TransitError.notFound("direction \(patternName) of line \(lineName)")
        }
        let stops = try await cache.stops()
        // Bollards the map layer does not know (depots, temporary stops) have no coordinates; they are
        // left out, but the survivors keep PEKA's `orderNo` so the sequence stays increasing.
        let pattern = direction.bollards.compactMap { bollard -> PatternStop? in
            guard let known = stops.byTag[bollard.tag] else { return nil }
            return PatternStop(stop: known.stop, sequence: bollard.orderNo, distanceAlongRoute: nil)
        }
        guard pattern.count >= 2 else { throw TransitError.notFound("stops for line \(line.id)") }
        return RoutePattern(line: line, stops: pattern)
    }

    /// The GTFS-RT feed carries no direction: `route_id` is the line number and `trip_id` is opaque.
    /// A vehicle is assigned to whichever of the line's PEKA directions has the stop it is heading for
    /// (`current_stop_sequence`, which follows the same numbering as PEKA's `orderNo`) closest to it.
    /// Vehicles no direction explains within 1.5 km (typically short-turn variants) are left out.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        guard let lineName = line.providerRefs["line"], let patternName = line.providerRefs["pattern"] else {
            throw TransitError.unsupported("line \(line.id) has no PEKA refs (was it loaded from another provider?)")
        }
        async let feed = cache.vehicleFeed()
        let directions = try await cache.directions(ofLine: lineName)
        let stops = try await cache.stops()
        let located = directions.map { direction in
            (name: direction.name, stops: direction.bollards.compactMap { bollard in
                stops.byTag[bollard.tag].map { (orderNo: bollard.orderNo, location: $0.stop.location) }
            })
        }

        return try await feed
            .filter { $0.routeID == lineName }
            .filter { vehicle in
                let heading = max(vehicle.stopSequence, 1)
                let scored = located.compactMap { direction -> (String, Double)? in
                    let candidates = direction.stops.filter { $0.orderNo == heading || $0.orderNo == heading - 1 }
                    let best = candidates.map { RouteGeometry.meters($0.location, vehicle.location) }.min()
                    return best.map { (direction.name, $0) }
                }
                guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 < 1_500 else { return false }
                return best.0 == patternName
            }
            .map { vehicle in
                VehiclePosition(
                    location: vehicle.location,
                    recordedAt: vehicle.timestamp,
                    tripId: vehicle.tripID,
                    bearing: vehicle.bearing,
                    speedKmh: vehicle.speed.map { $0 * 3.6 }
                )
            }
    }

    /// `getTimes` lists the next ~10–20 departures of every line at the bollard. Its `departure` is
    /// Poznań wall-clock time mislabelled with a `Z`, so the offset is ignored and the time read in
    /// Europe/Warsaw. It gives no separate timetable time, so `scheduledAt` stays nil.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        guard let lineName = line.providerRefs["line"] else {
            throw TransitError.unsupported("line \(line.id) has no PEKA refs (was it loaded from another provider?)")
        }
        let headsign = line.headsign
        let response = try await PEKA.call(DTO.TimesBody.self, "getTimes", ["symbol": stop.code])
        return (response?.times ?? [])
            .filter { $0.line == lineName && (headsign == nil || $0.direction == headsign) }
            .compactMap { time -> Arrival? in
                guard let expected = DTO.parseLocal(time.departure) else { return nil }
                return Arrival(expectedAt: expected, scheduledAt: nil, isRealtime: time.realTime ?? false)
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// There is no proximity query, so this filters the cached map layer. Lines come from one
    /// `getBollardsByStopPoint` per distinct stop name, so only the nearest dozen bollards are listed.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let nearest = try await cache.stops().all
            .map { (stop: $0.stop, distance: RouteGeometry.meters(point, $0.stop.location)) }
            .filter { $0.distance <= radiusMeters }
            .sorted { $0.distance < $1.distance }
            .prefix(12)
        let names = Set(nearest.map(\.stop.name))
        let linesByTag = try await withThrowingTaskGroup(of: [String: [TransitLine]].self) { group in
            for name in names { group.addTask { try await cache.linesByStopName(name) } }
            return try await group.reduce(into: [String: [TransitLine]]()) { $0.merge($1) { a, _ in a } }
        }
        return nearest.map { NearbyStop(stop: $0.stop, distanceMeters: $0.distance, lines: linesByTag[$0.stop.code] ?? []) }
    }
}

// MARK: - Session cache

/// Everything here is either static for the day (stops, line patterns) or shared by every line
/// (the vehicle feed), so it is fetched once and reused across providers, lines and polls.
private actor PoznanCache {
    static let shared = PoznanCache()

    private var stopsTask: Task<PoznanStops, any Error>?
    private var directionTasks: [String: (fetched: Date, task: Task<[PoznanDirection], any Error>)] = [:]
    private var feed: (fetched: Date, task: Task<[PoznanVehicle], any Error>)?

    func stops() async throws -> PoznanStops {
        if let stopsTask { return try await stopsTask.value }
        let task = Task { try await PoznanStops.load() }
        stopsTask = task
        do { return try await task.value } catch { stopsTask = nil; throw error }
    }

    /// Both main directions of a line with their bollards in travel order. Kept for an hour.
    func directions(ofLine line: String) async throws -> [PoznanDirection] {
        if let entry = directionTasks[line], Date().timeIntervalSince(entry.fetched) < 3_600 {
            return try await entry.task.value
        }
        let task = Task {
            let response = try await PEKA.call(DTO.LineBollards.self, "getBollardsByLine", ["name": line])
            return (response?.directions ?? []).map { entry in
                PoznanDirection(name: entry.direction.direction, bollards: entry.bollards.sorted { $0.orderNo < $1.orderNo })
            }
        }
        directionTasks[line] = (Date(), task)
        do { return try await task.value } catch { directionTasks[line] = nil; throw error }
    }

    /// One vehicle feed download serves every line polled within 10 s.
    func vehicleFeed() async throws -> [PoznanVehicle] {
        if let feed, Date().timeIntervalSince(feed.fetched) < 10 { return try await feed.task.value }
        let task = Task { try await PoznanVehicle.loadFeed() }
        feed = (Date(), task)
        do { return try await task.value } catch { feed = nil; throw error }
    }

    /// Lines at every bollard of a stop point, keyed by bollard tag.
    ///
    /// PEKA lists each bollard's (line, headsign) pairs, including short-turn and depot variants
    /// ("Głogowska/Hetmańska"), but `getBollardsByLine` only knows each line's two main directions.
    /// Each pair is therefore tied to the main direction that passes the bollard: the one of the same
    /// name if it does, otherwise the only one that does. Pairs no main direction explains, and
    /// runs that end at this bollard, are dropped — they cannot be drawn or tracked.
    func linesByStopName(_ name: String) async throws -> [String: [TransitLine]] {
        let response = try await PEKA.call(DTO.StopPointBollards.self, "getBollardsByStopPoint", ["name": name])
        let bollards = response?.bollards ?? []
        let lineNames = Set(bollards.flatMap { $0.directions.map(\.lineName) })
        let directions = try await withThrowingTaskGroup(of: (String, [PoznanDirection]).self) { group in
            for line in lineNames { group.addTask { (line, try await self.directions(ofLine: line)) } }
            return try await group.reduce(into: [String: [PoznanDirection]]()) { $0[$1.0] = $1.1 }
        }
        let stops = try await stops()

        var result: [String: [TransitLine]] = [:]
        for entry in bollards {
            let tag = entry.bollard.tag
            var seen = Set<String>()
            result[tag] = entry.directions.compactMap { served -> TransitLine? in
                let passing = (directions[served.lineName] ?? []).filter { direction in
                    guard let index = direction.bollards.firstIndex(where: { $0.tag == tag }) else { return false }
                    return index < direction.bollards.count - 1
                }
                guard served.direction != name,
                      let pattern = passing.first(where: { $0.name == served.direction }) ?? (passing.count == 1 ? passing[0] : nil)
                else { return nil }
                let id = "\(served.lineName)|\(served.direction)|\(pattern.name)"
                guard seen.insert(id).inserted else { return nil }
                let origin = pattern.bollards.first.map { stops.byTag[$0.tag]?.stop.name ?? PoznanText.stripBollard($0.name) }
                return TransitLine(
                    id: id,
                    shortName: served.lineName,
                    headsign: served.direction,
                    agency: "ZTM Poznań",
                    origin: origin,
                    destination: served.direction,
                    providerRefs: ["line": served.lineName, "pattern": pattern.name, "bollard": tag]
                )
            }
            .sorted { ($0.shortName.count, $0.shortName, $0.headsign ?? "") < ($1.shortName.count, $1.shortName, $1.headsign ?? "") }
        }
        return result
    }
}

private nonisolated struct PoznanDirection: Sendable {
    var name: String
    var bollards: [DTO.LineBollard]
}

private nonisolated struct PoznanStops: Sendable {
    struct Entry: Sendable {
        var stop: TransitStop
        var folded: String
    }

    var all: [Entry]
    var byTag: [String: Entry]

    /// The map layer lists a bollard served by both trams and buses twice (once per `route_type`)
    /// under the same id; the first copy is kept.
    static func load() async throws -> PoznanStops {
        let layer = try await HTTPClient(timeout: 60).get(
            DTO.StopLayer.self, "https://www.poznan.pl", "/mim/plan/map_service.html",
            query: ["mtype": "pub_transport", "co": "cluster"]
        )
        var byTag: [String: Entry] = [:]
        var all: [Entry] = []
        for feature in layer.features where byTag[feature.id] == nil {
            guard feature.geometry.coordinates.count >= 2 else { continue }
            let name = feature.properties.stop_name
            let stop = TransitStop(
                code: feature.id, name: name, city: nil,
                location: GeoPoint(lat: feature.geometry.coordinates[1], lon: feature.geometry.coordinates[0])
            )
            let entry = Entry(stop: stop, folded: PoznanText.fold(name))
            byTag[feature.id] = entry
            all.append(entry)
        }
        return PoznanStops(all: all, byTag: byTag)
    }
}

private nonisolated enum PoznanText {
    /// Case- and diacritic-insensitive form for matching ("Śródka" ≈ "srodka"; ł has no decomposition).
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .replacingOccurrences(of: "ł", with: "l")
    }

    /// PEKA line bollards are named "Rondo Kaponiera - 73".
    static func stripBollard(_ name: String) -> String {
        name.replacingOccurrences(of: #" - \d+$"#, with: "", options: .regularExpression)
    }
}

// MARK: - PEKA transport

/// PEKA VM is one endpoint: `POST method.vm?ts=<epoch ms>` with a form body `method=<name>&p0=<json>`.
/// Replies are `{"success": …}` or `{"failure": "brak"}` ("none"), which decodes as an empty success.
private nonisolated enum PEKA {
    static func call<T: Decodable & Sendable>(_ type: T.Type, _ method: String, _ argument: [String: String]) async throws -> T? {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        guard let url = URL(string: "https://www.peka.poznan.pl/vm/method.vm?ts=\(ms)") else {
            throw TransitError.badResponse("invalid PEKA URL")
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: argument, options: [.sortedKeys]), as: UTF8.self)
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BusBus-iOS/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("method=\(formEncode(method))&p0=\(formEncode(json))".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTPClient.check(data, response, request, "PEKA \(method)")
        return try HTTPClient.decode(DTO.Reply<T>.self, data, response, request, "PEKA \(method)").success
    }

    private static func formEncode(_ string: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }
}

// MARK: - GTFS-RT vehicle positions

private nonisolated struct PoznanVehicle: Sendable {
    var routeID: String
    var tripID: String?
    var location: GeoPoint
    var bearing: Double?
    /// Metres per second, as GTFS-RT publishes it.
    var speed: Double?
    var stopSequence: Int
    var timestamp: Date?

    static func loadFeed() async throws -> [PoznanVehicle] {
        guard let url = URL(string: "https://www.ztm.poznan.pl/pl/dla-deweloperow/getGtfsRtFile?file=vehicle_positions.pb") else {
            throw TransitError.badResponse("invalid GTFS-RT URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("BusBus-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTPClient.check(data, response, request, "vehicle_positions.pb")
        do {
            return try parse(Array(data))
        } catch {
            throw ResponseError("vehicle_positions.pb: \(ResponseError.describe(error))", data, response, request)
        }
    }

    /// Reads just the fields used, per gtfs-realtime.proto: FeedMessage.entity (2) → FeedEntity.vehicle (4)
    /// → VehiclePosition { trip (1) { trip_id 1, route_id 5 }, position (2) { latitude 1, longitude 2,
    /// bearing 3, speed 5 — all float }, current_stop_sequence (3), timestamp (5) }.
    static func parse(_ bytes: [UInt8]) throws -> [PoznanVehicle] {
        var vehicles: [PoznanVehicle] = []
        try Protobuf.fields(bytes[...]) { field, value in
            guard field == 2, case .bytes(let entity) = value else { return }
            try Protobuf.fields(entity) { field, value in
                guard field == 4, case .bytes(let body) = value else { return }
                var routeID: String?, tripID: String?, lat: Float?, lon: Float?, bearing: Float?, speed: Float?
                var sequence = 0
                var timestamp: UInt64?
                try Protobuf.fields(body) { field, value in
                    switch (field, value) {
                    case (1, .bytes(let trip)):
                        try Protobuf.fields(trip) { field, value in
                            guard case .bytes(let text) = value else { return }
                            if field == 1 { tripID = String(decoding: text, as: UTF8.self) }
                            if field == 5 { routeID = String(decoding: text, as: UTF8.self) }
                        }
                    case (2, .bytes(let position)):
                        try Protobuf.fields(position) { field, value in
                            guard case .fixed32(let bits) = value else { return }
                            let number = Float(bitPattern: bits)
                            switch field {
                            case 1: lat = number
                            case 2: lon = number
                            case 3: bearing = number
                            case 5: speed = number
                            default: break
                            }
                        }
                    case (3, .varint(let value)): sequence = Int(clamping: value)
                    case (5, .varint(let value)): timestamp = value
                    default: break
                    }
                }
                guard let routeID, let lat, let lon, lat != 0 || lon != 0 else { return }
                vehicles.append(PoznanVehicle(
                    routeID: routeID, tripID: tripID,
                    location: GeoPoint(lat: Double(lat), lon: Double(lon)),
                    bearing: bearing.map(Double.init), speed: speed.map(Double.init),
                    stopSequence: sequence,
                    timestamp: timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                ))
            }
        }
        return vehicles
    }
}

/// The smallest protobuf wire-format reader that walks a message's fields; no schema, no dependencies.
private nonisolated enum Protobuf {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(ArraySlice<UInt8>)
        case fixed32(UInt32)
    }

    static func fields(_ bytes: ArraySlice<UInt8>, _ visit: (Int, Value) throws -> Void) throws {
        var index = bytes.startIndex
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard index < bytes.endIndex, shift < 64 else { throw TransitError.badResponse("truncated protobuf varint") }
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
        }
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, bytes.endIndex - index >= count else { throw TransitError.badResponse("truncated protobuf field") }
            defer { index += count }
            return bytes[index..<index + count]
        }
        func little(_ slice: ArraySlice<UInt8>) -> UInt64 {
            slice.reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }
        while index < bytes.endIndex {
            let key = try varint()
            let field = Int(key >> 3)
            switch key & 7 {
            case 0: try visit(field, .varint(try varint()))
            case 1: try visit(field, .fixed64(little(try take(8))))
            case 2: try visit(field, .bytes(try take(Int(try varint()))))
            case 5: try visit(field, .fixed32(UInt32(little(try take(4)))))
            default: throw TransitError.badResponse("unsupported protobuf wire type \(key & 7)")
            }
        }
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct Reply<T: Decodable & Sendable>: Decodable, Sendable {
        var success: T?
    }

    struct StopPointBollards: Decodable, Sendable {
        var bollards: [StopPointBollard]
    }

    struct StopPointBollard: Decodable, Sendable {
        var bollard: Bollard
        var directions: [Direction]
    }

    struct Bollard: Decodable, Sendable {
        var tag: String
        var name: String
    }

    struct Direction: Decodable, Sendable {
        var lineName: String
        var direction: String
    }

    struct LineBollards: Decodable, Sendable {
        struct Entry: Decodable, Sendable {
            var direction: Direction
            var bollards: [LineBollard]
        }
        var directions: [Entry]
    }

    struct LineBollard: Decodable, Sendable {
        var tag: String
        var name: String
        var orderNo: Int
    }

    struct TimesBody: Decodable, Sendable {
        var times: [Time]
    }

    struct Time: Decodable, Sendable {
        var line: String
        var direction: String
        var departure: String
        var minutes: Int?
        var realTime: Bool?
        var vehicle: String?
    }
    struct StopLayer: Decodable, Sendable {
        struct Feature: Decodable, Sendable {
            struct Geometry: Decodable, Sendable { var coordinates: [Double] }
            struct Properties: Decodable, Sendable { var stop_name: String }
            var id: String
            var geometry: Geometry
            var properties: Properties
        }
        var features: [Feature]
    }

    /// "2026-09-22T11:28:00.000Z" is 11:28 in Poznań, not UTC.
    static func parseLocal(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = PoznanProvider.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: String(string.prefix(19)))
    }
}