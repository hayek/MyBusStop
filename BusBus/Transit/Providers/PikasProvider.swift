import Foundation

/// The "Pikas" timetable sites (transport.tallinn.ee, stops.lt): one CSV format behind several
/// Baltic cities, keyless and unofficial as an API — these are the files the cities' own journey
/// planners load in the browser, not a documented feed.
///
/// - `stops.txt` / `routes.txt`: the whole network, `;`-separated and delta-encoded (an empty cell
///   repeats the previous row's value, `0` means empty). Fetched once per session and city
///   (Tallinn ~570 KB, Vilnius ~600 KB, Kaunas ~220 KB of text; a quarter of that gzipped).
///   Each `routes.txt` row is one variant ("a-b", "b-a1", "dp-a"…) with its stops in order, and
///   is followed by one encoded timetable row, skipped here.
/// - `gps.txt` / `gps_full.txt`: every vehicle in the city (~20–70 KB), polled per board refresh.
/// - Departures at a stop: Tallinn's `siri-stop-departures.php` (predicted and scheduled seconds of
///   the day, by the stop's `SiriID`), stops.lt's `departures2.php` (vehicle-assigned trips only,
///   by the stop's own id, with the variant's direction type).
///
/// Times on the wire are seconds since local midnight; the service day runs past 24:00.
/// Only road vehicles (buses, trolleybuses) are offered; trams, ferries and trains are left out.
nonisolated struct PikasProvider: TransitProvider {
    let id: String
    let displayName: String
    let attribution: String?
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .nearbyStops, .routeShape,
    ]
    /// No published limit; the cities' own sites poll every 10 s, so 20 s is well within manners.
    let suggestedRefreshInterval: Duration = .seconds(20)

    let city: City
    /// Route map files read into their records, for the line card.
    private static let mapFiles = Memo<[String: String]>()

    /// Everything that differs between Pikas installations.
    nonisolated struct City: Sendable {
        var id: String
        var displayName: String
        var attribution: String
        /// Directory holding `stops.txt` and `routes.txt`.
        var dataURL: String
        /// Vehicle positions; a header row (stops.lt) switches to named columns.
        var gpsURL: String
        var departures: Departures
        var timeZone: TimeZone
        /// The routes file's `City` column, which names the map files: Tallinn's are
        /// `tallinna-linn_bus_9.txt`, not `tallinn_…`.
        var mapCity: String
        /// Transports whose map files go by another name, as the sites' own planner remaps them.
        var mapTransports: [String: String] = [:]
    }

    nonisolated enum Departures: Sendable {
        /// Tallinn: `transport,route,expectedSec,scheduledSec,destination,secondsUntil,flags`, asked by `SiriID`.
        case siri(String)
        /// stops.lt: `transport,route,directionType,sec,vehicle,…`, asked by stop id.
        case vehicles(String)
    }

    init(city: City) {
        self.city = city
        id = city.id
        displayName = city.displayName
        attribution = city.attribution
    }

    static let tallinn = PikasProvider(city: City(
        id: "tallinn",
        displayName: "TLT (Tallinn)",
        attribution: "Data: Tallinn City Transport Department (transport.tallinn.ee)",
        dataURL: "https://transport.tallinn.ee/data/",
        gpsURL: "https://transport.tallinn.ee/gps.txt",
        departures: .siri("https://transport.tallinn.ee/siri-stop-departures.php"),
        timeZone: TimeZone(identifier: "Europe/Tallinn")!,
        mapCity: "tallinna-linn",
        mapTransports: ["nightbus": "bus", "eventbus": "bus"]
    ))

    /// `gps_full.txt` rather than `gps.txt`: it names its columns and carries the variant's
    /// direction type, and it answered while `gps.txt` sat behind Cloudflare 522s.
    static let vilnius = PikasProvider(city: City(
        id: "vilnius",
        displayName: "stops.lt (Vilnius)",
        attribution: "Data: JUDU / Vilnius City Municipality (stops.lt)",
        dataURL: "https://www.stops.lt/vilnius/vilnius/",
        gpsURL: "https://www.stops.lt/vilnius/gps_full.txt",
        departures: .vehicles("https://www.stops.lt/vilnius/departures2.php"),
        timeZone: TimeZone(identifier: "Europe/Vilnius")!,
        mapCity: "vilnius",
        mapTransports: ["commercialbus": "bus", "autonomous": "bus"]
    ))

    static let kaunas = PikasProvider(city: City(
        id: "kaunas",
        displayName: "stops.lt (Kaunas)",
        attribution: "Data: Kauno autobusai / Kaunas City Municipality (stops.lt)",
        dataURL: "https://www.stops.lt/kaunas/kaunas/",
        gpsURL: "https://www.stops.lt/kaunas/gps_full.txt",
        departures: .vehicles("https://www.stops.lt/kaunas/departures2.php"),
        timeZone: TimeZone(identifier: "Europe/Vilnius")!,
        mapCity: "kaunas",
        mapTransports: ["expressbus": "bus"]
    ))

    // MARK: - Stops and lines

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let index = try await index()
        let needle = query.lowercased()
        if let id = index.stops[needle] != nil ? needle : index.stopBySiri[needle], let stop = index.stops[id] {
            return [stop.stop]
        }
        return PikasNameSearch.match(query, in: index.stops.values.map(\.stop))
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let index = try await index()
        return index.lines(at: stop.code).map { index.line(for: $0) }
    }

    /// Everything local: the stops file has coordinates, the routes file which lines stop there.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let index = try await index()
        let latSpan = radiusMeters / 111_320
        let lonSpan = latSpan / max(cos(point.lat * .pi / 180), 0.01)
        return index.stops.values
            .filter { abs($0.lat - point.lat) <= latSpan && abs($0.lon - point.lon) <= lonSpan }
            .map { ($0, RouteGeometry.meters(point, $0.stop.location)) }
            .filter { $0.1 <= radiusMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(15)
            .compactMap { stop, distance in
                let lines = index.lines(at: stop.id).map { index.line(for: $0) }
                return lines.isEmpty ? nil : NearbyStop(stop: stop.stop, distanceMeters: distance, lines: lines)
            }
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let index = try await index()
        guard let variant = index.variantByLineID[line.id].map({ index.variants[$0] }) else {
            throw TransitError.notFound("route variant \(line.id)")
        }
        let stops = variant.stopIDs.compactMap { index.stops[$0]?.stop }
        return RoutePattern(
            line: line,
            stops: stops.enumerated().map { PatternStop(stop: $1, sequence: $0 + 1, distanceAlongRoute: nil) }
        )
    }

    /// The sites draw their maps from one small file per route number (`{city}_{transport}_{num}.txt`,
    /// 1–3 KB gzipped) holding every variant: records of three lines, the variant type, its path as
    /// a Google polyline (precision 5), and a per-vertex flag string. Each stop is a vertex. One
    /// file serves both directions, so it is kept ten minutes for the other one's card.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        let parts = line.id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let transport = line.providerRefs["transport"] ?? parts.first,
              let type = line.providerRefs["type"] ?? parts.last?.split(separator: "#").first.map(String.init) else {
            throw TransitError.unsupported("line \(line.id) has no route type (was it loaded from another provider?)")
        }
        let file = Self.mapFile(city: city, transport: transport, number: line.shortName)
        let records = try await Self.mapFiles.value(city.dataURL + file, ttl: .seconds(600)) { [city] in
            Self.mapRecords(try await PikasHTTP.text(city.dataURL + file, timeout: 20, missing: .notFound("map file \(file)")))
        }
        guard let encoded = records[type.lowercased()] else {
            throw TransitError.notFound("variant \(type) in \(file)")
        }
        return RouteShape(try Polyline.decode(encoded))
    }

    /// As the sites' `pg.loadPolyline` names it: lowercase ASCII without spaces, `*` as `@`. The
    /// number keeps a dated variant's suffix (`kaunas_bus_43p(10.22).txt`), whose brackets the
    /// server only finds percent-encoded.
    static func mapFile(city: City, transport: String, number: String) -> String {
        let transport = city.mapTransports[transport.lowercased()] ?? transport
        let name = "\(city.mapCity)_\(transport)_\(number)"
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "*", with: "@")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.@")
        return (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name) + ".txt"
    }

    /// Variant type (lowercased) → encoded polyline.
    static func mapRecords(_ text: String) -> [String: String] {
        // CRLF is one Character in Swift, so lines are split on `isNewline`, not on "\n".
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var records: [String: String] = [:]
        var index = 0
        while index + 1 < lines.count {
            let type = lines[index].lowercased()
            if records[type] == nil, !lines[index + 1].isEmpty { records[type] = lines[index + 1] }
            index += 3
        }
        return records
    }

    // MARK: - Live data

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let index = try await index()
        let ref = Ref(line)
        let text = try await PikasHTTP.text(city.gpsURL, timeout: 20)
        let now = Date()
        return PikasGPS.parse(text).compactMap { row in
            guard Pikas.family(row.transport) == ref.family,
                  row.route.caseInsensitiveCompare(ref.num) == .orderedSame,
                  index.isSameDirection(ref, directionType: row.directionType, destination: row.destination),
                  LiveCheck.valid(row.lat, row.lon) else { return nil }
            return VehiclePosition(
                location: GeoPoint(lat: row.lat, lon: row.lon),
                recordedAt: row.recordedSec.map { Pikas.date(secondsOfDay: $0, near: now, in: city.timeZone) },
                tripId: row.tripID,
                plateNumber: row.vehicle,
                bearing: row.bearing,
                speedKmh: row.speed,
                isAccessible: row.isLowFloor
            )
        }
    }

    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let index = try await index()
        let ref = Ref(line)
        let now = Date()
        let millis = String(Int(now.timeIntervalSince1970 * 1000))
        var arrivals: [Arrival] = []

        switch city.departures {
        case .siri(let url):
            guard let siri = index.stops[stop.code]?.siriID, !siri.isEmpty else {
                throw TransitError.notFound("SiriID of stop \(stop.code)")
            }
            let text = try await PikasHTTP.text(url + "?stopid=\(siri)&time=\(millis)", timeout: 20)
            // A stop served in one direction only takes every departure of the line; otherwise the
            // destination text has to name one of this direction's termini.
            let oneWay = index.lines(at: stop.code).filter { Ref(index.line(for: $0)).sameRoute(ref) }.count <= 1
            for row in Pikas.rows(text) where row.count >= 5 && row[0] != "stop" {
                guard Pikas.family(row[0]) == ref.family, row[1].caseInsensitiveCompare(ref.num) == .orderedSame,
                      let expected = Int(row[2]) else { continue }
                guard oneWay || index.isSameDirection(ref, directionType: nil, destination: row[4]) else { continue }
                let scheduled = Int(row[3])
                arrivals.append(Arrival(
                    expectedAt: Pikas.date(secondsOfDay: expected, near: now, in: city.timeZone),
                    scheduledAt: scheduled.map { Pikas.date(secondsOfDay: $0, near: now, in: city.timeZone) },
                    // The feed repeats the timetable where it has no prediction; only a moved time is
                    // provably live.
                    isRealtime: scheduled != expected
                ))
            }
        case .vehicles(let url):
            let text = try await PikasHTTP.text(url + "?stopid=\(stop.code)&time=\(millis)", timeout: 20)
            for row in Pikas.rows(text) where row.count >= 5 && row[0] != "stop" {
                guard Pikas.family(row[0]) == ref.family, row[1].caseInsensitiveCompare(ref.num) == .orderedSame,
                      Pikas.group(row[2]) == ref.group, let seconds = Int(row[3]) else { continue }
                // Every row is a trip with a vehicle already assigned: a live prediction.
                arrivals.append(Arrival(
                    expectedAt: Pikas.date(secondsOfDay: seconds, near: now, in: city.timeZone),
                    scheduledAt: nil,
                    isRealtime: true,
                    tripId: row.count > 5 && Int(row[5]) != nil ? row[5] : nil
                ))
            }
        }
        return arrivals.sorted { $0.expectedAt < $1.expectedAt }
    }

    // MARK: - Helpers

    private func index() async throws -> PikasIndex {
        let city = city
        return try await PikasIndexStore.shared.index(for: city.id) {
            async let stops = PikasHTTP.text(city.dataURL + "stops.txt", timeout: 30)
            async let routes = PikasHTTP.text(city.dataURL + "routes.txt", timeout: 30)
            return try PikasIndex(stopsText: await stops, routesText: await routes)
        }
    }

    /// Transport family, route number and direction group of a line — enough to recognise its
    /// vehicles and departures. Line ids are `transport:num:routeType`, the fallback when a line
    /// was cached without `providerRefs`.
    fileprivate nonisolated struct Ref {
        var family: String
        var num: String
        var group: String

        init(_ line: TransitLine) {
            let parts = line.id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            family = line.providerRefs["family"] ?? Pikas.family(parts.first ?? "bus")
            num = line.providerRefs["num"] ?? Pikas.liveNumber(parts.count > 1 ? parts[1] : line.shortName)
            group = line.providerRefs["group"] ?? Pikas.group(parts.last ?? "")
        }

        func sameRoute(_ other: Ref) -> Bool {
            family == other.family && num.caseInsensitiveCompare(other.num) == .orderedSame
        }
    }
}

// MARK: - Format helpers

private nonisolated enum Pikas {
    /// Buses of every kind (express, night, commercial, regional) run to one board; trolleybuses
    /// and trams have their own numbering. The vehicle feeds say "1"/"2"/"3" (Tallinn) or
    /// "Autobusai"/"Troleibusai" (stops.lt).
    static func family(_ transport: String) -> String {
        let t = transport.lowercased()
        if t == "1" || t.hasPrefix("trol") { return "trol" }
        if t == "3" || t.hasPrefix("tram") { return "tram" }
        if t.hasPrefix("ferry") || t.hasPrefix("train") || t == "festal" || t == "christmastrain" { return t }
        return "bus"
    }

    /// The number the live feeds use: special-date variants are published as "4P (09.27)", and
    /// their vehicles as plain "4P".
    static func liveNumber(_ num: String) -> String {
        guard let paren = num.firstIndex(of: "(") else { return num }
        return num[..<paren].trimmingCharacters(in: .whitespaces)
    }

    static func isRoad(_ transport: String) -> Bool {
        ["bus", "trol"].contains(family(transport))
    }

    /// Direction group of a variant type: the terminus letter, without the short-turn digits.
    /// "a-b", "a1-b" and "a-b1" all head for b; stops.lt writes "A>B".
    static func group(_ routeType: String) -> String {
        let normalized = routeType.lowercased().replacingOccurrences(of: ">", with: "-")
        let end = normalized.split(separator: "-").last.map(String.init) ?? normalized
        return end.filter(\.isLetter)
    }

    /// Depot runs ("a-d", "b-dp") end in the garage.
    static func isDepot(_ group: String) -> Bool { group == "d" || group == "dp" }

    /// Seconds after local midnight, on whichever day puts them closest to now (the service day
    /// runs past 24:00, and just after midnight a feed may still count from yesterday).
    static func date(secondsOfDay: Int, near now: Date, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var date = calendar.startOfDay(for: now).addingTimeInterval(TimeInterval(secondsOfDay))
        while date.timeIntervalSince(now) > 12 * 3600 { date.addTimeInterval(-86_400) }
        while now.timeIntervalSince(date) > 12 * 3600 { date.addTimeInterval(86_400) }
        return date
    }

    /// Comma-separated rows with trailing empty cells dropped.
    static func rows(_ text: String) -> [[String]] {
        text.split(whereSeparator: \.isNewline).map { line in
            var cells = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            while cells.last == "" { cells.removeLast() }
            return cells
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Lowercased like the sites' own `ti.toAscii(id, true, true)` for stop ids (which are ASCII).
    static func stopID(_ raw: some StringProtocol) -> String {
        raw.lowercased().replacingOccurrences(of: " ", with: "")
    }
}

private nonisolated enum LiveCheck {
    static func valid(_ lat: Double, _ lon: Double) -> Bool {
        (-90...90).contains(lat) && (-180...180).contains(lon) && !(lat == 0 && lon == 0)
    }
}

/// One vehicle from either GPS layout.
private nonisolated struct PikasGPS {
    var transport: String
    var route: String
    var lat: Double
    var lon: Double
    var speed: Double?
    var bearing: Double?
    var vehicle: String?
    var tripID: String?
    var directionType: String?
    var destination: String?
    var recordedSec: Int?
    var isLowFloor: Bool?

    /// Tallinn: `type,route,lon×1e6,lat×1e6,speed,heading,vehicle,lowFloor("Z"),?,destination`, no
    /// header and no timestamp. stops.lt: a header row naming the (Lithuanian) columns.
    static func parse(_ text: String) -> [PikasGPS] {
        let rows = Pikas.rows(text)
        guard let first = rows.first else { return [] }
        if first.contains("Marsrutas") {
            let col = Dictionary(first.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            func cell(_ row: [String], _ name: String) -> String? {
                guard let i = col[name], i < row.count, !row[i].isEmpty else { return nil }
                return row[i]
            }
            return rows.dropFirst().compactMap { row in
                guard let transport = cell(row, "Transportas"), let route = cell(row, "Marsrutas"),
                      let lon = cell(row, "Ilguma").flatMap(Double.init),
                      let lat = cell(row, "Platuma").flatMap(Double.init) else { return nil }
                return PikasGPS(
                    transport: transport, route: route, lat: lat / 1e6, lon: lon / 1e6,
                    speed: cell(row, "Greitis").flatMap(Double.init),
                    bearing: cell(row, "Azimutas").flatMap(Double.init).flatMap { $0 < 360 ? $0 : nil },
                    vehicle: cell(row, "MasinosNumeris"),
                    tripID: cell(row, "ReisoIdGTFS") ?? cell(row, "ReisoID"),
                    directionType: cell(row, "KryptiesTipas"),
                    destination: cell(row, "KryptiesPavadinimas"),
                    recordedSec: cell(row, "MatavimoLaikas").flatMap(Int.init)
                )
            }
        }
        return rows.compactMap { row in
            guard row.count >= 4, let lon = Double(row[2]), let lat = Double(row[3]) else { return nil }
            func cell(_ i: Int) -> String? { i < row.count && !row[i].isEmpty ? row[i] : nil }
            return PikasGPS(
                transport: row[0], route: row[1], lat: lat / 1e6, lon: lon / 1e6,
                speed: cell(4).flatMap(Double.init),
                bearing: cell(5).flatMap(Double.init).flatMap { $0 < 360 ? $0 : nil },
                vehicle: cell(6),
                destination: cell(9),
                isLowFloor: cell(7).map { $0 == "Z" }
            )
        }
    }
}

// MARK: - Network index (stops.txt + routes.txt)

private nonisolated struct PikasIndex: Sendable {
    struct Stop: Sendable {
        var id: String
        var siriID: String?
        var name: String
        var area: String?
        /// Vilnius and Kaunas fill it for most stops, Tallinn mostly outside the city.
        var street: String?
        var lat: Double
        var lon: Double

        var stop: TransitStop {
            TransitStop(code: id, name: name, city: area, location: GeoPoint(lat: lat, lon: lon), address: street)
        }
    }

    struct Variant: Sendable {
        var lineID: String
        var num: String
        var transport: String
        var family: String
        var routeType: String
        var group: String
        var name: String
        var operatorName: String?
        var stopIDs: [String]

        /// Pull-outs and pull-ins ("dp-a", "d-b", "b-d1"): a few trips a day to or from the garage.
        var isDepotRun: Bool {
            routeType.lowercased().split(separator: "-").contains { Pikas.isDepot($0.filter(\.isLetter)) }
        }

        /// Main variants first, then short turns ("a-b1"); longer first within each.
        var rank: (Int, Int) {
            (routeType.contains { $0.isNumber } ? 1 : 0, -stopIDs.count)
        }

        /// The terminus as the feeds' destination texts name it: the last part of the route name
        /// ("Kadriorg - Kopli", "Lazdynai–Grigiškės").
        var destinationName: String {
            // Hyphenated place names ("Vana-Pääsküla") only split at spaced dashes or long dashes.
            guard let dash = name.range(of: #"\s[-–—]\s|[–—]"#, options: [.regularExpression, .backwards]) else { return name }
            return String(name[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
    }

    var stops: [String: Stop]
    var stopBySiri: [String: String]
    var variants: [Variant]
    var variantByLineID: [String: Int]
    var variantsAtStop: [String: [Int]]

    init(stopsText: String, routesText: String) throws {
        let allStops = Self.parseStops(stopsText)
        variants = Self.parseRoutes(routesText).compactMap { variant in
            var variant = variant
            variant.stopIDs = variant.stopIDs.filter { allStops[$0] != nil }
            return variant.stopIDs.count >= 2 ? variant : nil
        }
        // stops.lt lists a timetable change ahead of time as a second route, "31 (nuo 09-23)"
        // ("from 23 Sept"); the live feeds only ever say "31", so the plain one is kept.
        let plain = Set(variants.map { "\($0.family)|\($0.num)" })
        variants.removeAll { variant in
            let base = Pikas.liveNumber(variant.num)
            return base != variant.num && plain.contains("\(variant.family)|\(base)")
        }
        guard !allStops.isEmpty, !variants.isEmpty else { throw TransitError.badResponse("empty Pikas network") }
        var byLine: [String: Int] = [:]
        var atStop: [String: [Int]] = [:]
        for (i, variant) in variants.enumerated() {
            byLine[variant.lineID] = byLine[variant.lineID] ?? i
            for stopID in Set(variant.stopIDs) { atStop[stopID, default: []].append(i) }
        }
        variantByLineID = byLine
        variantsAtStop = atStop
        // Only stops some bus or trolleybus calls at: drops the planner's area pseudo-stops and
        // tram-only platforms.
        stops = allStops.filter { atStop[$0.key] != nil }
        stopBySiri = Dictionary(
            stops.values.compactMap { stop in stop.siriID.map { ($0, stop.id) } },
            uniquingKeysWith: { a, _ in a }
        )
    }

    /// One variant per (route, direction) that picks up at the stop. Variants that only *end* here
    /// are dropped unless nothing else serves it, and so are depot runs: a stop that only sees a
    /// route on its way to the garage is not a stop to wait for that route at.
    func lines(at stopID: String) -> [Variant] {
        let serving = (variantsAtStop[stopID] ?? []).map { variants[$0] }
        let boarding = serving.filter { $0.stopIDs.last != stopID || $0.stopIDs.dropLast().contains(stopID) }
        var pool = boarding.isEmpty ? serving : boarding
        let regular = pool.filter { !$0.isDepotRun }
        if !regular.isEmpty { pool = regular }
        var best: [String: Variant] = [:]
        for variant in pool {
            let key = "\(variant.family)|\(variant.num)|\(variant.group)"
            if let current = best[key], current.rank <= variant.rank { continue }
            best[key] = variant
        }
        return best.values
            .sorted {
                if $0.num != $1.num { return $0.num.localizedStandardCompare($1.num) == .orderedAscending }
                if $0.family != $1.family { return $0.family < $1.family }
                return $0.group < $1.group
            }
    }

    func line(for variant: Variant) -> TransitLine {
        TransitLine(
            id: variant.lineID,
            shortName: variant.num,
            headsign: variant.destinationName,
            agency: variant.operatorName,
            origin: variant.stopIDs.first.flatMap { stops[$0]?.name },
            destination: variant.stopIDs.last.flatMap { stops[$0]?.name },
            providerRefs: ["family": variant.family, "num": Pikas.liveNumber(variant.num), "group": variant.group,
                           "transport": variant.transport, "type": variant.routeType]
        )
    }

    /// Whether a vehicle or departure belongs to the line's direction. stops.lt states the variant
    /// type ("A>B"); Tallinn only the destination text, matched against the termini of every
    /// variant in that direction.
    func isSameDirection(_ ref: PikasProvider.Ref, directionType: String?, destination: String?) -> Bool {
        if let directionType, !directionType.isEmpty { return Pikas.group(directionType) == ref.group }
        guard let destination, !destination.isEmpty else { return false }
        let wanted = Pikas.fold(destination)
        return variants.contains { variant in
            variant.family == ref.family && variant.group == ref.group
                && Pikas.liveNumber(variant.num).caseInsensitiveCompare(ref.num) == .orderedSame
                && (Pikas.fold(variant.destinationName) == wanted
                    || variant.stopIDs.last.flatMap { stops[$0] }.map { Pikas.fold($0.name) == wanted } == true)
        }
    }

    // MARK: Parsing

    /// Header-named columns; Tallinn has `SiriID`, stops.lt a `Direction` ("towards") instead.
    /// Coordinates are degrees × 1e5. Name, street, area and city repeat from the row above when
    /// empty.
    private static func parseStops(_ text: String) -> [String: Stop] {
        let lines = text.split(whereSeparator: \.isNewline)
        guard let header = lines.first else { return [:] }
        let col = columns(header)
        var name = "", area = "", city = "", street = ""
        var stops: [String: Stop] = [:]
        for line in lines.dropFirst() where line.count > 1 {
            let parts = line.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            func cell(_ key: String) -> String? {
                guard let i = col[key], i < parts.count, !parts[i].isEmpty else { return nil }
                return parts[i]
            }
            if let n = cell("CITY") { city = n == "0" ? "" : n.trimmingCharacters(in: .whitespaces) }
            if let n = cell("AREA") { area = n == "0" ? "" : n.trimmingCharacters(in: .whitespaces) }
            if let n = cell("NAME") { name = n == "0" ? "" : n.trimmingCharacters(in: .whitespaces) }
            // Carried over like the others: a blank cell means "same as the row above".
            if let n = cell("STREET") { street = n == "0" ? "" : n.trimmingCharacters(in: .whitespaces) }
            guard let rawID = parts.first, !rawID.isEmpty,
                  let lat = cell("LAT").flatMap(Double.init), let lon = cell("LNG").flatMap(Double.init),
                  lat != 0, lon != 0 else { continue }
            let id = Pikas.stopID(rawID)
            let siri = cell("SIRIID").flatMap { Int($0) != nil ? $0 : nil }
            // Kaunas fills the area column with bare numbers.
            let area = Int(area) == nil ? area : ""
            stops[id] = Stop(id: id, siriID: siri, name: name.isEmpty ? id : name,
                             area: area.isEmpty ? (city.isEmpty ? nil : city) : area,
                             street: street.isEmpty ? nil : street,
                             lat: lat / 1e5, lon: lon / 1e5)
        }
        return stops
    }

    /// Mirrors the sites' `ti.loadRoutes`: `#` rows are notices, `SpecialDates` rows are calendars,
    /// every other row is a variant followed by its encoded timetable row.
    private static func parseRoutes(_ text: String) -> [Variant] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
        guard let header = lines.first else { return [] }
        let col = columns(header)
        var num = "", authority = "", transport = "", name = "", operatorName = ""
        var variants: [Variant] = []
        var seen: [String: Int] = [:]
        var i = 1
        while i < lines.count {
            let line = lines[i]
            i += 1
            guard !line.hasPrefix("#"), line.count > 1 else { continue }
            let parts = line.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            func cell(_ key: String) -> String? {
                guard let index = key == "ROUTENUM" ? 0 : col[key], index < parts.count, !parts[index].isEmpty else { return nil }
                return parts[index]
            }
            if let n = cell("AUTHORITY") { authority = n == "0" ? "" : n }
            if authority == "SpecialDates" { continue }
            if let n = cell("ROUTENUM") { num = n == "-" ? "" : n }
            if let n = cell("ROUTENAME") { name = n }
            if let n = cell("TRANSPORT") { transport = n == "0" ? "" : n }
            if let n = cell("OPERATOR") { operatorName = n == "0" ? "" : n }
            i += 1   // the timetable row
            // "разв" marks a service-only variant the sites hide too.
            guard !num.contains("\u{0440}\u{0430}\u{0437}\u{0432}"), !num.isEmpty, Pikas.isRoad(transport),
                  let routeType = cell("ROUTETYPE"), let stopList = cell("ROUTESTOPS") else { continue }
            // "e"/"x" prefixes mark entry-only and exit-only calls; the stop is the same.
            let stopIDs = stopList.split(separator: ",").map { raw -> String in
                let id = Pikas.stopID(raw)
                return (id.hasPrefix("e") || id.hasPrefix("x")) && id.dropFirst().first?.isNumber == true
                    ? String(id.dropFirst()) : id
            }
            var lineID = "\(transport):\(num):\(routeType)"
            if let count = seen[lineID] { seen[lineID] = count + 1; lineID += "#\(count + 1)" } else { seen[lineID] = 1 }
            variants.append(Variant(
                lineID: lineID, num: num, transport: transport, family: Pikas.family(transport),
                routeType: routeType, group: Pikas.group(routeType), name: name,
                operatorName: operatorName.isEmpty ? nil : operatorName, stopIDs: stopIDs
            ))
        }
        return variants
    }

    private static func columns(_ header: some StringProtocol) -> [String: Int] {
        let names = header.replacingOccurrences(of: "\u{FEFF}", with: "").uppercased()
            .split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return Dictionary(names.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    }
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

/// The parsed network per city, loaded once per session. A failed load is forgotten so the next
/// call retries (stops.lt's origin drops out now and then).
private actor PikasIndexStore {
    static let shared = PikasIndexStore()
    private var tasks: [String: Task<PikasIndex, any Error>] = [:]

    func index(for city: String, load: @escaping @Sendable () async throws -> PikasIndex) async throws -> PikasIndex {
        if let task = tasks[city] { return try await task.value }
        let task = Task { try await load() }
        tasks[city] = task
        do { return try await task.value } catch { tasks[city] = nil; throw error }
    }
}

/// Plain-text GET. Cloudflare fronts both hosts; stops.lt answers 522 when its origin is down,
/// after ~20 s, hence the shorter timeout.
private nonisolated enum PikasHTTP {
    /// `missing` is thrown instead when the server has no such file (404).
    static func text(_ urlString: String, timeout: TimeInterval, missing: TransitError? = nil) async throws -> String {
        guard let url = URL(string: urlString) else { throw TransitError.badResponse("invalid URL \(urlString)") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("BusBus-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 404, let missing { throw missing }
        guard (200..<300).contains(status) else {
            throw TransitError.badResponse("HTTP \(status) for \(url.lastPathComponent)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Case- and accent-insensitive "every word appears in the name", exact and prefix matches first.
private nonisolated enum PikasNameSearch {
    static func match(_ query: String, in stops: [TransitStop], limit: Int = 40) -> [TransitStop] {
        let needle = Pikas.fold(query)
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return stops
            .compactMap { stop -> (TransitStop, Int)? in
                let name = Pikas.fold(stop.name)
                guard words.allSatisfy(name.contains) else { return nil }
                return (stop, name == needle ? 0 : name.hasPrefix(needle) ? 1 : 2)
            }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : ($0.0.name, $0.0.code) < ($1.0.name, $1.0.code) }
            .prefix(limit)
            .map(\.0)
    }
}
