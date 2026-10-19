import Foundation

/// Hong Kong — MTR Bus, the ~25 New Territories feeder routes (K12, K51, 506, K76…), via DATA.GOV.HK.
/// Keyless, no published rate limit; the operator's own app polls every 60 s (`appRefreshTimeInSecond`).
///
/// There is no stop or route API: the network comes from two static CSVs on opendata.mtr.com.hk
/// (stops ~70 KB, routes ~4 KB), fetched once per session. The only live call is `getSchedule`, a POST
/// per route *number* that answers every variant and direction at once, with each bus's GPS fix and its
/// countdown to every stop ahead. See docs/research/worldwide-apis.md §8.1.
///
/// Stop ids (`K12-U020`) belong to one route direction, so a kerbside stop shared by four routes has
/// four ids. Search and nearby fold rows with the same English name within 60 m into one stop, coded by
/// its first id; `lines(atStop:)` unfolds it again.
///
/// Names follow the app language (`HKNameLanguage`): `STATION_NAME_ENG`, or `STATION_NAME_CHI`
/// (Traditional — the feed has no Simplified names, so Simplified Chinese reads it too). Search matches
/// either. The stop folding above always goes by the English name, so stop codes never change with it.
nonisolated struct MTRBusProvider: TransitProvider {
    let id = "hk-mtrbus"
    /// Lines and patterns are cached with their names baked in, so each name language is its own dataset.
    var datasetID: String { "\(id).\(HKNameLanguage.current.rawValue)" }
    let displayName = "MTR Bus (Hong Kong)"
    let attribution: String? = "Data: DATA.GOV.HK / MTR Corporation; route lines: Transport Department / CSDI Portal"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .scheduledArrivals, .nearbyStops, .routeShape,
    ]
    /// The feed itself says 60 s; the board clamps to 30 s, which is still gentle for ~20 routes.
    let suggestedRefreshInterval: Duration = .seconds(60)

    /// For the route lines only; everything else is the static CSVs and the schedule POST.
    var http = HTTPClient()

    /// The only MTR Bus routes TD has drawn: the Tai Po feeders, filed there as KMB.
    private static let drawnRoutes: Set<String> = ["K12", "K14", "K17", "K18"]

    private static let stopsURL = URL(string: "https://opendata.mtr.com.hk/data/mtr_bus_stops.csv")!
    private static let routesURL = URL(string: "https://opendata.mtr.com.hk/data/mtr_bus_routes.csv")!
    private static let scheduleURL = URL(string: "https://rt.data.gov.hk/v1/transport/mtr/bus/getSchedule")!

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        let network = try await Self.network()
        let language = HKNameLanguage.current
        return network.physicalStops
            .filter { $0.name.lowercased().contains(query) || $0.nameChinese.contains(query) || $0.stationID.lowercased() == query }
            .map { $0.stop(in: language) }
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let network = try await Self.network()
        let language = HKNameLanguage.current
        return network.members(of: stop.code)
            // A bus that ends here is no use to someone waiting here; a loop's last stop is its first.
            .filter { row in
                guard let pattern = network.patterns[row.lineKey], let last = pattern.last else { return false }
                return last.stationID != row.stationID || network.variants[row.referenceID]?.isCircular == true
            }
            .compactMap { network.line(row: $0, language: language) }
            .uniqued(by: \.id)
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let network = try await Self.network()
        guard let rows = network.patterns[line.id], rows.count >= 2 else {
            throw TransitError.notFound("stops for MTR Bus line \(line.id)")
        }
        let language = HKNameLanguage.current
        return RoutePattern(line: line, stops: rows.map {
            PatternStop(stop: $0.stop(in: language), sequence: $0.sequence, distanceAlongRoute: nil)
        })
    }

    /// A shape has no names in it.
    var shapeDatasetID: String { id }

    /// TD's drawn line (`HKRouteLines`) for the four routes it has; the others have no official
    /// line anywhere yet, so nothing is asked and their card shows the stops alone.
    /// Only the routes the Transport Department has drawn.
    func hasRouteShape(for line: TransitLine) -> Bool {
        Self.drawnRoutes.contains(line.providerRefs["routeName"] ?? line.shortName)
    }

    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        let routeName: String? = if let name = line.providerRefs["routeName"] {
            name
        } else {
            try await Self.network().variants[String(line.id.prefix { $0 != ":" })]?.routeName
        }
        guard let routeName else { throw TransitError.notFound("MTR Bus route of line \(line.id)") }
        guard Self.drawnRoutes.contains(routeName) else {
            throw TransitError.unsupported("route line of MTR Bus \(routeName)")
        }
        return try await HKRouteLines.shape(route: routeName, company: nil, pattern: pattern, http: http)
    }

    /// Every bus with a GPS fix that is running this variant+direction. A bus shows up at every stop
    /// ahead of it, so it is deduplicated by `busId`. Scheduled-only entries carry 0,0 and are dropped.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        guard let lineRef = line.providerRefs["lineRef"], let routeName = line.providerRefs["routeName"] else {
            throw TransitError.unsupported("line \(line.id) has no lineRef (was it loaded from another provider?)")
        }
        let schedule = try await Self.schedule(routeName: routeName)
        var seen = Set<String>()
        var result: [VehiclePosition] = []
        for stop in schedule.busStop ?? [] {
            for bus in stop.bus ?? [] where bus.lineRef == lineRef {
                guard let location = bus.busLocation?.point, seen.insert(bus.busId ?? UUID().uuidString).inserted else { continue }
                result.append(VehiclePosition(location: location, tripId: bus.busId))
            }
        }
        return result
    }

    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        guard let lineRef = line.providerRefs["lineRef"], let routeName = line.providerRefs["routeName"] else {
            throw TransitError.unsupported("line \(line.id) has no lineRef (was it loaded from another provider?)")
        }
        let network = try await Self.network()
        // A loop's first and last stops have their own ids (K18-U010, K18-D030) but fold into one kerbside
        // stop; the buses due at the last one end there, so only the first visit counts.
        guard let station = network.members(of: stop.code).filter({ $0.lineKey == line.id })
            .min(by: { $0.sequence < $1.sequence })?.stationID else { return [] }

        let schedule = try await Self.schedule(routeName: routeName)
        let now = Date()
        return (schedule.busStop ?? [])
            .filter { $0.busStopId == station }
            .flatMap { $0.bus ?? [] }
            .filter { $0.lineRef == lineRef }
            .compactMap { bus -> Arrival? in
                guard let seconds = bus.secondsToStop, seconds >= 0 else { return nil }
                let live = bus.isScheduled == "0"
                return Arrival(
                    expectedAt: now.addingTimeInterval(seconds),
                    scheduledAt: nil,
                    isRealtime: live,
                    tripId: live ? bus.busId : nil,
                    vehicleLocation: live ? bus.busLocation?.point : nil
                )
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let network = try await Self.network()
        let language = HKNameLanguage.current
        return try await withThrowingTaskGroup(of: NearbyStop?.self) { group in
            for row in network.physicalStops {
                let stop = row.stop(in: language)
                let distance = RouteGeometry.meters(point, stop.location)
                guard distance <= radiusMeters else { continue }
                group.addTask { NearbyStop(stop: stop, distanceMeters: distance, lines: try await lines(atStop: stop)) }
            }
            var result: [NearbyStop] = []
            for try await entry in group { if let entry { result.append(entry) } }
            return result.sorted { $0.distanceMeters < $1.distanceMeters }
        }
    }

    // MARK: - Loading

    private static let store = MTRBusStore()

    private static func network() async throws -> MTRBusNetwork {
        try await store.network.value("network", ttl: nil) {
            async let stops = fetch(stopsURL)
            async let routes = fetch(routesURL)
            return try MTRBusNetwork(stopsCSV: await stops, routesCSV: await routes)
        }
    }

    /// One schedule per route number serves every line and stop on it, so concurrent board requests
    /// (vehicles + arrivals) share a single POST for a few seconds.
    private static func schedule(routeName: String) async throws -> DTO.Schedule {
        try await store.schedules.value(routeName, ttl: .seconds(10)) {
            var request = URLRequest(url: scheduleURL, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("BusBus-iOS/1.0", forHTTPHeaderField: "User-Agent")
            request.httpBody = try JSONEncoder().encode(["language": "en", "routeName": routeName])
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else { throw TransitError.badResponse("HTTP \(status) for getSchedule \(routeName)") }
            do {
                return try JSONDecoder().decode(DTO.Schedule.self, from: data)
            } catch {
                throw TransitError.badResponse("decoding getSchedule: \(error)")
            }
        }
    }

    private static func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("BusBus-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status), let text = String(data: data, encoding: .utf8) else {
            throw TransitError.badResponse("HTTP \(status) for \(url.lastPathComponent)")
        }
        return text
    }
}

// MARK: - Network (static CSVs)

private nonisolated struct MTRBusNetwork: Sendable {
    /// One row of `mtr_bus_stops.csv`: a stop of one variant (`REFERENCE_ID`, e.g. "K51-1") in one direction.
    struct Row: Sendable {
        var routeName: String      // "K51"
        var referenceID: String    // "K51-1"
        var direction: String      // "O" (outbound, LINE_UP) or "I" (inbound, LINE_DOWN)
        var sequence: Int
        var stationID: String      // "K51-nU020"
        var location: GeoPoint
        var name: String
        var nameChinese: String

        /// `TransitLine.id`: variant + direction.
        var lineKey: String { "\(referenceID):\(direction)" }
        func displayName(in language: HKNameLanguage) -> String {
            language.pick(en: name, tc: nameChinese) ?? stationID
        }
        func stop(in language: HKNameLanguage) -> TransitStop {
            TransitStop(code: stationID, name: displayName(in: language), city: nil, location: location)
        }
    }

    /// One row of `mtr_bus_routes.csv`.
    struct Variant: Sendable {
        var routeName: String
        var lineUp: String?        // live `lineRef` of direction O
        var lineDown: String?      // live `lineRef` of direction I
        var isCircular: Bool
    }

    var rowsByStation: [String: Row] = [:]
    var patterns: [String: [Row]] = [:]
    var variants: [String: Variant] = [:]
    /// One row per kerbside stop, the one whose id codes it.
    var physicalStops: [Row] = []
    private var rowsByName: [String: [Row]] = [:]

    init(stopsCSV: String, routesCSV: String) throws {
        for record in CSV.records(routesCSV) {
            guard let reference = record["REFERENCE_ID"], let route = record["ROUTE_ID"] else { continue }
            variants[reference] = Variant(
                routeName: route,
                lineUp: record["LINE_UP"].flatMap { $0.isEmpty ? nil : $0 },
                lineDown: record["LINE_DOWN"].flatMap { $0.isEmpty ? nil : $0 },
                isCircular: record["IS_CIRCULAR"] == "1"
            )
        }
        var rows: [Row] = []
        for record in CSV.records(stopsCSV) {
            guard let route = record["ROUTE_ID"], let reference = record["REFERENCE_ID"],
                  let direction = record["DIRECTION"], let station = record["STATION_ID"],
                  let sequence = record["STATION_SEQNO"].flatMap({ Int($0) }),
                  let lat = record["STATION_LATITUDE"].flatMap({ Double($0) }),
                  let lon = record["STATION_LONGITUDE"].flatMap({ Double($0) }) else { continue }
            rows.append(Row(
                routeName: route, referenceID: reference, direction: direction, sequence: sequence,
                stationID: station, location: GeoPoint(lat: lat, lon: lon),
                name: record["STATION_NAME_ENG"]?.trimmingCharacters(in: .whitespaces) ?? station,
                nameChinese: record["STATION_NAME_CHI"]?.trimmingCharacters(in: .whitespaces) ?? ""
            ))
        }
        guard !rows.isEmpty else { throw TransitError.badResponse("mtr_bus_stops.csv has no rows") }

        for row in rows {
            rowsByStation[row.stationID] = rowsByStation[row.stationID] ?? row
            patterns[row.lineKey, default: []].append(row)
            rowsByName[row.name, default: []].append(row)
        }
        for key in patterns.keys { patterns[key]?.sort { $0.sequence < $1.sequence } }

        // Fold the per-route ids into kerbside stops, first id (in file order) standing for the group.
        var claimed = Set<String>()
        for row in rows where !claimed.contains(row.stationID) {
            for member in members(of: row) { claimed.insert(member.stationID) }
            physicalStops.append(row)
        }
    }

    /// Every route row at the same kerbside stop as `code`.
    func members(of code: String) -> [Row] {
        guard let row = rowsByStation[code] else { return [] }
        return members(of: row)
    }

    private func members(of row: Row) -> [Row] {
        (rowsByName[row.name] ?? []).filter {
            RouteGeometry.meters($0.location, row.location) <= 60   // same name, same kerb
        }
    }

    func line(row: Row, language: HKNameLanguage) -> TransitLine? {
        guard let variant = variants[row.referenceID],
              let lineRef = row.direction == "I" ? variant.lineDown : variant.lineUp,
              let pattern = patterns[row.lineKey], let first = pattern.first, let last = pattern.last else { return nil }
        let destination = last.displayName(in: language)
        let circular = language == .en ? "\(destination) (circular)" : "\(destination)（循環線）"
        return TransitLine(
            id: row.lineKey,
            shortName: variant.routeName,
            headsign: variant.isCircular ? circular : destination,
            agency: "MTR Bus",
            origin: first.displayName(in: language),
            destination: destination,
            providerRefs: ["routeName": variant.routeName, "lineRef": lineRef]
        )
    }
}

/// Just enough RFC 4180 for the MTR files: quoted fields (names with commas), CRLF, a UTF-8 BOM.
/// Works on unicode scalars because Swift treats "\r\n" as one Character.
private nonisolated enum CSV {
    static func records(_ text: String) -> [[String: String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var quoted = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        func endField() { row.append(String(field)); field = .init() }
        func endRow() { endField(); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }; row = [] }

        while let scalar = pending ?? iterator.next() {
            pending = nil
            switch scalar {
            case "\u{FEFF}" where rows.isEmpty && row.isEmpty && field.isEmpty:
                continue
            case "\"" where quoted:
                let next = iterator.next()
                if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
            case "\"" where field.isEmpty:
                quoted = true
            case "," where !quoted:
                endField()
            case "\r" where !quoted:
                continue
            case "\n" where !quoted:
                endRow()
            default:
                field.append(scalar)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }

        guard let header = rows.first else { return [] }
        return rows.dropFirst().map { values in
            Dictionary(zip(header, values), uniquingKeysWith: { first, _ in first })
        }
    }
}

// MARK: - Session cache

private actor MTRBusStore {
    let network = Memo<MTRBusNetwork>()
    let schedules = Memo<DTO.Schedule>()
}

/// Coalesces concurrent loads of the same key and keeps the result for `ttl` (forever when nil).
/// Failures are not kept.
private actor Memo<Value: Sendable> {
    private var entries: [String: (at: ContinuousClock.Instant, task: Task<Value, any Error>)] = [:]

    func value(_ key: String, ttl: Duration?, _ load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let now = ContinuousClock.now
        if let entry = entries[key], ttl.map({ now - entry.at < $0 }) ?? true {
            return try await entry.task.value
        }
        if let ttl { entries = entries.filter { now - $0.value.at < ttl } }
        let task = Task { try await load() }
        entries[key] = (now, task)
        do {
            return try await task.value
        } catch {
            if entries[key]?.task == task { entries[key] = nil }
            throw error
        }
    }
}

private nonisolated extension Array {
    func uniqued(by key: (Element) -> String) -> [Element] {
        var seen = Set<String>()
        return filter { seen.insert(key($0)).inserted }
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct Schedule: Decodable, Sendable {
        var routeName: String?
        /// "YYYY/MM/DD HH:mm", Hong Kong time, minute precision — the countdowns below are relative to
        /// the response, so the adapter anchors them on the time it received it instead.
        var routeStatusTime: String?
        var busStop: [BusStop]?
    }

    struct BusStop: Decodable, Sendable {
        var busStopId: String?
        var bus: [Bus]?
    }

    struct Bus: Decodable, Sendable {
        var busId: String?
        /// Variant+direction, matching `LINE_UP` / `LINE_DOWN` of the routes CSV ("K12_EG").
        var lineRef: String?
        /// Seconds from now, as strings. At a first stop the arrival is a 108000 placeholder and the
        /// departure is the real figure; negative means the bus has already left.
        var arrivalTimeInSecond: String?
        var departureTimeInSecond: String?
        /// "0" = tracked bus with a GPS fix, "1" = timetable slot.
        var isScheduled: String?
        var isDelayed: String?
        var busLocation: Location?

        var secondsToStop: TimeInterval? {
            let arrival = arrivalTimeInSecond.flatMap(Double.init)
            let departure = departureTimeInSecond.flatMap(Double.init)
            if let arrival, arrival < 100_000 { return arrival }
            return departure
        }
    }

    struct Location: Decodable, Sendable {
        var latitude: Double?
        var longitude: Double?

        /// 0,0 stands for "no fix".
        var point: GeoPoint? {
            guard let latitude, let longitude, latitude != 0 || longitude != 0 else { return nil }
            return GeoPoint(lat: latitude, lon: longitude)
        }
    }
}
