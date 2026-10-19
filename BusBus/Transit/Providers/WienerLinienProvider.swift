import Foundation

/// Vienna — Wiener Linien open government data (wienerlinien.at/ogd_realtime). Official and keyless
/// ("Ein API-Key ist nicht nötig"), CC BY 4.0: the app must credit
/// "Datenquelle: Stadt Wien – data.wien.gv.at / Wiener Linien". Fair use asks for polls ≥15 s apart
/// and only for stops actually shown; abuse is answered with an IP block.
/// See docs/research/worldwide-apis.md §5.8.
///
/// ARRIVALS-ONLY: the realtime `monitor` gives departures per stop, never vehicle positions.
///
/// Stops are RBL numbers (`StopID`), one per platform and direction; the monitor takes them as
/// `stopId`. Everything but the monitor — stop names and places, lines, and the stop sequence of every
/// line variant — only exists as CSV, so the three files are fetched once per session and searched
/// on the phone (see `ReferenceData`). Lines are limited to buses and trams: the U-Bahn and S-Bahn in
/// the same files are not what a bus board is for.
nonisolated struct WienerLinienProvider: TransitProvider {
    let id = "wienerlinien"
    let displayName = "Wiener Linien (Vienna)"
    let attribution: String? = "Datenquelle: Stadt Wien – data.wien.gv.at / Wiener Linien (CC BY 4.0)"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .realtimeArrivals, .scheduledArrivals, .nearbyStops, .routeShape,
    ]
    let suggestedRefreshInterval: Duration = .seconds(20)

    var http = HTTPClient()
    /// The routing service took 1.5–10 s per geo object in testing, once more than 11 s.
    var routingHTTP = HTTPClient(timeout: 30)

    private let base = "https://www.wienerlinien.at/ogd_realtime"

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let data = try await ReferenceData.shared.index()
        if let rbl = Int(query) {
            return data.stops[rbl].flatMap { data.servedStop($0) }.map { [$0] } ?? []
        }
        let needle = ReferenceData.fold(query)
        let matches = data.stops.values.filter { $0.folded.contains(needle) && data.isServed($0.rbl) }
        return matches
            .sorted { a, b in
                let (ap, bp) = (a.folded.hasPrefix(needle), b.folded.hasPrefix(needle))
                if ap != bp { return ap }
                return a.name == b.name ? a.rbl < b.rbl : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            .prefix(30)
            .compactMap { data.servedStop($0) }
    }

    /// The CSV lists every variant a line has ever been planned on, diversions and depot runs
    /// included, so the stop's live monitor decides which of them serve it today (see
    /// `Index.lines(atStop:live:)`). One monitor call, made once when a stop is chosen.
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        guard let rbl = Int(stop.code) else { throw TransitError.notFound("stop \(stop.code)") }
        let data = try await ReferenceData.shared.index()
        let monitor = try? await self.monitor(stop.code)
        let live = Set((monitor?.data?.monitors ?? []).flatMap { $0.lines ?? [] }.flatMap { line in
            let own = [line.lineId.flatMap { id in line.richtungsId.map { "\(id):\($0)" } }]
            let departures = (line.departures?.departure ?? []).map { departure in
                (departure.vehicle?.linienId ?? line.lineId).flatMap { id in
                    (departure.vehicle?.richtungsId ?? line.richtungsId).map { "\(id):\($0)" }
                }
            }
            return (own + departures).compactMap { $0 }
        })
        return data.lines(atStop: rbl, live: live)
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let ref = try reference(for: line)
        let data = try await ReferenceData.shared.index()
        guard let pattern = data.mainPattern(lineID: ref.lineID, direction: ref.direction, through: ref.rbl) else {
            throw TransitError.notFound("stops for line \(line.id)")
        }
        let stops = pattern.stops.compactMap { entry in
            data.stops[entry.rbl].map { PatternStop(stop: $0.stop, sequence: entry.sequence, distanceAlongRoute: nil) }
        }
        guard stops.count >= 2 else { throw TransitError.notFound("stops for line \(line.id)") }
        return RoutePattern(line: line, stops: stops)
    }

    /// The lines the timetable alone offers at `rbl`, each with the stops of the variant shown for
    /// it, from the reference files' rows (header dropped): what `lines(atStop:)` and
    /// `routePattern` read when the monitor vouches for nothing.
    static func timetableLines(at rbl: Int, stopRows: [[String]], lineRows: [[String]],
                               patternRows: [[String]]) -> [(line: TransitLine, stops: [String])] {
        let data = ReferenceData.index(stopRows: stopRows, lineRows: lineRows, patternRows: patternRows)
        return data.lines(atStop: rbl).compactMap { line in
            guard let lineID = line.providerRefs["lineId"].flatMap({ Int($0) }),
                  let direction = line.providerRefs["direction"].flatMap({ Int($0) }),
                  let main = data.mainPattern(lineID: lineID, direction: direction, through: rbl) else { return nil }
            return (line, main.stops.map { String($0.rbl) })
        }
    }

    /// Not the Badner Bahn, which the routing service has no id for. A line saved before it carried
    /// its mode is given the benefit of the doubt.
    func hasRouteShape(for line: TransitLine) -> Bool {
        guard let mode = line.providerRefs["mode"], let ref = try? reference(for: line) else { return true }
        return Self.timetableYears(Date()).contains { Self.efaLineID(name: line.shortName, mode: mode, direction: ref.direction, year: $0) != nil }
    }

    /// The line's path from Wiener Linien's routing service (`ogd_routing`, an EFA run by VOR):
    /// its geo object for the line and direction, 1.5–4 KB gzipped, stitched like Linz's (see
    /// `EFAShape`). It holds EFA's own main variant, which the timetable variant shown usually is.
    /// The line carries its name and mode, so the 1.85 MB of reference files are not loaded just
    /// to name it; only a line saved before it carried its mode looks them up.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        let ref = try reference(for: line)
        let name: String, mode: String
        if let carried = line.providerRefs["mode"] {
            (name, mode) = (line.shortName, carried)
        } else {
            guard let info = try await ReferenceData.shared.index().lines[ref.lineID] else {
                throw TransitError.notFound("line \(line.id)")
            }
            (name, mode) = (info.name, info.mode)
        }
        let ids = Self.timetableYears(Date()).compactMap {
            Self.efaLineID(name: name, mode: mode, direction: ref.direction, year: $0)
        }
        // The Badner Bahn has no id there: nothing is asked, and its card shows the stops alone.
        guard !ids.isEmpty else { throw TransitError.unsupported("route line of \(name)") }
        let stops = pattern.stops.map(\.stop.location)
        for id in ids {
            let response = try await routingHTTP.get(DTO.GeoObject.self, "https://www.wienerlinien.at/ogd_routing", "/XML_GEOOBJECT_REQUEST",
                                                     query: ["line": id, "outputFormat": "rapidJSON",
                                                             "coordOutputFormat": "WGS84[dd.ddddd]"])
            let pieces = (response.transportations ?? []).flatMap { $0.coords ?? [] }.map(EFAShape.points)
            // A year the service has no timetable for comes back with no pieces at all.
            guard !pieces.isEmpty else { continue }
            return RouteShape(EFAShape.stitch(pieces, stops: stops), version: id)
        }
        throw TransitError.notFound("shape of line \(name)")
    }

    /// The routing service's line id: "vor:2" + mode (2 tram, 3 bus, 4 night bus) + the name padded
    /// to three with zeros, then direction H/R and the timetable year: "vor:2313A: :H:j26" is 13A
    /// towards Hauptbahnhof in the 2026 timetable. Night lines pad the number after the N instead
    /// ("vor:24N06" is N6). The Badner Bahn has no id of this form.
    static func efaLineID(name: String, mode: String, direction: Int, year: Int) -> String? {
        let modes = ["ptTram": "2", "ptBusCity": "3", "ptBusNight": "4"]
        guard let mode = modes[mode], (1...2).contains(direction), name.count <= 3 else { return nil }
        func padded(_ text: some StringProtocol, to width: Int) -> String {
            String(repeating: "0", count: max(0, width - text.count)) + text
        }
        let name = mode == "4" && name.hasPrefix("N") ? "N" + padded(name.dropFirst(), to: 2) : padded(name, to: 3)
        return "vor:2\(mode)\(name): :\(direction == 1 ? "H" : "R"):j\(String(format: "%02d", year % 100))"
    }

    /// The timetable year runs from the second Sunday of December; around that day both are tried,
    /// the likelier first.
    static func timetableYears(_ date: Date) -> [Int] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return [] }
        guard month == 12 else { return [year] }
        let firstOfDecember = calendar.date(from: DateComponents(year: year, month: 12, day: 1))!
        let firstSunday = 1 + (8 - calendar.component(.weekday, from: firstOfDecember)) % 7
        return day >= firstSunday + 7 ? [year + 1, year] : [year, year + 1]
    }

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }

    /// The monitor lists every line at the RBL; departures are kept only for this line and direction
    /// (`richtungsId`, the same 1/2 as `Direction` in the CSV). A departure without `timeReal` is
    /// the timetable only.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let ref = try reference(for: line)
        let response = try await monitor(stop.code)
        return (response.data?.monitors ?? [])
            .flatMap { $0.lines ?? [] }
            .flatMap { monitorLine in
                (monitorLine.departures?.departure ?? []).compactMap { departure -> Arrival? in
                    let lineID = departure.vehicle?.linienId ?? monitorLine.lineId
                    let direction = departure.vehicle?.richtungsId ?? monitorLine.richtungsId
                    guard lineID == ref.lineID, direction == String(ref.direction) else { return nil }
                    let planned = departure.departureTime.timePlanned.flatMap(DTO.parseOffset)
                    let real = departure.departureTime.timeReal.flatMap(DTO.parseOffset)
                    guard let expected = real ?? planned else { return nil }
                    return Arrival(expectedAt: expected, scheduledAt: planned, isRealtime: real != nil,
                                   tripId: nil, vehicleLocation: nil)
                }
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    /// Computed on the phone from the cached stop list; each RBL is one platform, so the same place
    /// can appear once per direction.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let data = try await ReferenceData.shared.index()
        let latSpan = radiusMeters / 111_000
        let lonSpan = latSpan / max(cos(point.lat * .pi / 180), 0.01)
        return data.stops.values
            .filter { abs($0.lat - point.lat) <= latSpan && abs($0.lon - point.lon) <= lonSpan }
            .compactMap { entry -> NearbyStop? in
                let distance = RouteGeometry.meters(point, entry.stop.location)
                guard distance <= radiusMeters, let stop = data.servedStop(entry) else { return nil }
                let lines = data.lines(atStop: entry.rbl)
                return NearbyStop(stop: stop, distanceMeters: distance, lines: lines)
            }
            .sorted { $0.distanceMeters < $1.distanceMeters }
    }

    /// The monitor answers HTTP 200 even when it failed: the error is `message.messageCode` (311 DB
    /// unavailable, 312 no such stop, 316 request limit reached, 320/321 bad parameters), with no
    /// monitors, which would read as "no departures". 322 ("no data") is a genuinely empty board.
    private func monitor(_ stopID: String) async throws -> DTO.MonitorResponse {
        let response = try await http.get(DTO.MonitorResponse.self, base, "/monitor", query: ["stopId": stopID])
        if let code = response.message?.messageCode, code != 1, code != 322 {
            throw TransitError.badResponse("monitor for \(stopID): \(code) \(response.message?.value ?? "")")
        }
        return response
    }

    private struct Reference { var lineID: Int; var direction: Int; var rbl: Int? }

    private func reference(for line: TransitLine) throws -> Reference {
        let parts = line.id.split(separator: ":")
        guard let lineID = line.providerRefs["lineId"].flatMap(Int.init) ?? parts.first.flatMap({ Int($0) }),
              let direction = line.providerRefs["direction"].flatMap(Int.init) ?? (parts.count > 1 ? Int(parts[1]) : nil) else {
            throw TransitError.unsupported("line \(line.id) is not a Wiener Linien line")
        }
        return Reference(lineID: lineID, direction: direction, rbl: line.providerRefs["rbl"].flatMap(Int.init))
    }
}

// MARK: - Reference data (CSV, once per session)

/// The three OGD reference files, downloaded together the first time anything needs them and kept
/// for the rest of the session: `haltepunkte` (~340 KB, every RBL with name and coordinates),
/// `linien` (~5 KB, line names and modes) and `fahrwegverlaeufe` (~1.5 MB, the ordered stops of
/// every line variant). ~1.85 MB in all, served uncompressed. A failed load is forgotten so the
/// next call tries again.
private actor ReferenceData {
    static let shared = ReferenceData()

    private var loading: Task<Index, any Error>?

    func index() async throws -> Index {
        if let loading { return try await loading.value }
        let task = Task { try await Self.load() }
        loading = task
        do { return try await task.value } catch {
            loading = nil
            throw error
        }
    }

    struct Stop: Sendable {
        var rbl: Int
        var name: String
        var municipality: String
        var lat: Double
        var lon: Double
        var folded: String

        var stop: TransitStop { TransitStop(code: String(rbl), name: name, city: municipality, location: GeoPoint(lat: lat, lon: lon)) }
    }

    struct Line: Sendable {
        var id: Int
        var name: String
        var sort: Int
        /// `MeansOfTransport`: ptTram, ptBusCity, ptBusNight, ptTramWLB.
        var mode: String
        var isNight: Bool { mode == "ptBusNight" }
    }

    struct Pattern: Sendable {
        var lineID: Int
        var patternID: Int
        var direction: Int
        var stops: [(sequence: Int, rbl: Int)]
    }

    struct Index: Sendable {
        var stops: [Int: Stop]
        /// Buses and trams only.
        var lines: [Int: Line]
        var patterns: [Pattern]
        /// Indices into `patterns` of the variants that stop at an RBL.
        var patternsAtStop: [Int: [Int]]
        /// Indices into `patterns` of every variant of a line and direction, keyed "lineId:direction".
        var variants: [String: [Int]]

        func isServed(_ rbl: Int) -> Bool { !(patternsAtStop[rbl] ?? []).isEmpty }

        /// The lowest-numbered variant of a line and direction (the timetable's base route), through
        /// `rbl` when one is given. The file keeps every variant ever planned, and the longest was
        /// often a diversion that no longer runs (tram 6 to Zentralfriedhof): checked against the
        /// routing service's current paths, the lowest number matched on 12 of 17 directions where
        /// the two differ, the longest on none.
        func mainPattern(lineID: Int, direction: Int, through rbl: Int?) -> Pattern? {
            let candidates = (rbl.map { patternsAtStop[$0] ?? [] } ?? variants["\(lineID):\(direction)"] ?? []).map { patterns[$0] }
            return candidates
                .filter { $0.lineID == lineID && $0.direction == direction }
                .min { $0.patternID < $1.patternID }
        }

        /// Whether `rbl` is on the line's own route rather than only on a diversion or depot run:
        /// on its lowest-numbered variant (the timetable's base route) or on its longest one.
        func isRegular(lineID: Int, direction: Int, at rbl: Int) -> Bool {
            let variants = (variants["\(lineID):\(direction)"] ?? []).map { patterns[$0] }
            let base = variants.min { $0.patternID < $1.patternID }
            let longest = variants.max { $0.stops.count < $1.stops.count }
            return [base, longest].contains { $0?.stops.contains { $0.rbl == rbl } ?? false }
        }

        /// One line per line and direction that departs from `rbl`; a variant that only ends there is
        /// not a line a rider can wait for.
        ///
        /// `live` holds the "lineId:direction" pairs the stop's monitor lists right now. When it has
        /// any, it decides: the timetable data alone would offer trams that only pass on a diversion.
        /// Lines the monitor cannot vouch for — night lines by day, or everything when the monitor is
        /// empty or was not asked — fall back to `isRegular`.
        func lines(atStop rbl: Int, live: Set<String>? = nil) -> [TransitLine] {
            var keys: [(Int, Int)] = []
            for index in patternsAtStop[rbl] ?? [] {
                let pattern = patterns[index]
                guard pattern.stops.last?.rbl != rbl else { continue }
                if !keys.contains(where: { $0 == (pattern.lineID, pattern.direction) }) {
                    keys.append((pattern.lineID, pattern.direction))
                }
            }
            let live = live ?? []
            keys = keys.filter { lineID, direction in
                if live.contains("\(lineID):\(direction)") { return true }
                let vouchable = !live.isEmpty && lines[lineID]?.isNight != true
                return !vouchable && isRegular(lineID: lineID, direction: direction, at: rbl)
            }
            return keys
                .sorted { (lines[$0.0]?.sort ?? 0, $0.1) < (lines[$1.0]?.sort ?? 0, $1.1) }
                .compactMap { lineID, direction in
                    guard let line = lines[lineID],
                          let main = mainPattern(lineID: lineID, direction: direction, through: rbl) else { return nil }
                    let origin = main.stops.first.flatMap { stops[$0.rbl]?.name }
                    let destination = main.stops.last.flatMap { stops[$0.rbl]?.name }
                    return TransitLine(
                        id: "\(lineID):\(direction)",
                        shortName: line.name,
                        headsign: destination,
                        agency: "Wiener Linien",
                        origin: origin,
                        destination: destination,
                        providerRefs: ["lineId": String(lineID), "direction": String(direction), "rbl": String(rbl),
                                       "mode": line.mode]
                    )
                }
        }

        /// The stop as the picker shows it: RBLs share their place's name, so the lines leaving from
        /// it and where they go are added to tell the platforms apart.
        func servedStop(_ entry: Stop) -> TransitStop? {
            let lines = lines(atStop: entry.rbl)
            guard !lines.isEmpty else { return nil }
            var stop = entry.stop
            let names = lines.map(\.shortName).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let towards = lines.first?.destination.map { " → \($0)" } ?? ""
            let served = names.prefix(4).joined(separator: ", ") + towards
            stop.city = entry.municipality.isEmpty ? served : "\(entry.municipality) · \(served)"
            return stop
        }
    }

    private static let files = "https://www.wienerlinien.at/ogd_realtime/doku/ogd/wienerlinien-ogd-"
    private static let modes: Set<String> = ["ptBusCity", "ptBusNight", "ptTram", "ptTramWLB"]

    private static func load() async throws -> Index {
        async let stopRows = rows("haltepunkte")
        async let lineRows = rows("linien")
        async let patternRows = rows("fahrwegverlaeufe")
        return try await index(stopRows: stopRows, lineRows: lineRows, patternRows: patternRows)
    }

    /// The three files' rows, header dropped, as the index the provider reads.
    nonisolated static func index(stopRows: [[String]], lineRows: [[String]], patternRows: [[String]]) -> Index {
        // StopID;DIVA;StopText;Municipality;MunicipalityID;Longitude;Latitude
        var stops: [Int: Stop] = [:]
        for row in stopRows where row.count >= 7 {
            guard let rbl = Int(row[0]), let lon = Double(row[5]), let lat = Double(row[6]) else { continue }
            stops[rbl] = Stop(rbl: rbl, name: row[2], municipality: row[3], lat: lat, lon: lon, folded: fold(row[2]))
        }

        // LineID;LineText;SortingHelp;Realtime;MeansOfTransport
        var lines: [Int: Line] = [:]
        for row in lineRows where row.count >= 5 && modes.contains(row[4]) {
            guard let id = Int(row[0]) else { continue }
            lines[id] = Line(id: id, name: row[1], sort: Int(row[2]) ?? id, mode: row[4])
        }

        // LineID;PatternID;StopSeqCount;StopID;Direction — rows of one variant are contiguous, but are
        // grouped by key anyway rather than trusting that. Gaps in StopSeqCount are timing points.
        var grouped: [String: Pattern] = [:]
        for row in patternRows where row.count >= 5 {
            guard let lineID = Int(row[0]), lines[lineID] != nil, let patternID = Int(row[1]),
                  let sequence = Int(row[2]), let rbl = Int(row[3]), let direction = Int(row[4]) else { continue }
            grouped["\(lineID)/\(patternID)", default: Pattern(lineID: lineID, patternID: patternID, direction: direction, stops: [])]
                .stops.append((sequence, rbl))
        }
        var patterns: [Pattern] = []
        var patternsAtStop: [Int: [Int]] = [:]
        var variants: [String: [Int]] = [:]
        for var pattern in grouped.values {
            pattern.stops.sort { $0.sequence < $1.sequence }
            pattern.stops.removeAll { stops[$0.rbl] == nil }
            guard pattern.stops.count >= 2 else { continue }
            for rbl in Set(pattern.stops.map(\.rbl)) { patternsAtStop[rbl, default: []].append(patterns.count) }
            variants["\(pattern.lineID):\(pattern.direction)", default: []].append(patterns.count)
            patterns.append(pattern)
        }
        return Index(stops: stops, lines: lines, patterns: patterns, patternsAtStop: patternsAtStop, variants: variants)
    }

    /// Semicolon-separated, header first, CRLF line ends, no quoting in any of the three files.
    private static func rows(_ name: String) async throws -> [[String]] {
        guard let url = URL(string: files + name + ".csv") else { throw TransitError.badResponse("invalid URL for \(name)") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("BusBus-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTPClient.check(data, response, request, "\(name).csv")
        guard let text = String(data: data, encoding: .utf8) else {
            throw ResponseError("\(name).csv is not UTF-8", data, response, request)
        }
        return text.split(whereSeparator: \.isNewline).dropFirst().map {
            $0.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    /// Case- and accent-insensitive, so "strasse" and "Straße" and "schonbrunn" all find their stops.
    nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_AT"))
            .replacingOccurrences(of: "ß", with: "ss")
    }
}

// MARK: - Wire format

private nonisolated enum DTO {
    struct MonitorResponse: Decodable, Sendable {
        struct Payload: Decodable, Sendable { var monitors: [Monitor]? }
        struct Message: Decodable, Sendable { var value: String?; var messageCode: Int? }
        var data: Payload?
        var message: Message?
    }

    struct Monitor: Decodable, Sendable { var lines: [MonitorLine]? }

    struct MonitorLine: Decodable, Sendable {
        struct Departures: Decodable, Sendable { var departure: [Departure]? }
        var name: String?
        var lineId: Int?
        var richtungsId: String?
        var departures: Departures?
    }

    struct Departure: Decodable, Sendable {
        struct Time: Decodable, Sendable { var timePlanned: String?; var timeReal: String? }
        /// Present when a departure belongs to another line or direction than the entry it is listed under.
        struct Vehicle: Decodable, Sendable { var linienId: Int?; var richtungsId: String? }
        var departureTime: Time
        var vehicle: Vehicle?
    }

    /// The routing service's geo object; `coords` are loose pieces of `[[lat, lon], …]`.
    struct GeoObject: Decodable, Sendable {
        struct Transportation: Decodable, Sendable { var coords: [[[Double]]]? }
        var transportations: [Transportation]?
    }

    /// Local time with its offset: "2026-09-22T11:33:00.000+0200".
    static func parseOffset(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Vienna")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter.date(from: string)
    }
}
