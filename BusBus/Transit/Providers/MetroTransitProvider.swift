import Compression
import Foundation

/// US, Minneapolis–St Paul — Metro Transit NexTrip v2 (svc.metrotransit.org/nextrip), official and
/// keyless, no published rate limit or API-specific terms. Stop ids are the public stop numbers.
///
/// NexTrip itself has no stop coordinates for a route (its `/stops/{route}/{dir}` are timepoints
/// without positions), no name search and no proximity query. So:
/// - stop positions and names come from `stops.txt` of the official GTFS zip, pulled out of the
///   19 MB archive with two HTTP range requests (~200 KB) once per session;
/// - the ordered stop list of a line comes from the sibling Schedule API (`/schedule/stoplist`);
/// - lines at a stop are the routes/directions in its upcoming departures, then every other line
///   the timetable stops there, from an index built off the GTFS (`MetroTransitStopLines.json`,
///   made by `scripts/metrotransit-stop-index.py`).
nonisolated struct MetroTransitProvider: TransitProvider {
    let id = "metrotransit"
    let displayName = "Metro Transit (Minneapolis–St Paul)"
    let attribution: String? = "Data: Metro Transit (NexTrip)"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .scheduledArrivals, .nearbyStops,
    ]
    /// Vehicle fixes arrive 25–45 s old, so polling faster buys nothing.
    let suggestedRefreshInterval: Duration = .seconds(30)

    var http = HTTPClient()

    private let nextrip = "https://svc.metrotransit.org/nextrip"
    private let schedule = "https://svc.metrotransit.org/schedule"
    private static let gtfsZip = URL(string: "https://svc.metrotransit.org/mtgtfs/gtfs.zip")!
    private static let timeZone = TimeZone(identifier: "America/Chicago")!

    /// `agency_id` → name, from `/nextrip/agencies` (stable; not worth a call).
    fileprivate static let agencies = [
        0: "Metro Transit", 1: "Metro Transit/Met Council", 2: "Met Council", 3: "Minnesota Valley",
        4: "Maple Grove", 5: "Plymouth", 6: "SouthWest Transit", 10: "Airport (MAC)", 11: "University of Minnesota",
    ]

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        // An unknown stop number is an HTTP 400 ("Invalid Stop ID"); fall through to names then.
        if query.allSatisfy(\.isNumber),
           let result = try? await http.get(DTO.NexTripResult.self, nextrip, "/\(query)"),
           let stop = result.stops?.first?.stop {
            return [stop]
        }
        return MetroTransitNameSearch.match(query, in: try await allStops())
    }

    /// Routes and directions in the stop's upcoming departures (schedule and live), in the order
    /// they next leave, then the timetable's other lines there. NexTrip alone knows only the lines
    /// with a trip in its window, so overnight every stop would seem to have none, and a peak-only
    /// express would be missing off-peak.
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let result = try await http.get(DTO.NexTripResult.self, nextrip, "/\(stop.code)")
        return Self.merge(live: (result.departures ?? []).map(\.line),
                          scheduled: MetroTransitStopIndex.shared.lines(atStop: stop.code))
    }

    /// The departures' lines first, each once, then the timetable's lines they did not name.
    static func merge(live: [TransitLine], scheduled: [TransitLine]) -> [TransitLine] {
        var seen = Set<String>()
        return (live + scheduled).filter { seen.insert($0.id).inserted }
    }

    /// Nearest GTFS stops within the radius (at most 8), each asked for its lines — NexTrip has no
    /// proximity query, so this is the one place the adapter fans out.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let near = try await allStops()
            .map { ($0, RouteGeometry.meters(point, $0.location)) }
            .filter { $0.1 <= radiusMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(8)
        let results = await withTaskGroup(of: NearbyStop?.self) { group in
            for (stop, distance) in near {
                group.addTask {
                    guard let lines = try? await self.lines(atStop: stop), !lines.isEmpty else { return nil }
                    return NearbyStop(stop: stop, distanceMeters: distance, lines: lines)
                }
            }
            var found: [NearbyStop] = []
            for await stop in group { if let stop { found.append(stop) } }
            return found
        }
        return results.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    /// Schedule API: route → today's timetable for the direction → its full ordered stop list.
    /// Positions come from the GTFS stop cache.
    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let ref = Ref(line)
        let params = try await MetroTransitCaches.routeParams.value {
            let routes = try await http.get([DTO.ScheduleRoute].self, schedule, "/routes")
            return Dictionary(routes.compactMap { r in r.routeUrlParam.map { (r.routeId ?? "", $0) } },
                              uniquingKeysWith: { first, _ in first })
        }
        guard let param = params[ref.route] else {
            throw TransitError.notFound("timetable for route \(ref.route)")
        }
        let details = try await http.get(DTO.RouteDetails.self, schedule, "/routedetails/\(param)")
        guard let number = details.scheduleNumber(direction: ref.direction, dayType: DayType.today(in: Self.timeZone).rawValue) else {
            throw TransitError.notFound("timetable for route \(ref.route) direction \(ref.direction)")
        }
        let list = try await http.get([DTO.StopListItem].self, schedule, "/stoplist/\(ref.route)/\(number)")
        let byCode = Dictionary(try await allStops().map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
        let stops = list.compactMap { byCode[String($0.stopId)] }
        guard stops.count >= 2 else { throw TransitError.notFound("stops for route \(ref.route) direction \(ref.direction)") }
        var pattern = line
        if pattern.origin == nil { pattern.origin = stops.first?.name }
        if pattern.destination == nil { pattern.destination = stops.last?.name }
        return RoutePattern(
            line: pattern,
            stops: stops.enumerated().map { PatternStop(stop: $1, sequence: $0 + 1, distanceAlongRoute: nil) }
        )
    }

    /// Every vehicle of the route; ones not currently on a trip report 0,0 and are dropped.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let ref = Ref(line)
        let vehicles = try await http.get([DTO.Vehicle].self, nextrip, "/vehicles/\(ref.route)")
        return vehicles.compactMap { v in
            guard String(v.directionId ?? -1) == ref.direction, let lat = v.latitude, let lon = v.longitude,
                  lat != 0 || lon != 0 else { return nil }
            return VehiclePosition(
                location: GeoPoint(lat: lat, lon: lon),
                recordedAt: v.locationTime.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                tripId: v.tripId,
                bearing: v.bearing
                // `speed` is published without a documented unit, so it is left out.
            )
        }
    }

    /// `departure_time` is the prediction when `actual` is true and the timetable otherwise; the
    /// feed never gives both, so a live departure carries no scheduled time.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let ref = Ref(line)
        let result = try await http.get(DTO.NexTripResult.self, nextrip, "/\(stop.code)")
        return (result.departures ?? [])
            .filter { $0.routeId == ref.route && String($0.directionId ?? -1) == ref.direction }
            .filter { !["skipped", "canceled", "cancelled"].contains(($0.scheduleRelationship ?? "").lowercased()) }
            .compactMap { d -> Arrival? in
                guard let time = d.departureTime else { return nil }
                let at = Date(timeIntervalSince1970: time)
                let live = d.actual ?? false
                return Arrival(expectedAt: at, scheduledAt: live ? nil : at, isRealtime: live, tripId: d.tripId)
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    // MARK: - Helpers

    private func allStops() async throws -> [TransitStop] {
        try await MetroTransitCaches.stops.value { try await GTFSStops.load(from: Self.gtfsZip) }
    }

    private nonisolated struct Ref {
        var route: String
        var direction: String

        /// Line ids are `{route_id}-{direction_id}`; `providerRefs` holds the same, unambiguously.
        init(_ line: TransitLine) {
            route = line.providerRefs["route"] ?? String(line.id.split(separator: "-").dropLast().joined(separator: "-"))
            direction = line.providerRefs["direction"] ?? String(line.id.split(separator: "-").last ?? "0")
        }
    }

    /// Timetables are published per day type; the service day runs to ~3 am, Twin Cities time.
    private nonisolated enum DayType: String {
        case weekday = "Weekday", saturday = "Saturday", sunday = "Sunday"

        static func today(in zone: TimeZone, now: Date = Date()) -> DayType {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let serviceDay = calendar.component(.hour, from: now) < 3 ? now.addingTimeInterval(-3 * 3600) : now
            switch calendar.component(.weekday, from: serviceDay) {
            case 1: return .sunday
            case 7: return .saturday
            default: return .weekday
            }
        }
    }
}

// MARK: - Stop index

/// Every line the timetable stops at each stop, keyed by public stop number, from the GTFS. Shipped
/// in the app rather than fetched: working it out takes the 19 MB `stop_times.txt`. A build without
/// the file (the live probe) has an empty index, and stops fall back to the departures alone.
nonisolated struct MetroTransitStopIndex: Sendable {
    static let shared = MetroTransitStopIndex(
        url: Bundle.main.url(forResource: "MetroTransitStopLines", withExtension: "json"))

    private struct File: Decodable {
        struct Line: Decodable {
            var route: String
            var direction: Int
            var directionText: String
            var shortName: String
            var headsign: String
            var agency: Int
        }
        var lines: [Line]
        var stops: [String: [Int]]
    }

    private let lines: [TransitLine]
    private let stops: [String: [Int]]

    init(url: URL?) {
        self.init(data: url.flatMap { try? Data(contentsOf: $0) } ?? Data())
    }

    init(data: Data) {
        let file = try? JSONDecoder().decode(File.self, from: data)
        // The same line the departures make, so a line chosen at night is the one the board polls.
        lines = (file?.lines ?? []).map { line in
            TransitLine(
                id: "\(line.route)-\(line.direction)",
                shortName: line.shortName,
                headsign: line.headsign,
                agency: MetroTransitProvider.agencies[line.agency],
                providerRefs: ["route": line.route, "direction": String(line.direction),
                               "directionText": line.directionText]
            )
        }
        stops = file?.stops ?? [:]
    }

    func lines(atStop code: String) -> [TransitLine] {
        (stops[code] ?? []).compactMap { $0 < lines.count ? lines[$0] : nil }
    }
}

// MARK: - Session caches

/// Loads a value once per session; a failed load is forgotten so the next caller retries.
private actor MetroTransitCache<Value: Sendable> {
    private var task: Task<Value, any Error>?

    func value(load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let task { return try await task.value }
        let task = Task { try await load() }
        self.task = task
        do { return try await task.value } catch { self.task = nil; throw error }
    }
}

private nonisolated enum MetroTransitCaches {
    static let stops = MetroTransitCache<[TransitStop]>()
    /// `route_id` → the Schedule API's `route_url_param` ("924" → "dline"), ~150 routes, ~15 KB.
    static let routeParams = MetroTransitCache<[String: String]>()
}

/// `stops.txt` out of the Metro Transit GTFS zip without downloading the archive: one range request
/// for the tail (end-of-central-directory + central directory, ~1 KB), one for the compressed entry
/// itself (~200 KB deflated, ~1 MB of CSV, ~8,000 stops). The zip is refreshed weekly, so the
/// offsets are read fresh each session.
private nonisolated enum GTFSStops {
    static func load(from url: URL) async throws -> [TransitStop] {
        let (tail, total) = try await fetch(url, range: "bytes=-8192")
        guard let eocd = lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: tail) else {
            throw TransitError.badResponse("GTFS zip has no end of central directory")
        }
        let entryCount = tail.u16(eocd + 10)
        let directorySize = tail.u32(eocd + 12)
        let directoryOffset = tail.u32(eocd + 16)
        let tailStart = total - tail.count
        let directory = directoryOffset >= tailStart
            ? tail.subdata(in: (directoryOffset - tailStart)..<(directoryOffset - tailStart + directorySize))
            : try await fetch(url, range: "bytes=\(directoryOffset)-\(directoryOffset + directorySize - 1)").data

        var p = 0
        for _ in 0..<entryCount {
            guard p + 46 <= directory.count, directory.u32(p) == 0x0201_4B50 else { break }
            let method = directory.u16(p + 10)
            let compressed = directory.u32(p + 20)
            let uncompressed = directory.u32(p + 24)
            let nameLength = directory.u16(p + 28)
            let extraLength = directory.u16(p + 30)
            let commentLength = directory.u16(p + 32)
            let localOffset = directory.u32(p + 42)
            let name = String(decoding: directory.subdata(in: (p + 46)..<(p + 46 + nameLength)), as: UTF8.self)
            p += 46 + nameLength + extraLength + commentLength
            guard name == "stops.txt" else { continue }

            // The local header's extra field may differ from the central one; allow slack, refetch if short.
            var slack = 30 + nameLength + extraLength + 512
            var chunk = try await fetch(url, range: "bytes=\(localOffset)-\(localOffset + slack + compressed - 1)").data
            var start = 30 + chunk.u16(26) + chunk.u16(28)
            if start + compressed > chunk.count {
                slack = start
                chunk = try await fetch(url, range: "bytes=\(localOffset)-\(localOffset + slack + compressed - 1)").data
                start = 30 + chunk.u16(26) + chunk.u16(28)
            }
            let body = chunk.subdata(in: start..<(start + compressed))
            let csv = method == 0 ? body : try inflate(body, size: uncompressed)
            return parse(String(decoding: csv, as: UTF8.self))
        }
        throw TransitError.notFound("stops.txt in GTFS zip")
    }

    /// The requested bytes, and the archive's total length from `Content-Range` ("bytes a-b/total").
    private static func fetch(_ url: URL, range: String) async throws -> (data: Data, total: Int) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue("BusBus-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            throw TransitError.badResponse("GTFS zip range request answered \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let total = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap({ Int($0) }) else {
            throw TransitError.badResponse("GTFS zip range response without a total length")
        }
        return (data, total)
    }

    /// Zip entries are raw DEFLATE, which is what Compression's `COMPRESSION_ZLIB` decodes.
    private static func inflate(_ data: Data, size: Int) throws -> Data {
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_decode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!, size,
                    input.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else { throw TransitError.badResponse("GTFS stops.txt inflated to \(written) of \(size) bytes") }
        return output
    }

    private static func lastIndex(of signature: [UInt8], in data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= signature.count else { return nil }
        for i in stride(from: bytes.count - signature.count, through: 0, by: -1) where bytes[i..<(i + signature.count)].elementsEqual(signature) {
            return i
        }
        return nil
    }

    /// Boarding points only (`location_type` 0 or empty); `stop_code` is the public number and
    /// equals `stop_id` in this feed.
    static func parse(_ csv: String) -> [TransitStop] {
        var lines = csv.split(whereSeparator: \.isNewline).makeIterator()
        guard let header = lines.next().map({ fields(String($0)) }) else { return [] }
        let column = { (name: String) in header.firstIndex { $0.trimmingCharacters(in: .init(charactersIn: "\u{FEFF}")) == name } }
        guard let idColumn = column("stop_id"), let nameColumn = column("stop_name"),
              let latColumn = column("stop_lat"), let lonColumn = column("stop_lon") else { return [] }
        let codeColumn = column("stop_code"), typeColumn = column("location_type")
        var stops: [TransitStop] = []
        while let line = lines.next() {
            let f = fields(String(line))
            func value(_ i: Int?) -> String? { i.flatMap { $0 < f.count ? f[$0] : nil } }
            guard ["", "0"].contains(value(typeColumn) ?? ""),
                  let id = value(idColumn), let lat = value(latColumn).flatMap(Double.init),
                  let lon = value(lonColumn).flatMap(Double.init) else { continue }
            let code = value(codeColumn).flatMap { $0.isEmpty ? nil : $0 } ?? id
            stops.append(TransitStop(code: code, name: value(nameColumn) ?? code, city: nil, location: GeoPoint(lat: lat, lon: lon)))
        }
        return stops
    }

    /// One CSV record, honouring quoted fields with doubled quotes.
    private static func fields(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        var chars = line.makeIterator()
        while let c = chars.next() {
            if quoted {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { current.append("\"") } else { quoted = false; if next == "," { result.append(current); current = "" } else { current.append(next) } }
                    } else { quoted = false }
                } else { current.append(c) }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                result.append(current); current = ""
            } else {
                current.append(c)
            }
        }
        result.append(current)
        return result
    }
}

/// Case- and accent-insensitive "every word appears in the name", exact and prefix matches first.
private nonisolated enum MetroTransitNameSearch {
    static func match(_ query: String, in stops: [TransitStop], limit: Int = 40) -> [TransitStop] {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let needle = fold(query)
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return stops
            .compactMap { stop -> (TransitStop, Int)? in
                let name = fold(stop.name)
                guard words.allSatisfy(name.contains) else { return nil }
                return (stop, name == needle ? 0 : name.hasPrefix(needle) ? 1 : 2)
            }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.name < $1.0.name }
            .prefix(limit)
            .map(\.0)
    }
}

private nonisolated extension Data {
    func u16(_ offset: Int) -> Int {
        Int(self[startIndex + offset]) | Int(self[startIndex + offset + 1]) << 8
    }

    func u32(_ offset: Int) -> Int {
        u16(offset) | u16(offset + 2) << 16
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct NexTripResult: Decodable, Sendable {
        var stops: [Stop]?
        var departures: [Departure]?
    }

    struct Stop: Decodable, Sendable {
        var stopId: Int
        var latitude: Double
        var longitude: Double
        var description: String?

        enum CodingKeys: String, CodingKey { case latitude, longitude, description, stopId = "stop_id" }

        var stop: TransitStop {
            TransitStop(code: String(stopId), name: description ?? String(stopId), city: nil,
                        location: GeoPoint(lat: latitude, lon: longitude))
        }
    }

    struct Departure: Decodable, Sendable {
        var actual: Bool?
        var tripId: String?
        var departureTime: Double?        // epoch seconds
        var description: String?          // headsign
        var routeId: String?
        var routeShortName: String?
        var directionId: Int?
        var directionText: String?        // "NB", "SB", "EB", "WB"
        var agencyId: Int?
        var scheduleRelationship: String? // "Scheduled", "Skipped", …

        enum CodingKeys: String, CodingKey {
            case actual, description
            case tripId = "trip_id", departureTime = "departure_time", routeId = "route_id"
            case routeShortName = "route_short_name", directionId = "direction_id"
            case directionText = "direction_text", agencyId = "agency_id"
            case scheduleRelationship = "schedule_relationship"
        }

        var line: TransitLine {
            let route = routeId ?? ""
            let direction = String(directionId ?? 0)
            var refs = ["route": route, "direction": direction]
            refs["directionText"] = directionText
            return TransitLine(
                id: "\(route)-\(direction)",
                shortName: routeShortName ?? route,
                headsign: description,
                agency: agencyId.flatMap { MetroTransitProvider.agencies[$0] },
                providerRefs: refs
            )
        }
    }

    struct Vehicle: Decodable, Sendable {
        var tripId: String?
        var directionId: Int?
        var locationTime: Double?         // epoch seconds; 0 when not on a trip
        var latitude: Double?
        var longitude: Double?
        var bearing: Double?

        enum CodingKeys: String, CodingKey {
            case latitude, longitude, bearing
            case tripId = "trip_id", directionId = "direction_id", locationTime = "location_time"
        }
    }

    struct ScheduleRoute: Decodable, Sendable {
        var routeId: String?
        var routeUrlParam: String?
        enum CodingKeys: String, CodingKey { case routeId = "route_id", routeUrlParam = "route_url_param" }
    }

    struct RouteDetails: Decodable, Sendable {
        struct Schedule: Decodable, Sendable {
            var scheduleTypeName: String?
            var timetables: [Timetable]?
            enum CodingKeys: String, CodingKey { case timetables, scheduleTypeName = "schedule_type_name" }
        }
        struct Timetable: Decodable, Sendable {
            var scheduleNumber: Int
            var directionId: Int
            enum CodingKeys: String, CodingKey { case scheduleNumber = "schedule_number", directionId = "direction_id" }
        }

        var schedules: [Schedule]?

        /// Today's day type if the route runs it, else any timetable in that direction (weekday first).
        func scheduleNumber(direction: String, dayType: String) -> Int? {
            let matching = (schedules ?? []).compactMap { schedule -> (String, Int)? in
                guard let table = schedule.timetables?.first(where: { String($0.directionId) == direction }) else { return nil }
                return (schedule.scheduleTypeName ?? "", table.scheduleNumber)
            }
            return (matching.first { $0.0.localizedCaseInsensitiveContains(dayType) } ?? matching.first)?.1
        }
    }

    struct StopListItem: Decodable, Sendable {
        var stopId: Int
        enum CodingKeys: String, CodingKey { case stopId = "stop_id" }
    }
}
