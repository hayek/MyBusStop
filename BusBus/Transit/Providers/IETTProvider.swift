import Foundation

/// Turkey, Istanbul — İETT, the city's bus operator, through İBB's keyless SOAP web services
/// (api.ibb.gov.tr/iett, ASP.NET `.asmx` behind a Layer7 gateway that rejects every operation the
/// WSDL lists but the public documentation does not). Official; İBB Open Data Licence (CC BY 4.0
/// compatible). Names are published in Turkish only, in capitals. See
/// docs/research/worldwide-apis.md §6.10.
///
/// Operations used:
/// - `HatDurakGuzergah.asmx GetDurak_json` — one stop by code, or every stop (15k stops, 3.7 MB of
///   JSON-in-XML, ~560 KB gzipped) with an empty code: the name search and nearby source.
/// - `ibb.asmx DurakDetay_GYY` — the ordered stops of both directions (`YON` G/D) of one line
///   (~20 KB). With an empty line code it returns the whole network (~82k rows, 28.6 MB of XML but
///   ~2 MB gzipped, ~15 s server time): the only way to learn which lines call at a stop, as there
///   is no stop→lines operation. It is streamed to a temporary file and parsed row by row, so only
///   a compact index stays in memory.
/// - `HatDurakGuzergah.asmx GetHat_json` — the line's timetabled running time, for ETAs.
/// - `SeferGerceklesme.asmx GetHatOtoKonum_json` — live positions of one line's buses (fixes
///   ~5–30 s old). Documented limit: **100 requests per hour** for this service.
///
/// There is no arrival-prediction operation, so arrivals are estimated from the live positions:
/// the share of the route between each bus and the stop, times the line's one-way running time.
nonisolated struct IETTProvider: TransitProvider {
    let id = "iett"
    let displayName = "İETT (İstanbul)"
    let attribution: String? = "Kaynak: İETT, İBB Açık Veri Portalı. Atıf 4.0 Uluslararası (CC BY 4.0) kapsamında lisanslanan kamu sektörü bilgilerini içerir."
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .nearbyStops, .routeShape,
    ]
    /// The position service allows 100 calls an hour; one board poll is one call (vehicles and
    /// arrivals share it), so 40 s keeps a single board at 90/h.
    let suggestedRefreshInterval: Duration = .seconds(40)
    var refreshInterval: Duration { suggestedRefreshInterval }

    static let timeZone = TimeZone(identifier: "Europe/Istanbul")!

    private var cache: IETTCache { .shared }
    /// For the website's map endpoint, which took up to 21 s in testing.
    var http = HTTPClient(timeout: 40)

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        if query.allSatisfy(\.isNumber) {
            let direct = try await SOAP.json([DTO.Stop].self, "UlasimAnaVeri/HatDurakGuzergah.asmx",
                                             "GetDurak_json", ["DurakKodu": query])
            let stops = direct.compactMap(\.stop)
            if !stops.isEmpty { return stops }
        }
        let needle = IETTText.fold(query)
        let words = needle.split(separator: " ").map(String.init)
        return try await cache.stops().all
            .filter { entry in words.allSatisfy(entry.folded.contains) }
            .sorted { a, b in
                let ar = a.folded == needle ? 0 : a.folded.hasPrefix(needle) ? 1 : 2
                let br = b.folded == needle ? 0 : b.folded.hasPrefix(needle) ? 1 : 2
                return ar != br ? ar < br : (a.stop.name, a.stop.code) < (b.stop.name, b.stop.code)
            }
            .prefix(60)
            .map(\.stop)
    }

    /// Every direction of every line whose pattern calls at the stop, from the whole-network index.
    /// Directions that only *end* here are dropped unless nothing else serves the stop (a terminus).
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        try await cache.network().lines(at: stop.code)
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let ref = Ref(line)
        let rows = try await cache.pattern(ofLine: ref.line)[ref.direction] ?? []
        guard rows.count >= 2 else { throw TransitError.notFound("stops of line \(ref.line) direction \(ref.direction)") }
        return RoutePattern(line: line, stops: rows.map { PatternStop(stop: $0.stop, sequence: $0.sequence) })
    }

    /// The İETT website's own map call (`GetRoutePinV2`, 17–48 KB, not compressed), by route code:
    /// line, direction and `D0` for the direction's main route, the variant the stop list is. Not part
    /// of the open-data API, but the same geometry is published there (`iett-hat-guzergahlari`,
    /// CC BY 4.0) as a 257 MB file, far too big to fetch per line.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        let ref = Ref(line)
        let code = "\(ref.line)_\(ref.direction)_D0"
        let reply = try await http.get([DTO.RoutePin].self, "https://iett.istanbul", "/tr/RouteStation/GetRoutePinV2",
                                       query: ["q": code])
        let points = Self.decodeRoutePin(reply.first?.line ?? "")
        // An unknown code is answered 200 with an empty line.
        guard points.count >= 2 else { throw TransitError.notFound("shape of route \(code)") }
        return RouteShape(points, version: code)
    }

    /// `LINESTRING (lon lat, lon lat, …)|LINESTRING (…)`: one piece per stop-to-stop leg, already
    /// in order, so they are joined end to end (a joint repeated across pieces is kept once).
    static func decodeRoutePin(_ wkt: String) -> [GeoPoint] {
        var points: [GeoPoint] = []
        for piece in wkt.split(separator: "|") {
            guard let open = piece.firstIndex(of: "("), let close = piece.lastIndex(of: ")"), open < close else { continue }
            for pair in piece[piece.index(after: open)..<close].split(separator: ",") {
                let values = pair.split(separator: " ").compactMap { Double($0) }
                guard values.count >= 2 else { continue }
                let point = GeoPoint(lat: values[1], lon: values[0])
                if points.last != point { points.append(point) }
            }
        }
        return points
    }

    /// The feed is per line; its `guzergahkodu` ("500T_G_D0" = line, direction, variant) says which
    /// direction each bus is running.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let ref = Ref(line)
        return try await cache.vehicles(ofLine: ref.line)
            .filter { $0.direction(ofLine: ref.line) == ref.direction }
            .compactMap(\.position)
    }

    /// Estimated, not published: each bus of this direction still short of the stop arrives after
    /// the share of the route left to it times the line's one-way running time (`SEFER_SURESI`,
    /// timetabled minutes for the round trip), counted from its GPS fix. Realtime in that it moves
    /// with a live bus; there is no timetable time to show beside it. Buses still at the first stop
    /// are left out.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let ref = Ref(line)
        async let feed = cache.vehicles(ofLine: ref.line)
        async let roundTrip = cache.roundTripMinutes(ofLine: ref.line)
        let pattern = try await routePattern(for: line)
        let geometry = RouteGeometry(pattern: pattern)
        guard let target = geometry.distance(ofStopCode: stop.code), geometry.totalLength > 0 else {
            throw TransitError.notFound("stop \(stop.code) on line \(line.shortName)")
        }
        let oneWay = try await roundTrip.map { $0 * 60 / 2 }
        var secondsPerMeter = oneWay.map { $0 / geometry.totalLength } ?? 0
        // Outside 7–54 km/h the published running time is not believable; assume 18 km/h.
        if !(1.0 / 15...1.0 / 2).contains(secondsPerMeter) { secondsPerMeter = 1 / 5 }

        let now = Date()
        return try await feed
            .filter { $0.direction(ofLine: ref.line) == ref.direction }
            .compactMap { vehicle -> Arrival? in
                guard let position = vehicle.position,
                      let along = Self.distanceAlong(position.location, near: vehicle.yakinDurakKodu, geometry) else { return nil }
                // Buses laid over at the first stop have not started the trip; no time can be told.
                guard along > 100 else { return nil }
                let remaining = target - along
                guard remaining > -BusProgressService.atStopToleranceMeters else { return nil }
                let fix = min(position.recordedAt ?? now, now)
                let expected = max(fix.addingTimeInterval(max(remaining, 0) * secondsPerMeter), now)
                return Arrival(expectedAt: expected, scheduledAt: nil, isRealtime: true,
                               tripId: vehicle.kapino, vehicleLocation: position.location)
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// No proximity query either: the cached stop list is filtered, and the lines come from the
    /// whole-network index. Stops no İETT line calls at are left out.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let nearest = try await cache.stops().all
            .map { (stop: $0.stop, distance: RouteGeometry.meters(point, $0.stop.location)) }
            .filter { $0.distance <= radiusMeters }
            .sorted { $0.distance < $1.distance }
            .prefix(30)
        guard !nearest.isEmpty else { return [] }
        let network = try await cache.network()
        return nearest
            .compactMap { near -> NearbyStop? in
                let lines = network.lines(at: near.stop.code)
                return lines.isEmpty ? nil : NearbyStop(stop: near.stop, distanceMeters: near.distance, lines: lines)
            }
            .prefix(15)
            .map { $0 }
    }

    // MARK: - Helpers

    /// Snaps a bus onto the route. On routes that fold back on themselves the nearest segment can
    /// be the wrong leg, so the feed's own "nearest stop" wins when the two disagree by over 1.5 km.
    private static func distanceAlong(_ point: GeoPoint, near stopCode: String?, _ geometry: RouteGeometry) -> Double? {
        let hinted = stopCode.flatMap { geometry.distance(ofStopCode: $0) }
        guard let snapped = geometry.project(point), snapped.offRoute <= 400 else { return nil }
        if let hinted, abs(hinted - snapped.distanceAlong) > 1_500 { return hinted }
        return snapped.distanceAlong
    }

    /// Line code and direction (G = gidiş, D = dönüş). Line ids are "<line>_<G|D>", which is the
    /// fallback for a line cached without `providerRefs`.
    private nonisolated struct Ref {
        var line: String
        var direction: String

        init(_ line: TransitLine) {
            let parts = line.id.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
            self.line = line.providerRefs["line"] ?? parts.dropLast().joined(separator: "_")
            direction = line.providerRefs["direction"] ?? parts.last ?? "G"
        }
    }
}

// MARK: - Session cache

private actor IETTCache {
    static let shared = IETTCache()

    private var stopsTask: Task<IETTStopList, any Error>?
    private var networkTask: Task<IETTNetwork, any Error>?
    private var loadedNetwork: IETTNetwork?
    private var patterns: [String: Task<[String: [IETTNetwork.Row]], any Error>] = [:]
    private var runningTimes: [String: Task<Double?, any Error>] = [:]
    private var feeds: [String: (fetched: ContinuousClock.Instant, task: Task<[DTO.Vehicle], any Error>)] = [:]

    /// Every stop, once per session (3.7 MB of JSON, ~560 KB gzipped). A failed load is retried.
    func stops() async throws -> IETTStopList {
        if let stopsTask { return try await stopsTask.value }
        let task = Task {
            let dtos = try await SOAP.json([DTO.Stop].self, "UlasimAnaVeri/HatDurakGuzergah.asmx",
                                           "GetDurak_json", ["DurakKodu": ""], timeout: 60)
            return IETTStopList(all: dtos.compactMap(\.stop).map { .init(stop: $0, folded: IETTText.fold($0.name)) })
        }
        stopsTask = task
        do { return try await task.value } catch { stopsTask = nil; throw error }
    }

    /// Every pattern of every line, once per session (~2 MB on the wire, see the provider notes).
    func network() async throws -> IETTNetwork {
        if let networkTask { return try await networkTask.value }
        let task = Task { try await IETTNetwork.load() }
        networkTask = task
        do {
            let network = try await task.value
            loadedNetwork = network
            return network
        } catch { networkTask = nil; throw error }
    }

    /// Both directions of one line, keyed "G"/"D". Taken from the network index when it is already
    /// loaded, otherwise asked for on its own (~20 KB), so a saved board never needs the full dump.
    func pattern(ofLine line: String) async throws -> [String: [IETTNetwork.Row]] {
        if let known = loadedNetwork?.patterns[line] { return known }
        if let task = patterns[line] { return try await task.value }
        let task = Task {
            var rows: [(String, IETTNetwork.Row)] = []
            let data = try await SOAP.call("ibb/ibb.asmx", "DurakDetay_GYY", ["hat_kodu": line])
            try TableParser.parse(data: data) { fields in
                guard fields["HATKODU"] == line, let parsed = IETTNetwork.Row(fields) else { return }
                rows.append((fields["YON"] ?? "", parsed))
            }
            return IETTNetwork.group(rows)
        }
        patterns[line] = task
        do { return try await task.value } catch { patterns[line] = nil; throw error }
    }

    /// `SEFER_SURESI` of the line, in minutes (nil when unpublished).
    func roundTripMinutes(ofLine line: String) async throws -> Double? {
        if let task = runningTimes[line] { return try await task.value }
        let task = Task {
            let lines = try await SOAP.json([DTO.Line].self, "UlasimAnaVeri/HatDurakGuzergah.asmx",
                                            "GetHat_json", ["HatKodu": line])
            return lines.first { $0.SHATKODU == line }?.SEFER_SURESI
        }
        runningTimes[line] = task
        do { return try await task.value } catch { runningTimes[line] = nil; throw error }
    }

    /// One line's buses, shared for 15 s so that the board's vehicles and arrivals cost one call
    /// against the service's 100-an-hour budget.
    func vehicles(ofLine line: String) async throws -> [DTO.Vehicle] {
        if let cached = feeds[line], ContinuousClock.now - cached.fetched < .seconds(15) {
            return try await cached.task.value
        }
        let task = Task {
            try await SOAP.json([DTO.Vehicle].self, "FiloDurum/SeferGerceklesme.asmx",
                                "GetHatOtoKonum_json", ["HatKodu": line])
        }
        feeds[line] = (ContinuousClock.now, task)
        do { return try await task.value } catch { feeds[line] = nil; throw error }
    }
}

private nonisolated struct IETTStopList: Sendable {
    struct Entry: Sendable {
        var stop: TransitStop
        var folded: String
    }
    var all: [Entry]
}

/// The whole network: each line's directions as ordered stops, and which directions call where.
private nonisolated struct IETTNetwork: Sendable {
    struct Row: Sendable {
        var sequence: Int
        var stop: TransitStop

        init?(_ fields: [String: String]) {
            guard let code = fields["DURAKKODU"], !code.isEmpty,
                  let sequence = fields["SIRANO"].flatMap({ Int($0) }),
                  let lon = fields["XKOORDINATI"].flatMap({ Double($0) }),
                  let lat = fields["YKOORDINATI"].flatMap({ Double($0) }) else { return nil }
            self.sequence = sequence
            stop = TransitStop(code: code, name: IETTText.clean(fields["DURAKADI"]) ?? code,
                               city: IETTText.clean(fields["ILCEADI"]), location: GeoPoint(lat: lat, lon: lon))
        }
    }

    struct Key: Hashable, Sendable {
        var line: String
        var direction: String
    }

    /// line → direction → stops in travel order.
    var patterns: [String: [String: [Row]]]
    /// stop code → the directions that call there, and whether the stop is where they end.
    var callsAt: [String: [(key: Key, isLast: Bool)]]

    /// Streams `DurakDetay_GYY` for every line to a temporary file and indexes it row by row.
    static func load() async throws -> IETTNetwork {
        let file = try await SOAP.download("ibb/ibb.asmx", "DurakDetay_GYY", ["hat_kodu": ""])
        defer { try? FileManager.default.removeItem(at: file) }
        var rows: [String: [(String, Row)]] = [:]
        // ~82k rows but only ~13.7k distinct stops: one shared TransitStop per code keeps it small.
        var interned: [String: TransitStop] = [:]
        guard let stream = InputStream(url: file) else { throw TransitError.badResponse("İETT network dump unreadable") }
        try TableParser.parse(stream: stream) { fields in
            guard let line = fields["HATKODU"], !line.isEmpty, var row = Row(fields) else { return }
            if let known = interned[row.stop.code] { row.stop = known } else { interned[row.stop.code] = row.stop }
            rows[line, default: []].append((fields["YON"] ?? "", row))
        }
        guard !rows.isEmpty else { throw TransitError.badResponse("İETT network dump is empty") }
        let patterns = rows.mapValues(group)
        var callsAt: [String: [(key: Key, isLast: Bool)]] = [:]
        for (line, directions) in patterns {
            for (direction, stops) in directions {
                for (index, row) in stops.enumerated() {
                    callsAt[row.stop.code, default: []].append((Key(line: line, direction: direction),
                                                                index == stops.count - 1))
                }
            }
        }
        return IETTNetwork(patterns: patterns, callsAt: callsAt)
    }

    /// Rows of one line grouped by direction, in `SIRANO` order; a repeated number keeps its first row.
    static func group(_ rows: [(String, Row)]) -> [String: [Row]] {
        Dictionary(grouping: rows, by: \.0).mapValues { directionRows in
            var seen = Set<Int>()
            return directionRows.map(\.1).sorted { $0.sequence < $1.sequence }.filter { seen.insert($0.sequence).inserted }
        }
    }

    func lines(at stopCode: String) -> [TransitLine] {
        let calls = callsAt[stopCode] ?? []
        let boarding = calls.filter { !$0.isLast }
        return (boarding.isEmpty ? calls : boarding)
            .map(\.key)
            .sorted { a, b in
                a.line != b.line ? a.line.localizedStandardCompare(b.line) == .orderedAscending : a.direction > b.direction
            }
            .compactMap(line)
    }

    private func line(_ key: Key) -> TransitLine? {
        guard let stops = patterns[key.line]?[key.direction], let first = stops.first, let last = stops.last else { return nil }
        return TransitLine(
            id: "\(key.line)_\(key.direction)",
            shortName: key.line,
            headsign: last.stop.name,
            agency: "İETT",
            origin: first.stop.name,
            destination: last.stop.name,
            providerRefs: ["line": key.line, "direction": key.direction]
        )
    }
}

private nonisolated enum IETTText {
    /// Case- and accent-insensitive, with Turkish dotted/dotless i folded together.
    static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "I")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func clean(_ s: String?) -> String? {
        let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - SOAP

/// SOAP 1.1 over HTTPS. The `_json` operations wrap a JSON document as the text of `<OpResult>`;
/// the others return an ADO.NET `NewDataSet` of `<Table>` rows.
private nonisolated enum SOAP {
    static let base = "https://api.ibb.gov.tr/iett/"

    static func request(_ service: String, _ operation: String, _ parameters: [String: String], timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: base + service) else { throw TransitError.badResponse("invalid URL \(service)") }
        let body = parameters.sorted { $0.key < $1.key }.map { "<\($0.key)>\(escape($0.value))</\($0.key)>" }.joined()
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"http://tempuri.org/\(operation)\"", forHTTPHeaderField: "SOAPAction")
        request.setValue("BusBus-iOS/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">\
            <soap:Body><\(operation) xmlns="http://tempuri.org/">\(body)</\(operation)></soap:Body></soap:Envelope>
            """.utf8)
        return request
    }

    static func call(_ service: String, _ operation: String, _ parameters: [String: String], timeout: TimeInterval = 30) async throws -> Data {
        try await exchange(service, operation, parameters, timeout: timeout).data
    }

    /// The reply, with the request and response it came from so a later parse can report the body.
    private static func exchange(_ service: String, _ operation: String, _ parameters: [String: String],
                                 timeout: TimeInterval) async throws -> (data: Data, response: URLResponse, request: URLRequest) {
        let request = try request(service, operation, parameters, timeout: timeout)
        let (data, response) = try await URLSession.shared.data(for: request)
        // The gateway answers a refused operation (or an exceeded quota) with a 500 SOAP fault.
        try HTTPClient.check(data, response, request, operation)
        return (data, response, request)
    }

    /// For the network dump: the body goes to a file (URLSession undoes the gzip), never to memory.
    static func download(_ service: String, _ operation: String, _ parameters: [String: String]) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(for: request(service, operation, parameters, timeout: 120))
        do { try check(response, operation) } catch { try? FileManager.default.removeItem(at: file); throw error }
        return file
    }

    static func json<T: Decodable>(_ type: T.Type, _ service: String, _ operation: String, _ parameters: [String: String],
                                   timeout: TimeInterval = 30) async throws -> T {
        let raw = try await exchange(service, operation, parameters, timeout: timeout)
        let text: String
        do {
            text = try ResultParser.text(of: "\(operation)Result", in: raw.data)
        } catch {
            throw ResponseError("\(operation): \(ResponseError.describe(error))", raw.data, raw.response, raw.request)
        }
        return try HTTPClient.decode(T.self, Data(text.utf8), raw.response, raw.request, operation)
    }

    private static func check(_ response: URLResponse, _ operation: String) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        // The gateway answers a refused operation (or an exceeded quota) with a 500 SOAP fault.
        guard (200..<300).contains(status) else { throw TransitError.badResponse("HTTP \(status) for \(operation)") }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Collects the text of one element (the `…Result` that carries a JSON document).
private nonisolated final class ResultParser: NSObject, XMLParserDelegate {
    private let element: String
    private var inside = false
    private var text = ""
    private var found = false

    private init(element: String) { self.element = element }

    static func text(of element: String, in data: Data) throws -> String {
        let delegate = ResultParser(element: element)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.found else {
            throw TransitError.badResponse("no <\(element)> in response\(parser.parserError.map { ": \($0)" } ?? "")")
        }
        return delegate.text
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == element { inside = true; found = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inside { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == element { inside = false }
    }
}

/// Streams `<Table><FIELD>value</FIELD>…</Table>` rows to a closure, one flat dictionary per row.
private nonisolated final class TableParser: NSObject, XMLParserDelegate {
    private let onRow: ([String: String]) -> Void
    private var row: [String: String]?
    private var text = ""

    private init(onRow: @escaping ([String: String]) -> Void) { self.onRow = onRow }

    static func parse(data: Data, onRow: @escaping ([String: String]) -> Void) throws {
        try run(XMLParser(data: data), onRow)
    }

    static func parse(stream: InputStream, onRow: @escaping ([String: String]) -> Void) throws {
        try run(XMLParser(stream: stream), onRow)
    }

    private static func run(_ parser: XMLParser, _ onRow: @escaping ([String: String]) -> Void) throws {
        let delegate = TableParser(onRow: onRow)
        parser.delegate = delegate
        guard parser.parse() else {
            throw TransitError.badResponse("İETT XML: \(parser.parserError.map(String.init(describing:)) ?? "unparseable")")
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "Table" { row = [:] }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if row != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Table" {
            if let row { onRow(row) }
            row = nil
        } else if row != nil {
            row?[elementName] = text
        }
        text = ""
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    /// `GetRoutePinV2`: the route as WKT pieces, and its stops by name only.
    struct RoutePin: Decodable, Sendable { var line: String? }

    /// `GetDurak_json`. `SDURAKKODU` is a JSON number; `KOORDINAT` is WKT "POINT (lon lat)".
    struct Stop: Decodable, Sendable {
        var SDURAKKODU: Int?
        var SDURAKADI: String?
        var KOORDINAT: String?
        var ILCEADI: String?

        var stop: TransitStop? {
            guard let code = SDURAKKODU, let point = KOORDINAT else { return nil }
            let numbers = point.split(whereSeparator: { "() ".contains($0) }).compactMap { Double($0) }
            guard numbers.count == 2 else { return nil }
            return TransitStop(code: String(code), name: IETTText.clean(SDURAKADI) ?? String(code),
                               city: IETTText.clean(ILCEADI), location: GeoPoint(lat: numbers[1], lon: numbers[0]))
        }
    }

    /// `GetHat_json`. `SEFER_SURESI` is the timetabled round trip in minutes (Metrobüs 34: 144 for
    /// a ~70-minute ride each way).
    struct Line: Decodable, Sendable {
        var SHATKODU: String?
        var SEFER_SURESI: Double?
    }

    /// `GetHatOtoKonum_json`. Coordinates are strings; the fix time is Istanbul wall-clock time.
    struct Vehicle: Decodable, Sendable {
        var kapino: String?
        var boylam: String?
        var enlem: String?
        var guzergahkodu: String?
        var son_konum_zamani: String?
        var yakinDurakKodu: String?

        /// "500T_G_D0" → "G" for line 500T.
        func direction(ofLine line: String) -> String? {
            guard let route = guzergahkodu, route.hasPrefix(line + "_") else { return nil }
            return route.dropFirst(line.count + 1).split(separator: "_").first.map(String.init)
        }

        var position: VehiclePosition? {
            guard let lat = enlem.flatMap(Double.init), let lon = boylam.flatMap(Double.init),
                  lat != 0, lon != 0 else { return nil }
            return VehiclePosition(location: GeoPoint(lat: lat, lon: lon),
                                   recordedAt: son_konum_zamani.flatMap(DTO.parseLocal),
                                   plateNumber: kapino)
        }
    }

    /// "2026-09-22 15:31:56", Istanbul time.
    static func parseLocal(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = IETTProvider.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)
    }
}
