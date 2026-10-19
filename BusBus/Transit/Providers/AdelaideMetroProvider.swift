import Compression
import Foundation

/// Australia, Adelaide — Adelaide Metro (Department for Infrastructure and Transport, South
/// Australia), official and keyless. Data and website content are licensed under Creative Commons
/// Attribution; the credit asked for is the `attribution` line, verbatim. See
/// docs/research/worldwide-apis.md §8.5.
///
/// - Arrivals: SIRI Stop Monitoring JSON (realtime.adelaidemetro.com.au, ~5 KB per stop and line).
///   `MonitoringRef` is the public stop code, `LineRef` the GTFS `route_id`, `DirectionRef` "I"/"O"
///   the GTFS `direction_id` 0/1. Visits carry the timetable time, the prediction and whether the bus
///   is tracked. Documented limits: at most one similar request a minute, 4 requests a second per IP.
/// - Positions: the city-wide GTFS-RT VehiclePosition feed (~10–15 KB of protobuf, refreshed every
///   15 s), filtered by `route_id` and `direction_id`.
/// - Stops, lines at a stop and ordered patterns: SIRI has no discovery services on this host (only
///   Stop Monitoring answers) and the website's own endpoints sit behind a Cloudflare challenge, so
///   they come from the official GTFS zip (~15 MB). Its files are not published one by one, but
///   the archive is served with byte ranges, so only the entries needed are fetched out of it:
///   `stops.txt` alone (~350 KB deflated) for search, and for lines and patterns `routes.txt`,
///   `trips.txt` and `stop_times.txt` too (~6.2 MB deflated, ~43 MB of CSV, streamed). That
///   one-time ~6.5 MB download is folded into a compact index (~1.7k stop patterns) kept on disk
///   for a week.
nonisolated struct AdelaideMetroProvider: TransitProvider {
    let id = "adelaide-metro"
    let displayName = "Adelaide Metro"
    let attribution: String? = "Adelaide Metro – Department for Infrastructure and Transport, South Australia"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .scheduledArrivals, .nearbyStops,
    ]
    /// Positions are regenerated every 15 s; the SIRI arrivals are held for a minute (its limit).
    let suggestedRefreshInterval: Duration = .seconds(15)

    var http = HTTPClient()

    fileprivate static let siri = "https://realtime.adelaidemetro.com.au/SiriWebServiceSAVM/SiriStopMonitoring.svc/json"
    fileprivate static let gtfs = "https://gtfs.adelaidemetro.com.au/v1"
    private var store: AdelaideStore { .shared }

    // MARK: - Stops

    /// A number is the code on the pole; anything else is matched word by word against the stop
    /// name and its street address ("King William", "Parade Norwood").
    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let stops = try await store.stops()
        if query.allSatisfy(\.isNumber), let byCode = stops.byCode[query] {
            return byCode.map(\.stop)
        }
        let needle = AdelaideStops.fold(query)
        let words = needle.split(separator: " ").map(String.init)
        return stops.all
            .filter { entry in words.allSatisfy(entry.folded.contains) }
            .sorted { a, b in
                let ar = a.foldedName.hasPrefix(needle) ? 0 : a.foldedName.contains(needle) ? 1 : 2
                let br = b.foldedName.hasPrefix(needle) ? 0 : b.foldedName.contains(needle) ? 1 : 2
                return ar != br ? ar < br : (a.stop.name, a.stop.code) < (b.stop.name, b.stop.code)
            }
            .prefix(50)
            .map(\.stop)
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let network = try await store.network()
        guard network.stops.byCode[stop.code] != nil else { throw TransitError.notFound("stop \(stop.code)") }
        return network.lines(at: stop.code)
    }

    /// Stops within the radius, from the cached stop list, with the lines of the network index.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let network = try await store.network()
        let latSpan = radiusMeters / 111_000
        let lonSpan = latSpan / max(cos(point.lat * .pi / 180), 0.01)
        return network.stops.all
            .filter { abs($0.stop.location.lat - point.lat) <= latSpan && abs($0.stop.location.lon - point.lon) <= lonSpan }
            .map { ($0.stop, RouteGeometry.meters(point, $0.stop.location)) }
            .filter { $0.1 <= radiusMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(30)
            .compactMap { stop, distance in
                let lines = network.lines(at: stop.code)
                return lines.isEmpty ? nil : NearbyStop(stop: stop, distanceMeters: distance, lines: lines)
            }
    }

    // MARK: - Lines

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let network = try await store.network()
        guard let pattern = network.pattern(for: Ref(line)) else { throw TransitError.notFound("pattern of \(line.id)") }
        let stops = pattern.stops.enumerated().compactMap { index, stopID -> PatternStop? in
            guard let stop = network.stops.byID[stopID]?.stop else { return nil }
            // `shape_dist_traveled` is published in kilometres.
            let distance = pattern.distances.flatMap { index < $0.count ? $0[index] * 1_000 : nil }
            return PatternStop(stop: stop, sequence: index + 1, distanceAlongRoute: distance)
        }
        guard stops.count >= 2 else { throw TransitError.notFound("stops of \(line.id)") }
        return RoutePattern(line: line, stops: stops)
    }

    // MARK: - Live

    /// The whole city's feed, shared by every line on the board for 10 s.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let ref = Ref(line)
        return try await store.vehicleFeed()
            .filter { $0.routeID == ref.route && ($0.directionID.map { String($0) == ref.direction } ?? true) }
            .map { v in
                VehiclePosition(
                    location: GeoPoint(lat: v.lat, lon: v.lon),
                    recordedAt: v.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    tripId: v.tripID,
                    plateNumber: v.label,
                    bearing: v.bearing,
                    speedKmh: v.speed.map { $0 * 3.6 }
                )
            }
    }

    /// The next 90 minutes of the line at the stop. A tracked bus (`VehicleRef`) carries a
    /// prediction and its position; the rest are the timetable.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let ref = Ref(line)
        let siriDirection = ref.direction == "0" ? "I" : "O"
        let key = "\(stop.code)/\(ref.route)/\(siriDirection)"
        let visits = try await store.visits(key) { [http] in
            try await http.get(DTO.Response.self, Self.siri, "/SM", query: [
                "MonitoringRef": stop.code, "LineRef": ref.route, "DirectionRef": siriDirection, "PreviewInterval": "90",
            ]).StopMonitoringDelivery?.first?.MonitoredStopVisit ?? []
        }
        let cutoff = Date().addingTimeInterval(-60)
        return visits
            .compactMap { visit -> Arrival? in
                let journey = visit.MonitoredVehicleJourney
                guard journey.LineRef?.Value == ref.route, (journey.DirectionRef?.Value ?? siriDirection) == siriDirection else { return nil }
                let aimed = DTO.date(journey.MonitoredCall?.AimedArrivalTime)
                let predicted = DTO.date(journey.MonitoredCall?.LatestExpectedArrivalTime)
                // `Monitored` is true on every visit, even hours ahead; a timetable-only one has no
                // `VehicleRef`, a prediction equal to the timetable and the stop's own coordinates.
                let hasBus = journey.VehicleRef?.Value?.isEmpty == false
                let tracked = journey.Monitored == true && predicted != nil && (hasBus || predicted != aimed)
                guard let expected = tracked ? predicted : aimed ?? predicted, expected >= cutoff else { return nil }
                return Arrival(
                    expectedAt: expected,
                    scheduledAt: aimed,
                    isRealtime: tracked,
                    tripId: journey.FramedVehicleJourneyRef?.DatedVehicleJourneyRef,
                    vehicleLocation: hasBus ? journey.VehicleLocation?.point : nil
                )
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// A line is one direction of one route, drawn as its busiest pattern through the stop it was
    /// picked at (`via`), and otherwise its busiest pattern between the same two ends.
    fileprivate nonisolated struct Ref {
        var route: String
        var direction: String
        var from: String?
        var to: String?
        var via: String?

        init(_ line: TransitLine) {
            let parts = line.id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            route = line.providerRefs["route"] ?? parts.first ?? line.id
            direction = line.providerRefs["direction"] ?? (parts.count > 1 ? parts[1] : "0")
            from = line.providerRefs["from"] ?? (parts.count > 2 ? parts[2] : nil)
            to = line.providerRefs["to"] ?? (parts.count > 3 ? parts[3] : nil)
            via = line.providerRefs["via"]
        }
    }
}

// MARK: - Session cache

private actor AdelaideStore {
    static let shared = AdelaideStore()

    /// The index is rebuilt weekly; the timetable version changes more often, but stops and
    /// patterns hardly ever do, and the realtime feeds name routes and stops the same way.
    static let lifetime: TimeInterval = 7 * 24 * 3600

    private var stopsTask: Task<AdelaideStops, any Error>?
    private var networkTask: Task<AdelaideNetwork, any Error>?
    private var feed: (fetched: ContinuousClock.Instant, task: Task<[GTFSRealtime.Vehicle], any Error>)?
    private var stopVisits: [String: (fetched: ContinuousClock.Instant, task: Task<[DTO.Visit], any Error>)] = [:]

    /// Stops for search: the network's when it is at hand, otherwise `stops.txt` on its own.
    func stops() async throws -> AdelaideStops {
        if let networkTask, let network = try? await networkTask.value { return network.stops }
        if let fresh = AdelaideDisk.read(AdelaideNetwork.Stored.self, "network", maxAge: Self.lifetime) {
            return try await network(preloaded: fresh).stops
        }
        if let stopsTask { return try await stopsTask.value }
        let task = Task {
            if let stored = AdelaideDisk.read([AdelaideStops.Row].self, "stops", maxAge: Self.lifetime) {
                return AdelaideStops(stored)
            }
            do {
                let zip = try await GTFSZip.latest()
                let rows = try AdelaideStops.parse(try await zip.text("stops.txt"))
                AdelaideDisk.write(rows, "stops")
                return AdelaideStops(rows)
            } catch {
                if let stale = AdelaideDisk.read([AdelaideStops.Row].self, "stops", maxAge: nil) { return AdelaideStops(stale) }
                throw error
            }
        }
        stopsTask = task
        do { return try await task.value } catch { stopsTask = nil; throw error }
    }

    func network(preloaded: AdelaideNetwork.Stored? = nil) async throws -> AdelaideNetwork {
        if let networkTask { return try await networkTask.value }
        let task = Task {
            if let stored = preloaded ?? AdelaideDisk.read(AdelaideNetwork.Stored.self, "network", maxAge: Self.lifetime) {
                return AdelaideNetwork(stored)
            }
            do {
                let stored = try await AdelaideNetwork.build()
                AdelaideDisk.write(stored, "network")
                return AdelaideNetwork(stored)
            } catch {
                if let stale = AdelaideDisk.read(AdelaideNetwork.Stored.self, "network", maxAge: nil) { return AdelaideNetwork(stale) }
                throw error
            }
        }
        networkTask = task
        do { return try await task.value } catch { networkTask = nil; throw error }
    }

    func vehicleFeed() async throws -> [GTFSRealtime.Vehicle] {
        if let feed, ContinuousClock.now - feed.fetched < .seconds(10) { return try await feed.task.value }
        let task = Task {
            guard let url = URL(string: AdelaideMetroProvider.gtfs + "/realtime/vehicle_positions") else {
                throw TransitError.badResponse("invalid vehicle feed URL")
            }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("BusBus-iOS/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            try HTTPClient.check(data, response, request, url.path)
            return try GTFSRealtime.vehicles(data)
        }
        feed = (ContinuousClock.now, task)
        do { return try await task.value } catch { feed = nil; throw error }
    }

    /// One stop, line and direction, asked at most once a minute (the service's limit).
    func visits(_ key: String, _ load: @escaping @Sendable () async throws -> [DTO.Visit]) async throws -> [DTO.Visit] {
        let now = ContinuousClock.now
        if let cached = stopVisits[key], now - cached.fetched < .seconds(60) { return try await cached.task.value }
        stopVisits = stopVisits.filter { now - $0.value.fetched < .seconds(60) }
        let task = Task { try await load() }
        stopVisits[key] = (now, task)
        do { return try await task.value } catch { stopVisits[key] = nil; throw error }
    }
}

/// The index files, in Caches: the system may purge them, and they are rebuilt from the zip.
private nonisolated enum AdelaideDisk {
    private struct Envelope<Value: Codable>: Codable {
        var storedAt: Date
        var value: Value
    }

    private static func url(_ name: String) -> URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("BusBus/adelaide-metro", isDirectory: true)
            .appendingPathComponent(name + ".json")
    }

    static func read<Value: Codable>(_ type: Value.Type, _ name: String, maxAge: TimeInterval?) -> Value? {
        guard let url = url(name), let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope<Value>.self, from: data) else { return nil }
        if let maxAge, Date().timeIntervalSince(envelope.storedAt) > maxAge { return nil }
        return envelope.value
    }

    static func write<Value: Codable>(_ value: Value, _ name: String) {
        guard let url = url(name), let data = try? JSONEncoder().encode(Envelope(storedAt: Date(), value: value)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Stops and network index

private nonisolated struct AdelaideStops: Sendable {
    /// One boarding point of `stops.txt`; stations (`location_type` 1) carry no code and are left out.
    struct Row: Codable, Sendable {
        var id: String
        var code: String
        var name: String
        var desc: String?
        var lat: Double
        var lon: Double
    }

    struct Entry: Sendable {
        var stop: TransitStop
        var foldedName: String
        /// Name and street address.
        var folded: String
    }

    let all: [Entry]
    let byID: [String: Entry]
    let byCode: [String: [Entry]]

    init(_ rows: [Row]) {
        var byID: [String: Entry] = [:]
        let entries = rows.map { row -> Entry in
            // "35-37 The Parade, Norwood": the street address, then the suburb.
            let parts = row.desc?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            let stop = TransitStop(
                code: row.code, name: row.name, city: parts.count > 1 ? parts.last : nil,
                location: GeoPoint(lat: row.lat, lon: row.lon),
                address: TransitStop.address(parts.count > 1 ? parts.dropLast().map { $0 } : parts, separator: ", ")
            )
            let entry = Entry(stop: stop, foldedName: Self.fold(row.name), folded: Self.fold(row.name + " " + (row.desc ?? "")))
            byID[row.id] = entry
            return entry
        }
        all = entries
        self.byID = byID
        byCode = Dictionary(grouping: entries, by: \.stop.code)
    }

    static func parse(_ csv: String) throws -> [Row] {
        try CSV.rows(csv, columns: ["stop_id", "stop_code", "stop_name", "stop_desc", "stop_lat", "stop_lon", "location_type"])
            .compactMap { f in
                guard f[6] == "" || f[6] == "0", !f[1].isEmpty, let lat = Double(f[4]), let lon = Double(f[5]) else { return nil }
                return Row(id: f[0], code: f[1], name: f[2], desc: f[3].isEmpty ? nil : f[3], lat: lat, lon: lon)
            }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// Every distinct stop sequence of every route and direction, with how many trips run it.
private nonisolated struct AdelaideNetwork: Sendable {
    struct Route: Codable, Sendable {
        var shortName: String
        var longName: String?
        var agency: String?
    }

    struct Pattern: Codable, Sendable {
        var route: String
        var direction: String
        var headsign: String?
        var trips: Int
        var stops: [String]
        /// Kilometres from the first stop (`shape_dist_traveled`), when every stop has one.
        var distances: [Double]?
    }

    struct Stored: Codable, Sendable {
        var stops: [AdelaideStops.Row]
        var routes: [String: Route]
        var patterns: [Pattern]
    }

    let stops: AdelaideStops
    let routes: [String: Route]
    let patterns: [Pattern]
    /// stop code → indices of the patterns calling there.
    let patternsAt: [String: [Int]]

    init(_ stored: Stored) {
        let stops = AdelaideStops(stored.stops)
        self.stops = stops
        routes = stored.routes
        patterns = stored.patterns
        var patternsAt: [String: [Int]] = [:]
        for (index, pattern) in stored.patterns.enumerated() {
            for code in Set(pattern.stops.compactMap { stops.byID[$0]?.stop.code }) {
                patternsAt[code, default: []].append(index)
            }
        }
        self.patternsAt = patternsAt
    }

    /// One line per route and direction calling here, drawn as its busiest pattern through the stop.
    /// Directions that only end here are left out unless nothing else serves the stop (a terminus).
    func lines(at stopCode: String) -> [TransitLine] {
        let calling = (patternsAt[stopCode] ?? []).map { (index: $0, ends: code(of: patterns[$0].stops.last) == stopCode) }
        let boarding = calling.filter { !$0.ends }
        let chosen = Dictionary(grouping: boarding.isEmpty ? calling : boarding) {
            "\(patterns[$0.index].route)|\(patterns[$0.index].direction)"
        }
        .compactMap { _, options in options.max { patterns[$0.index].trips < patterns[$1.index].trips } }
        return chosen
            .compactMap { line(patterns[$0.index], via: stopCode) }
            .sorted { a, b in
                a.shortName != b.shortName
                    ? a.shortName.localizedStandardCompare(b.shortName) == .orderedAscending
                    : a.id < b.id
            }
    }

    func pattern(for ref: AdelaideMetroProvider.Ref) -> Pattern? {
        let candidates = patterns.filter { $0.route == ref.route && $0.direction == ref.direction }
        let sameEnds = candidates.filter { code(of: $0.stops.first) == ref.from && code(of: $0.stops.last) == ref.to }
        let through = sameEnds.filter { p in ref.via.map { via in p.stops.contains { code(of: $0) == via } } ?? true }
        let pool = !through.isEmpty ? through : !sameEnds.isEmpty ? sameEnds : candidates
        return pool.max { $0.trips < $1.trips }
    }

    private func code(of stopID: String?) -> String? { stopID.flatMap { stops.byID[$0]?.stop.code } }

    private func line(_ pattern: Pattern, via: String) -> TransitLine? {
        guard let first = pattern.stops.first.flatMap({ stops.byID[$0] }),
              let last = pattern.stops.last.flatMap({ stops.byID[$0] }) else { return nil }
        let route = routes[pattern.route]
        return TransitLine(
            id: [pattern.route, pattern.direction, first.stop.code, last.stop.code].joined(separator: "|"),
            shortName: route?.shortName ?? pattern.route,
            headsign: pattern.headsign ?? last.stop.name,
            agency: route?.agency,
            origin: first.stop.name,
            destination: last.stop.name,
            providerRefs: [
                "route": pattern.route, "direction": pattern.direction,
                "from": first.stop.code, "to": last.stop.code, "via": via,
            ]
        )
    }

    /// `agency`, `routes`, `trips`, `stops` and `stop_times` out of the current timetable zip.
    static func build() async throws -> Stored {
        let zip = try await GTFSZip.latest()
        async let agencyText = zip.text("agency.txt")
        async let routesText = zip.text("routes.txt")
        async let tripsText = zip.text("trips.txt")
        async let stopsText = zip.text("stops.txt")
        async let stopTimesBody = zip.compressed("stop_times.txt")

        let agencies = Dictionary(
            try CSV.rows(try await agencyText, columns: ["agency_id", "agency_name"]).map { ($0[0], $0[1]) },
            uniquingKeysWith: { a, _ in a })
        let routes = Dictionary(
            try CSV.rows(try await routesText, columns: ["route_id", "agency_id", "route_short_name", "route_long_name"]).map { f in
                (f[0], Route(shortName: f[2].isEmpty ? f[0] : f[2], longName: f[3].isEmpty ? nil : f[3], agency: agencies[f[1]]))
            },
            uniquingKeysWith: { a, _ in a })
        var trips: [String: (route: String, direction: String, headsign: String)] = [:]
        for f in try CSV.rows(try await tripsText, columns: ["trip_id", "route_id", "direction_id", "trip_headsign"]) {
            trips[f[0]] = (f[1], f[2].isEmpty ? "0" : f[2], f[3])
        }
        let stops = try AdelaideStops.parse(try await stopsText)

        let collector = PatternCollector(trips: trips)
        try GTFSZip.inflateLines(try await stopTimesBody, into: collector)
        let patterns = try collector.finish()
        guard !patterns.isEmpty else { throw TransitError.badResponse("Adelaide Metro stop_times.txt gave no patterns") }
        return Stored(stops: stops, routes: routes, patterns: patterns)
    }
}

/// Reads `stop_times.txt` line by line as it inflates (it is ~43 MB, grouped by trip) and keeps
/// only the distinct stop sequences, counted per route and direction.
private final nonisolated class PatternCollector: LineSink {
    private let trips: [String: (route: String, direction: String, headsign: String)]
    private var columns: (trip: Int, stop: Int, sequence: Int, distance: Int?)?
    private var currentTrip = ""
    private var rows: [(sequence: Int, stop: String, distance: Double?)] = []
    private struct Key: Hashable { var route: String, direction: String, stops: [String] }
    private var found: [Key: (trips: Int, headsigns: [String: Int], distances: [Double]?)] = [:]

    init(trips: [String: (route: String, direction: String, headsign: String)]) { self.trips = trips }

    func line(_ bytes: ArraySlice<UInt8>) throws {
        let fields = CSV.split(bytes)
        guard let columns else {
            let header = fields.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}\r")) }
            guard let trip = header.firstIndex(of: "trip_id"), let stop = header.firstIndex(of: "stop_id"),
                  let sequence = header.firstIndex(of: "stop_sequence") else {
                throw TransitError.badResponse("stop_times.txt header \(header)")
            }
            self.columns = (trip, stop, sequence, header.firstIndex(of: "shape_dist_traveled"))
            return
        }
        guard fields.count > max(columns.trip, columns.stop, columns.sequence), let sequence = Int(fields[columns.sequence]) else { return }
        let trip = fields[columns.trip]
        if trip != currentTrip { flush(); currentTrip = trip }
        let distance = columns.distance.flatMap { $0 < fields.count ? Double(fields[$0]) : nil }
        rows.append((sequence, fields[columns.stop], distance))
    }

    private func flush() {
        defer { rows.removeAll(keepingCapacity: true) }
        guard rows.count >= 2, let trip = trips[currentTrip] else { return }
        let ordered = rows.sorted { $0.sequence < $1.sequence }
        let key = Key(route: trip.route, direction: trip.direction, stops: ordered.map(\.stop))
        var entry = found[key] ?? (0, [:], nil)
        if entry.trips == 0 {
            let distances = ordered.compactMap(\.distance)
            entry.distances = distances.count == ordered.count ? distances : nil
        }
        entry.trips += 1
        if !trip.headsign.isEmpty { entry.headsigns[trip.headsign, default: 0] += 1 }
        found[key] = entry
    }

    func finish() throws -> [AdelaideNetwork.Pattern] {
        flush()
        return found.map { key, value in
            AdelaideNetwork.Pattern(
                route: key.route, direction: key.direction,
                headsign: value.headsigns.max { $0.value < $1.value }?.key,
                trips: value.trips, stops: key.stops, distances: value.distances
            )
        }
        .sorted { ($0.route, $0.direction, $1.trips) < ($1.route, $1.direction, $0.trips) }
    }
}

// MARK: - GTFS zip, read with byte ranges

private nonisolated protocol LineSink: AnyObject {
    func line(_ bytes: ArraySlice<UInt8>) throws
}

/// Entries of the timetable zip without downloading the archive: one range request for the central
/// directory at its tail (~1 KB), one per entry. The versioned URL is used so that a new timetable
/// published mid-read cannot shift the offsets under us.
private nonisolated struct GTFSZip: Sendable {
    struct Entry: Sendable {
        var method: Int
        var compressedSize: Int
        var size: Int
        var offset: Int
    }

    let url: URL
    let entries: [String: Entry]

    static func latest() async throws -> GTFSZip {
        guard let versionURL = URL(string: AdelaideMetroProvider.gtfs + "/static/latest/version.txt") else {
            throw TransitError.badResponse("invalid GTFS version URL")
        }
        let raw = try await get(versionURL, range: nil).data
        // `version.txt` is a bare number ("1703"), served as JSON.
        let version = String(decoding: raw, as: UTF8.self).filter(\.isNumber)
        guard !version.isEmpty, let url = URL(string: AdelaideMetroProvider.gtfs + "/static/\(version)/google_transit.zip") else {
            throw TransitError.badResponse("GTFS version.txt said \(String(decoding: raw.prefix(40), as: UTF8.self))")
        }
        let (tail, total) = try await get(url, range: "bytes=-8192")
        guard let total, let eocd = lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: tail) else {
            throw TransitError.badResponse("GTFS zip has no end of central directory")
        }
        let count = tail.u16(eocd + 10), directorySize = tail.u32(eocd + 12), directoryOffset = tail.u32(eocd + 16)
        let tailStart = total - tail.count
        let directory = directoryOffset >= tailStart
            ? tail.subdata(in: (directoryOffset - tailStart)..<(directoryOffset - tailStart + directorySize))
            : try await get(url, range: "bytes=\(directoryOffset)-\(directoryOffset + directorySize - 1)").data
        var entries: [String: Entry] = [:]
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= directory.count, directory.u32(p) == 0x0201_4B50 else { break }
            let nameLength = directory.u16(p + 28)
            let name = String(decoding: directory.subdata(in: (p + 46)..<(p + 46 + nameLength)), as: UTF8.self)
            entries[name] = Entry(method: directory.u16(p + 10), compressedSize: directory.u32(p + 20),
                                  size: directory.u32(p + 24), offset: directory.u32(p + 42))
            p += 46 + nameLength + directory.u16(p + 30) + directory.u16(p + 32)
        }
        return GTFSZip(url: url, entries: entries)
    }

    /// The entry's raw (deflated) bytes. The local header's extra field may differ from the
    /// central one, so some slack is asked for and the rest fetched if it fell short.
    func compressed(_ name: String) async throws -> (entry: Entry, body: Data) {
        guard let entry = entries[name] else { throw TransitError.notFound("\(name) in GTFS zip") }
        var chunk = try await Self.get(url, range: "bytes=\(entry.offset)-\(entry.offset + 30 + 1_024 + entry.compressedSize - 1)").data
        guard chunk.count >= 30, chunk.u32(0) == 0x0403_4B50 else { throw TransitError.badResponse("\(name): no local header") }
        let start = 30 + chunk.u16(26) + chunk.u16(28)
        if start + entry.compressedSize > chunk.count {
            chunk = try await Self.get(url, range: "bytes=\(entry.offset)-\(entry.offset + start + entry.compressedSize - 1)").data
        }
        return (entry, chunk.subdata(in: start..<(start + entry.compressedSize)))
    }

    /// A small entry, whole, as text.
    func text(_ name: String) async throws -> String {
        let (entry, body) = try await compressed(name)
        guard entry.method != 0 else { return String(decoding: body, as: UTF8.self) }
        var output = Data(count: entry.size)
        let written = output.withUnsafeMutableBytes { out in
            body.withUnsafeBytes { input in
                // Zip entries are raw DEFLATE, which is what Compression's `COMPRESSION_ZLIB` decodes.
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                                          input.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == entry.size else { throw TransitError.badResponse("\(name) inflated to \(written) of \(entry.size) bytes") }
        return String(decoding: output, as: UTF8.self)
    }

    /// A large entry, inflated in 64 KB steps and handed over a line at a time, so the CSV is never
    /// held whole.
    static func inflateLines(_ compressed: (entry: Entry, body: Data), into sink: some LineSink) throws {
        var pending: [UInt8] = []
        func consume(_ chunk: Data) throws {
            pending.append(contentsOf: chunk)
            var start = 0
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                try sink.line(pending[start..<newline])
                start = newline + 1
            }
            pending.removeFirst(start)
        }
        if compressed.entry.method == 0 {
            try consume(compressed.body)
        } else {
            let filter = try OutputFilter(.decompress, using: .zlib, bufferCapacity: 65_536) { chunk in
                if let chunk { try consume(chunk) }
            }
            var offset = 0
            let body = compressed.body
            while offset < body.count {
                let end = min(offset + 65_536, body.count)
                try filter.write(body.subdata(in: offset..<end))
                offset = end
            }
            try filter.finalize()
        }
        if !pending.isEmpty { try sink.line(pending[...]) }
    }

    private static func get(_ url: URL, range: String?) async throws -> (data: Data, total: Int?) {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("BusBus-iOS/1.0", forHTTPHeaderField: "User-Agent")
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTPClient.check(data, response, request, url.lastPathComponent)
        guard range != nil else { return (data, nil) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            throw ResponseError("GTFS zip range request answered without a range", data, response, request)
        }
        // "bytes a-b/total"
        return (data, http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int($0) })
    }

    private static func lastIndex(of signature: [UInt8], in data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= signature.count else { return nil }
        return stride(from: bytes.count - signature.count, through: 0, by: -1).first {
            bytes[$0..<($0 + signature.count)].elementsEqual(signature)
        }
    }
}

private nonisolated extension Data {
    func u16(_ at: Int) -> Int { Int(self[startIndex + at]) | Int(self[startIndex + at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
}

/// GTFS CSV: comma-separated, fields optionally in double quotes (`""` inside one is a quote).
private nonisolated enum CSV {
    /// The named columns of every data row, in the order asked ("" where a column is missing).
    static func rows(_ text: String, columns: [String]) throws -> [[String]] {
        var lines = text.split(whereSeparator: \.isNewline).makeIterator()
        guard let first = lines.next() else { return [] }
        let header = split(ArraySlice(first.utf8)).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")) }
        let indices = columns.map { header.firstIndex(of: $0) }
        guard indices.first! != nil else { throw TransitError.badResponse("GTFS header without \(columns[0]): \(header)") }
        var result: [[String]] = []
        while let line = lines.next() {
            let fields = split(ArraySlice(line.utf8))
            result.append(indices.map { $0.flatMap { $0 < fields.count ? fields[$0] : nil } ?? "" })
        }
        return result
    }

    static func split<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> [String] {
        var fields: [String] = []
        var field: [UInt8] = []
        var quoted = false
        var iterator = bytes.makeIterator()
        var next = iterator.next()
        while let byte = next {
            next = iterator.next()
            switch byte {
            case 0x22 where quoted && next == 0x22: field.append(0x22); next = iterator.next()
            case 0x22: quoted.toggle()
            case 0x2C where !quoted: fields.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true)
            case 0x0D where !quoted && next == nil: break
            default: field.append(byte)
            }
        }
        fields.append(String(decoding: field, as: UTF8.self))
        return fields
    }
}

// MARK: - Wire format (SIRI Stop Monitoring, WCF JSON)

private nonisolated enum DTO {
    struct Value: Decodable, Sendable { var Value: String? }

    struct Response: Decodable, Sendable {
        var StopMonitoringDelivery: [Delivery]?
    }

    struct Delivery: Decodable, Sendable {
        var MonitoredStopVisit: [Visit]?
    }

    struct Visit: Decodable, Sendable {
        var MonitoredVehicleJourney: Journey
    }

    struct Journey: Decodable, Sendable {
        struct Framed: Decodable, Sendable { var DatedVehicleJourneyRef: String? }
        struct Call: Decodable, Sendable {
            var AimedArrivalTime: String?
            var LatestExpectedArrivalTime: String?
        }
        struct Location: Decodable, Sendable {
            /// ["-34.924520", "138.5857"]: latitude, longitude.
            var Items: [String]?
            var point: GeoPoint? {
                guard let items = Items, items.count == 2, let lat = Double(items[0]), let lon = Double(items[1]),
                      lat != 0 || lon != 0 else { return nil }
                return GeoPoint(lat: lat, lon: lon)
            }
        }

        var LineRef: Value?
        var DirectionRef: Value?
        /// The fleet number, present only when a bus is actually assigned and reporting.
        var VehicleRef: Value?
        var FramedVehicleJourneyRef: Framed?
        var Monitored: Bool?
        var MonitoredCall: Call?
        var VehicleLocation: Location?
    }

    /// WCF dates, "/Date(1790604014000+0930)/": Unix milliseconds, then the offset it was written
    /// in. "/Date(0)/" means unset.
    static func date(_ raw: String?) -> Date? {
        guard let raw, let open = raw.firstIndex(of: "("),
              let millis = Double(raw[raw.index(after: open)...].prefix(while: \.isNumber)), millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1_000)
    }
}
