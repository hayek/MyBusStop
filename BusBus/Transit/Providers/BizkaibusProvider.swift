import Foundation

/// Spain, Biscay (Bilbao and the rest of Bizkaia) — Bizkaibus, the Diputación Foral de Bizkaia's
/// interurban buses. Two keyless sources:
/// - The Bizkaibus web service behind the operator's own site and app
///   (`apli.bizkaia.net/APPS/DANOK/TQWS/TQ.ASMX`, ASP.NET `.asmx` answering plain GETs). No published
///   terms or limits. Operations used:
///   - `GetParadasAlfanumericas` — every stop (~2,400, 450 KB of XML, ~87 KB gzipped): name, 4-digit
///     code, and ETRS89 UTM 30N coordinates. The name search and nearby source, once per session.
///   - `GetMunicipiosBizkaibus_JSON` — municipality names, for the stops' city (~15 KB).
///   - `gfReturn_LineasNew` — the lines calling at a stop, by province/municipality/stop number.
///   - `gfReturn_Buscar_ItinerariosLinea_Basico` — the ordered stops of one line's route and
///     direction (`I` ida / `V` vuelta), ~13 KB (~2.3 KB gzipped). Every line's main route is `001`.
///   - `GetPasoParadaMobile_JSON` — the next two buses of each line at a stop, in minutes and metres.
///   - `GetRutaParadas_JSON` — the drawn line of one route and direction, for the line's map.
///   The XML operations answer `<string>status®payload</string>`: status 1 is success, anything else
///   is a message ("90®Servicio temporalmente no disponible").
/// - The official GTFS-RT vehicle feed (`baliabideak.bizkaia.eus/Bizkaibus/GTFSRealTime`, ~28 KB for
///   the whole fleet), CC BY 4.0 via data.ctb.eus. Its `stop_id` is the stop code without leading
///   zeros; its trips carry the line code but no direction.
/// See docs/research/worldwide-apis.md §6.5.
///
/// Stop names are the operator's, in Basque, Spanish or both ("Udaletxea/Ayuntamiento").
nonisolated struct BizkaibusProvider: TransitProvider {
    let id = "bizkaibus"
    let displayName = "Bizkaibus"
    let attribution: String? = "Datos: Bizkaibus, Diputación Foral de Bizkaia (data.ctb.eus, CC BY 4.0)"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .nearbyStops, .routeShape,
    ]
    /// No stated limit; the vehicle feed is the whole fleet (~28 KB) and ETAs are whole minutes.
    let suggestedRefreshInterval: Duration = .seconds(30)

    static let timeZone = TimeZone(identifier: "Europe/Madrid")!

    private var cache: BizkaibusCache { .shared }

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let stops = try await cache.stops()
        // The 4-digit code on the pole, with or without its leading zeros, or the 8-digit label.
        if query.allSatisfy(\.isNumber) {
            let padded = query.count < 4 ? String(repeating: "0", count: 4 - query.count) + query : query
            if let exact = stops.byCode[padded] ?? stops.all.first(where: { $0.label == query }) { return [exact.stop] }
        }
        let needle = BizkaibusText.fold(query)
        let words = needle.split(separator: " ").map(String.init)
        return stops.all
            .filter { entry in words.allSatisfy(entry.folded.contains) }
            .sorted { a, b in
                let ar = a.folded == needle ? 0 : a.folded.hasPrefix(needle) ? 1 : 2
                let br = b.folded == needle ? 0 : b.folded.hasPrefix(needle) ? 1 : 2
                return ar != br ? ar < br : (a.stop.name, a.stop.code) < (b.stop.name, b.stop.code)
            }
            .prefix(60)
            .map(\.stop)
    }

    /// Both directions of every line the stop's record lists, kept where the direction's stop list
    /// calls here. A direction that only ends here is dropped unless nothing else serves the stop.
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        guard let entry = try await cache.stops().byCode[stop.code] else { throw TransitError.notFound("stop \(stop.code)") }
        let served = try await cache.lines(at: entry)
        let directions = try await withThrowingTaskGroup(of: [(Int, BizkaibusDirection)].self) { group in
            for (index, line) in served.enumerated() {
                group.addTask {
                    try await ["I", "V"].enumerated().asyncCompactMap { order, direction in
                        let found = try await cache.direction(line: line.code, direction: direction, name: line.name)
                        return found.map { (index * 2 + order, $0) }
                    }
                }
            }
            return try await group.reduce(into: []) { $0 += $1 }.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let calling = directions.filter { $0.codes.contains(stop.code) }
        let boarding = calling.filter { $0.codes.last != stop.code }
        return (boarding.isEmpty ? calling : boarding).map(\.line)
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let ref = Ref(line)
        guard let direction = try await cache.direction(line: ref.line, direction: ref.direction, name: nil) else {
            throw TransitError.notFound("stops of line \(ref.line) direction \(ref.direction)")
        }
        return RoutePattern(line: line, stops: direction.stops.enumerated().map { PatternStop(stop: $1, sequence: $0 + 1) })
    }

    /// One call: the route's line from the operator's map service. Some directions are stored end
    /// to start (A3224 `I`, not its `V`), so each is turned to run the itinerary's way. The same reply
    /// lists the route's stops, but not in travel order, so the itinerary stays the pattern.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        let ref = Ref(line)
        let (data, response, request) = try await BizkaibusAPI.get("GetRutaParadas_JSON", [
            "callback": "", "sCodigoLinea": ref.line, "sNumeroRuta": "001", "sSentido": ref.direction,
        ])
        do {
            return try Self.routeShape(String(decoding: data, as: UTF8.self), stops: pattern.stops.map(\.stop.location))
        } catch {
            throw ResponseError("GetRutaParadas_JSON: \(ResponseError.describe(error))", data, response, request)
        }
    }

    static func routeShape(_ reply: String, stops: [GeoPoint]) throws -> RouteShape {
        RouteShape(branches: ShapeCheck.chained(try routePaths(reply)).map { ShapeCheck.oriented($0, stops: stops) })
    }

    /// The Esri `paths` (`[lon, lat]`) of a `GetRutaParadas_JSON` reply. The reply mixes single- and
    /// double-quoted strings, which no JSON parser takes, so the array is cut out on its own.
    static func routePaths(_ text: String) throws -> [[GeoPoint]] {
        if text.contains("'STATUS': 'ERROR'") { throw TransitError.badResponse("STATUS ERROR") }
        let bytes = Array(text.utf8)
        guard let key = bytes.firstRange(of: Array(#""paths":"#.utf8)),
              let open = bytes[key.upperBound...].firstIndex(of: UInt8(ascii: "[")) else {
            throw TransitError.badResponse("no paths")
        }
        var depth = 0
        var close: Int?
        for index in open..<bytes.count {
            if bytes[index] == UInt8(ascii: "[") { depth += 1 }
            if bytes[index] == UInt8(ascii: "]") { depth -= 1 }
            if depth == 0 { close = index; break }
        }
        guard let close else { throw TransitError.badResponse("unterminated paths") }
        let pieces = try JSONDecoder().decode([[[Double]]].self, from: Data(bytes[open...close]))
        return pieces.map { $0.compactMap { $0.count >= 2 ? GeoPoint(lat: $0[1], lon: $0[0]) : nil } }.filter { $0.count >= 2 }
    }

    /// The fleet feed names the line of each trip but not its direction. A bus belongs to this
    /// direction when the stop it is at or heading to is on this direction's list and not the
    /// other's; at a stop both share (a terminus), its stop sequence says which list it is on.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let ref = Ref(line)
        async let feed = cache.vehicles()
        async let other = cache.direction(line: ref.line, direction: ref.direction == "I" ? "V" : "I", name: nil)
        guard let own = try await cache.direction(line: ref.line, direction: ref.direction, name: nil) else { return [] }
        let otherCodes = try await other?.codes ?? []
        return try await feed.compactMap { vehicle -> VehiclePosition? in
            guard vehicle.line == ref.line, let stopCode = vehicle.stopCode,
                  let index = own.codes.firstIndex(of: stopCode) else { return nil }
            if let otherIndex = otherCodes.firstIndex(of: stopCode) {
                guard let sequence = vehicle.stopSequence, sequence == index + 1, sequence != otherIndex + 1 else { return nil }
            }
            return VehiclePosition(location: vehicle.location, recordedAt: vehicle.timestamp, tripId: vehicle.tripID)
        }
    }

    /// Minutes to the next two buses of each line, counted from now. The service puts these on the
    /// operator's displays and app as live times; there is no timetable time beside them.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let ref = Ref(line)
        let now = Date()
        return try await BizkaibusAPI.passages(stopCode: stop.code)
            .filter { $0.line == ref.line }
            .flatMap(\.minutes)
            .map { Arrival(expectedAt: now.addingTimeInterval(Double($0) * 60), isRealtime: true) }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// From the cached stop list, so the rider's position never leaves the phone; the lines of the
    /// nearest few are then asked for. Stops no line calls at are left out.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let nearest = try await cache.stops().all
            .map { (stop: $0.stop, distance: RouteGeometry.meters(point, $0.stop.location)) }
            .filter { $0.distance <= radiusMeters }
            .sorted { $0.distance < $1.distance }
            .prefix(10)
        var found: [NearbyStop] = []
        // Four at a time: the service is slow (1–3 s a call) and resets connections when rushed.
        for batch in Array(nearest).chunked(4) {
            let lines = try await withThrowingTaskGroup(of: (String, [TransitLine]).self) { group in
                for near in batch { group.addTask { (near.stop.code, try await lines(atStop: near.stop)) } }
                return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
            }
            for near in batch {
                guard let served = lines[near.stop.code], !served.isEmpty else { continue }
                found.append(NearbyStop(stop: near.stop, distanceMeters: near.distance, lines: served))
            }
        }
        return found
    }

    /// Line code and direction (`I`/`V`). Line ids are "<line>|<direction>", the fallback for a
    /// line cached without `providerRefs`.
    private nonisolated struct Ref {
        var line: String
        var direction: String

        init(_ line: TransitLine) {
            let parts = line.id.split(separator: "|").map(String.init)
            self.line = line.providerRefs["line"] ?? parts.first ?? line.shortName
            direction = line.providerRefs["direction"] ?? (parts.count > 1 ? parts[1] : "I")
        }
    }
}

// MARK: - Session cache

/// One stop of the network, with what the lines-at-stop operation needs to find it.
private nonisolated struct BizkaibusStopEntry: Sendable {
    var stop: TransitStop
    var folded: String
    /// "48020192": province, municipality, stop number.
    var label: String
    var province: String
    var municipality: String
    var number: String
}

private nonisolated struct BizkaibusStopList: Sendable {
    var all: [BizkaibusStopEntry]
    var byCode: [String: BizkaibusStopEntry]
}

/// One direction of a line's main route, in travel order.
private nonisolated struct BizkaibusDirection: Sendable {
    var line: TransitLine
    /// The stops the stop list has coordinates for.
    var stops: [TransitStop]
    /// Every stop code of the route, so that an index here is the feed's stop sequence less one.
    var codes: [String]
}

private nonisolated struct BizkaibusVehicle: Sendable {
    var tripID: String
    /// "A3224", from the trip id "trp_A3224_862_…".
    var line: String
    var location: GeoPoint
    var stopCode: String?
    var stopSequence: Int?
    var timestamp: Date?
}

private actor BizkaibusCache {
    static let shared = BizkaibusCache()

    private var stopsTask: Task<BizkaibusStopList, any Error>?
    private var lineTasks: [String: Task<[(code: String, name: String)], any Error>] = [:]
    private var directionTasks: [String: Task<BizkaibusDirection?, any Error>] = [:]
    private var feed: (fetched: ContinuousClock.Instant, task: Task<[BizkaibusVehicle], any Error>)?

    /// Every stop, once per session. A failed load is retried.
    func stops() async throws -> BizkaibusStopList {
        if let stopsTask { return try await stopsTask.value }
        let task = Task { try await BizkaibusAPI.stops() }
        stopsTask = task
        do { return try await task.value } catch { stopsTask = nil; throw error }
    }

    /// The lines whose record lists the stop.
    func lines(at entry: BizkaibusStopEntry) async throws -> [(code: String, name: String)] {
        if let task = lineTasks[entry.stop.code] { return try await task.value }
        let task = Task { try await BizkaibusAPI.lines(province: entry.province, municipality: entry.municipality, stop: entry.number) }
        lineTasks[entry.stop.code] = task
        do { return try await task.value } catch { lineTasks[entry.stop.code] = nil; throw error }
    }

    /// One direction of a line's main route; nil when the line has no such direction.
    func direction(line: String, direction: String, name: String?) async throws -> BizkaibusDirection? {
        let key = "\(line)|\(direction)"
        if let task = directionTasks[key] { return try await task.value }
        let task = Task { () async throws -> BizkaibusDirection? in
            let rows = try await BizkaibusAPI.itinerary(line: line, direction: direction)
            let stops = try await self.stops()
            let pattern = rows.compactMap { row -> TransitStop? in
                guard var stop = stops.byCode[row.code]?.stop else { return nil }
                if let city = row.city { stop.city = city }
                return stop
            }
            guard pattern.count >= 2, let first = pattern.first, let last = pattern.last else { return nil }
            let transitLine = TransitLine(
                id: key,
                shortName: line,
                headsign: last.name,
                agency: "Bizkaibus",
                origin: first.name,
                destination: last.name,
                providerRefs: ["line": line, "direction": direction]
            )
            return BizkaibusDirection(line: transitLine, stops: pattern, codes: rows.map(\.code))
        }
        directionTasks[key] = task
        do { return try await task.value } catch { directionTasks[key] = nil; throw error }
    }

    /// The fleet feed, shared for 15 s so that every line on a board costs one download.
    func vehicles() async throws -> [BizkaibusVehicle] {
        if let feed, ContinuousClock.now - feed.fetched < .seconds(15) { return try await feed.task.value }
        let task = Task { try await BizkaibusAPI.vehicles() }
        feed = (ContinuousClock.now, task)
        do { return try await task.value } catch { feed = nil; throw error }
    }
}

// MARK: - Network

private nonisolated enum BizkaibusAPI {
    static let base = "https://apli.bizkaia.net/APPS/DANOK/TQWS/TQ.ASMX/"
    static let feedURL = "https://baliabideak.bizkaia.eus/Bizkaibus/GTFSRealTime/FeedVehiculos.pb"

    static func stops() async throws -> BizkaibusStopList {
        async let names = municipalities()
        let rows = try await records("GetParadasAlfanumericas", [:], timeout: 60)
        let cities = (try? await names) ?? [:]
        var all: [BizkaibusStopEntry] = []
        for row in rows {
            guard let code = row["CODIGOREDUCIDOPARADA"], !code.isEmpty,
                  let province = row["PROVINCIA"], let municipality = row["MUNICIPIO"], let number = row["PARADA"],
                  let x = row["COORDX"].flatMap(Double.init), let y = row["COORDY"].flatMap(Double.init),
                  x > 0, y > 0 else { continue }
            let name = BizkaibusText.clean(row["DENOMINACION"]) ?? code
            let stop = TransitStop(code: code, name: name, city: cities["\(province)|\(municipality)"],
                                   location: UTM.etrs89Zone30(easting: x, northing: y))
            all.append(BizkaibusStopEntry(stop: stop, folded: BizkaibusText.fold(name),
                                          label: row["ETIQUETA_PARADA"] ?? province + municipality + number,
                                          province: province, municipality: municipality, number: number))
        }
        guard !all.isEmpty else { throw TransitError.badResponse("Bizkaibus stop list is empty") }
        return BizkaibusStopList(all: all, byCode: Dictionary(all.map { ($0.stop.code, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    /// "48|020" → "Bilbao". Names come in capitals ("ABANTO Y CIERVANA-ABANTO ZIERBENA").
    static func municipalities() async throws -> [String: String] {
        struct Reply: Decodable {
            struct Consulta: Decodable { var Registro: [Municipality] }
            struct Municipality: Decodable { var CodigoProvincia: String; var CodigoMunicipio: String; var DescripcionMunicipio: String }
            var Consulta: Consulta?
        }
        let (data, response, request) = try await get("GetMunicipiosBizkaibus_JSON", ["callback": ""])
        let reply = try HTTPClient.decode(Reply.self, jsonp(data), response, request, "GetMunicipiosBizkaibus_JSON")
        return Dictionary((reply.Consulta?.Registro ?? []).map {
            ("\($0.CodigoProvincia)|\($0.CodigoMunicipio)", $0.DescripcionMunicipio.capitalized(with: Locale(identifier: "es_ES")))
        }, uniquingKeysWith: { a, _ in a })
    }

    static func lines(province: String, municipality: String, stop: String) async throws -> [(code: String, name: String)] {
        let rows = try await records("gfReturn_LineasNew", [
            "strCODLINEA": "", "strDESCLINEA": "", "intACTIVAS": "1", "intESBIZKAIBUS": "1", "strNIF": "",
            "strGRUPO": "", "strSUBGRUPO": "", "strCODCENTRO": "", "strCODPROVINCIA": province,
            "strCODMUNICIPIO": municipality, "strCODZONA": "", "strCODTARIFA": "", "strCODPARADA": stop,
            "strINCIDENCIAS": "",
        ])
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let code = row["LN_CLINEA"], !code.isEmpty, seen.insert(code).inserted else { return nil }
            return (code, row["LN_DENOMI"] ?? code)
        }
        .sorted { $0.code.localizedStandardCompare($1.code) == .orderedAscending }
    }

    /// The main route's stops in travel order: code and municipality.
    static func itinerary(line: String, direction: String) async throws -> [(code: String, city: String?)] {
        let rows = try await records("gfReturn_Buscar_ItinerariosLinea_Basico",
                                     ["strCODLINEA": line, "strNUMRUTA": "001", "strSENTIDO": direction])
        return rows.compactMap { row in
            guard let code = row["PR_CODRED"], !code.isEmpty else { return nil }
            return (code, row["DescripcionMunicipio"].flatMap(BizkaibusText.clean).map { $0.capitalized(with: Locale(identifier: "es_ES")) })
        }
    }

    struct Passage: Sendable {
        var line: String
        var minutes: [Int]
    }

    /// The JSON wraps an XML document in a JavaScript object with single-quoted strings, which no
    /// JSON parser takes; the XML is cut out and read on its own. `NOINFO` is an unknown stop or
    /// nothing due.
    static func passages(stopCode: String) async throws -> [Passage] {
        let (data, response, request) = try await get("GetPasoParadaMobile_JSON", ["callback": "", "strLinea": "", "strParada": stopCode])
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<GetPasoParadaResult>"),
              let end = text.range(of: "</GetPasoParadaResult>", range: start.upperBound..<text.endIndex) else {
            if text.contains("'STATUS': 'ERROR'") { throw ResponseError("GetPasoParadaMobile_JSON: error", data, response, request) }
            return []
        }
        let root: XMLNode
        do {
            root = try XMLNode.parse(Data(text[start.lowerBound..<end.upperBound].utf8))
        } catch {
            throw ResponseError("GetPasoParadaMobile_JSON: \(ResponseError.describe(error))", data, response, request)
        }
        return root.children.filter { $0.name == "PasoParada" }.compactMap { passage in
            guard let line = passage.child("linea")?.text, !line.isEmpty else { return nil }
            let minutes = ["e1", "e2"].compactMap { passage.child($0)?.child("minutos").flatMap { Int($0.text) } }
            return Passage(line: line, minutes: minutes)
        }
    }

    /// Reads just the fields used, per gtfs-realtime.proto: FeedMessage.entity (2) → FeedEntity.vehicle (4)
    /// → VehiclePosition { trip (1) { trip_id 1 }, position (2) { latitude 1, longitude 2 — float },
    /// current_stop_sequence (3), timestamp (5), stop_id (7) }.
    static func vehicles() async throws -> [BizkaibusVehicle] {
        guard let url = URL(string: feedURL) else { throw TransitError.badResponse("invalid GTFS-RT URL") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("BusBus-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTPClient.check(data, response, request, "FeedVehiculos.pb")
        var vehicles: [BizkaibusVehicle] = []
        do {
            try Protobuf.fields(Array(data)[...]) { field, value in
                guard field == 2, case .bytes(let entity) = value else { return }
                try Protobuf.fields(entity) { field, value in
                    guard field == 4, case .bytes(let body) = value else { return }
                    var tripID: String?, stopID: String?, lat: Float?, lon: Float?
                    var sequence: Int?
                    var timestamp: UInt64?
                    try Protobuf.fields(body) { field, value in
                        switch (field, value) {
                        case (1, .bytes(let trip)):
                            try Protobuf.fields(trip) { field, value in
                                if field == 1, case .bytes(let text) = value { tripID = String(decoding: text, as: UTF8.self) }
                            }
                        case (2, .bytes(let position)):
                            try Protobuf.fields(position) { field, value in
                                guard case .fixed32(let bits) = value else { return }
                                if field == 1 { lat = Float(bitPattern: bits) }
                                if field == 2 { lon = Float(bitPattern: bits) }
                            }
                        case (3, .varint(let value)): sequence = Int(clamping: value)
                        case (5, .varint(let value)): timestamp = value
                        case (7, .bytes(let text)): stopID = String(decoding: text, as: UTF8.self)
                        default: break
                        }
                    }
                    let parts = tripID?.split(separator: "_") ?? []
                    guard let tripID, parts.count > 1, let lat, let lon, lat != 0 || lon != 0 else { return }
                    vehicles.append(BizkaibusVehicle(
                        tripID: tripID,
                        line: String(parts[1]),
                        location: GeoPoint(lat: Double(lat), lon: Double(lon)),
                        // "167" in the feed is stop "0167" everywhere else.
                        stopCode: stopID.map { $0.count < 4 ? String(repeating: "0", count: 4 - $0.count) + $0 : $0 },
                        stopSequence: sequence,
                        timestamp: timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    ))
                }
            }
        } catch {
            throw ResponseError("FeedVehiculos.pb: \(ResponseError.describe(error))", data, response, request)
        }
        return vehicles
    }

    // MARK: Plumbing

    /// The `Registro` rows of an XML operation: `<string>1®&lt;Consulta&gt;&lt;Registro …/&gt;…</string>`.
    static func records(_ operation: String, _ query: [String: String], timeout: TimeInterval = 30) async throws -> [[String: String]] {
        let (data, response, request) = try await get(operation, query, timeout: timeout)
        do {
            let text = try XMLNode.parse(data).text
            guard let mark = text.firstIndex(of: "®") else { throw TransitError.badResponse("no status mark") }
            let status = text[..<mark].trimmingCharacters(in: .whitespacesAndNewlines)
            let payload = String(text[text.index(after: mark)...])
            guard status == "1" else { throw TransitError.badResponse("status \(status): \(payload.prefix(200))") }
            return try XMLNode.parse(Data(payload.utf8)).children.filter { $0.name == "Registro" }.map(\.attributes)
        } catch {
            throw ResponseError("\(operation): \(ResponseError.describe(error))", data, response, request)
        }
    }

    static func get(_ operation: String, _ query: [String: String],
                    timeout: TimeInterval = 30) async throws -> (Data, URLResponse, URLRequest) {
        guard var components = URLComponents(string: base + operation) else { throw TransitError.badResponse("invalid URL \(operation)") }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw TransitError.badResponse("invalid URL \(operation)") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("BusBus-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTPClient.check(data, response, request, operation)
        return (data, response, request)
    }

    /// `({…});` → `{…}`.
    static func jsonp(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("("), let close = text.lastIndex(of: ")") else { return data }
        return Data(text[text.index(after: text.startIndex)..<close].utf8)
    }
}

private nonisolated enum BizkaibusText {
    /// Case- and accent-insensitive, whitespace collapsed.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func clean(_ s: String?) -> String? {
        let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// ETRS89 / UTM zone 30N (EPSG:25830) to latitude/longitude, the series expansion of the inverse
/// transverse Mercator (Snyder, *Map Projections*, p. 63). Well under a metre across Bizkaia.
private nonisolated enum UTM {
    static func etrs89Zone30(easting: Double, northing: Double) -> GeoPoint {
        let a = 6_378_137.0, f = 1 / 298.257222101, k0 = 0.9996
        let e2 = f * (2 - f), ep2 = e2 / (1 - e2)
        let x = easting - 500_000, m = northing / k0
        let mu = m / (a * (1 - e2 / 4 - 3 * e2 * e2 / 64 - 5 * e2 * e2 * e2 / 256))
        let e1 = (1 - (1 - e2).squareRoot()) / (1 + (1 - e2).squareRoot())
        let phi1 = mu + (3 * e1 / 2 - 27 * pow(e1, 3) / 32) * sin(2 * mu)
            + (21 * e1 * e1 / 16 - 55 * pow(e1, 4) / 32) * sin(4 * mu)
            + (151 * pow(e1, 3) / 96) * sin(6 * mu) + (1097 * pow(e1, 4) / 512) * sin(8 * mu)
        let c1 = ep2 * pow(cos(phi1), 2), t1 = pow(tan(phi1), 2)
        let n1 = a / (1 - e2 * pow(sin(phi1), 2)).squareRoot()
        let r1 = a * (1 - e2) / pow(1 - e2 * pow(sin(phi1), 2), 1.5)
        let d = x / (n1 * k0)
        let lat = phi1 - (n1 * tan(phi1) / r1) * (d * d / 2
            - (5 + 3 * t1 + 10 * c1 - 4 * c1 * c1 - 9 * ep2) * pow(d, 4) / 24
            + (61 + 90 * t1 + 298 * c1 + 45 * t1 * t1 - 252 * ep2 - 3 * c1 * c1) * pow(d, 6) / 720)
        let lon = (d - (1 + 2 * t1 + c1) * pow(d, 3) / 6
            + (5 - 2 * c1 + 28 * t1 - 3 * c1 * c1 + 8 * ep2 + 24 * t1 * t1) * pow(d, 5) / 120) / cos(phi1)
        return GeoPoint(lat: lat * 180 / .pi, lon: -3 + lon * 180 / .pi)
    }
}

// MARK: - XML

/// A small XML tree: the service's documents are a few hundred KB at most.
private nonisolated struct XMLNode: Sendable {
    var name: String
    var attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []

    func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }

    static func parse(_ data: Data) throws -> XMLNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw TransitError.badResponse("XML: \(parser.parserError.map(String.init(describing:)) ?? "unparseable")")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [XMLNode] = []
        var root: XMLNode?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            stack.append(XMLNode(name: elementName, attributes: attributeDict))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard var node = stack.popLast() else { return }
            node.text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if stack.isEmpty { root = node } else { stack[stack.count - 1].children.append(node) }
        }
    }
}

// MARK: - Protobuf

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

private nonisolated extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}

private nonisolated extension Sequence {
    func asyncCompactMap<T>(_ transform: (Element) async throws -> T?) async rethrows -> [T] {
        var result: [T] = []
        for element in self { if let value = try await transform(element) { result.append(value) } }
        return result
    }
}
