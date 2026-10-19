import Foundation

/// Japan, Tokyo — Toei Bus (Bureau of Transportation, Tokyo Metropolitan Government) through the
/// ODPT public API (api-public.odpt.org), official and keyless. Only Toei is served on the
/// token-free host; every other ODPT operator needs a developer token that may not be shipped.
///
/// - Positions: the fleet-wide GTFS-RT VehiclePosition feed (~20-40 KB of protobuf, refreshed
///   every ~30 s), read by the small decoder at the bottom of this file. Its trip ids are
///   `{pattern}-{direction}-…`, the same numbers as the ODPT route pattern ids, which is how a
///   bus is matched to a line.
/// - Arrivals: ODPT publishes no predictions. The stop timetable gives the schedule; for buses on
///   the road, `odpt:Bus` says which stop each one last passed and when, and that trip's own
///   timetable turns this into a delay carried forward to the rider's stop. Only those are marked
///   realtime.
/// - Filters that take several values (`owl:sameAs=a,b`) accept at most 10, hence the chunking.
/// - No published rate limit; responses are gzip'd and `Cache-Control: max-age=3600` on static data.
///
/// Licence: CC BY 4.0 for every Toei bus dataset (ckan.odpt.org), crediting "東京都交通局・公共交通
/// オープンデータ協議会" / "Bureau of Transportation, Tokyo Metropolitan Government / Association
/// for Open Data of Public Transportation".
nonisolated struct ToeiBusProvider: TransitProvider {
    let id = "odpt-toei"
    let displayName = "Toei Bus (Tokyo)"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .scheduledArrivals, .nearbyStops, .routeShape,
    ]
    /// Both `odpt:Bus` and the GTFS-RT feed are regenerated every 30 s (`odpt:frequency`).
    let suggestedRefreshInterval: Duration = .seconds(30)

    var http = HTTPClient()

    private static let base = "https://api-public.odpt.org/api/v4"
    private static let timeZone = TimeZone(identifier: "Asia/Tokyo")!
    private static let polePrefix = "odpt.BusstopPole:Toei."

    /// Names are published in Japanese and (for stops) English. Japanese readers get Japanese,
    /// everyone else English. Resolved per call, since the app language can change at any time.
    static var language: String { AppLanguage.locale.language.languageCode?.identifier == "ja" ? "ja" : "en" }
    private var language: String { Self.language }

    /// Cached lines and patterns carry names, so each language is its own dataset.
    var datasetID: String { "\(id).\(language)" }

    /// A shape has no names in it.
    var shapeDatasetID: String { id }

    /// Poles are kerbside, but a line's first or last pole often stands inside a terminal or depot
    /// while the drawn line ends on the street: 30 of the 748 patterns checked had one end 50–190 m
    /// off (Higashi43.40408.1: 190 m).
    var shapeTolerance: ShapeTolerance { ShapeTolerance(stops: 50, ends: 200) }

    var attribution: String? {
        language == "ja"
            ? "東京都交通局・公共交通オープンデータ協議会 (CC BY 4.0)"
            : "Bureau of Transportation, Tokyo Metropolitan Government / Association for Open Data of Public Transportation (CC BY 4.0)"
    }

    // MARK: - Stops

    /// ODPT only matches exact titles, so search runs over the full pole list, fetched once.
    /// A number finds every pole of that stop ("442"); a pole code ("KinshichoStation.442.2") itself.
    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let index = try await poleIndex()
        let language = language
        if let pole = index[Self.polePrefix + query] { return [pole.stop(language, platform: true)] }
        if query.allSatisfy(\.isASCII), query.allSatisfy(\.isNumber) {
            let hits = index.values.filter { $0.stopNumber == Int(query) }
            if !hits.isEmpty { return hits.map { $0.stop(language, platform: true) }.sorted { $0.name < $1.name } }
        }
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
        let needle = fold(query)
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        return index.values
            .compactMap { pole -> (DTO.Pole, Int)? in
                let names = [pole.title?.ja ?? pole.dcTitle, pole.title?.en, pole.kana].compactMap { $0 }.map(fold)
                guard let name = names.first(where: { name in words.allSatisfy(name.contains) }) else { return nil }
                return (pole, name == needle ? 0 : name.hasPrefix(needle) ? 1 : 2)
            }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.sameAs < $1.0.sameAs }
            .prefix(40)
            .map { $0.0.stop(language, platform: true) }
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let pole = try await poles([Self.polePrefix + stop.code]).first
        guard let pole else { throw TransitError.notFound("stop \(stop.code)") }
        return try await servingLines(poles: [pole])[pole.sameAs] ?? []
    }

    /// `places/odpt:BusstopPole` is a true radius query; lines come from the patterns it lists.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let found = try await http.get(
            [DTO.Pole].self, Self.base, "/places/odpt:BusstopPole",
            query: ["lat": String(point.lat), "lon": String(point.lon), "radius": String(Int(min(radiusMeters, 4_000)))]
        )
        let nearest = found
            .filter { $0.location != nil }
            .sorted { RouteGeometry.meters(point, $0.location!) < RouteGeometry.meters(point, $1.location!) }
            .prefix(15)
        let lines = try await servingLines(poles: Array(nearest))
        let language = language
        return nearest.compactMap { pole in
            guard let served = lines[pole.sameAs], !served.isEmpty, let location = pole.location else { return nil }
            return NearbyStop(stop: pole.stop(language, platform: true),
                              distanceMeters: RouteGeometry.meters(point, location), lines: served)
        }
    }

    // MARK: - Lines

    /// A line is the representative (longest) pattern; `providerRefs["patterns"]` lists every
    /// pattern folded into it — variants of the same route and terminus starting elsewhere.
    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        guard let pattern = try await patterns([line.id]).first else { throw TransitError.notFound("pattern \(line.id)") }
        let order = pattern.stops.sorted { $0.index < $1.index }
        let byID = Dictionary(try await poles(order.map(\.pole)).map { ($0.sameAs, $0) }, uniquingKeysWith: { a, _ in a })
        let language = language
        let stops = order.compactMap { entry -> PatternStop? in
            guard let pole = byID[entry.pole], pole.location != nil else { return nil }
            return PatternStop(stop: pole.stop(language, platform: false), sequence: entry.index, distanceAlongRoute: nil)
        }
        guard stops.count >= 2 else { throw TransitError.notFound("stops for pattern \(line.id)") }
        return RoutePattern(line: line, stops: stops)
    }

    /// The pattern reply already carries the line's path (`ug:region`), so the shape costs nothing.
    /// A pattern without one gives an empty shape, kept so the card does not ask again.
    func routePatternWithShape(for line: TransitLine) async throws -> (pattern: RoutePattern, shape: RouteShape?) {
        let pattern = try await routePattern(for: line)
        let found = try await patterns([line.id]).first
        return (pattern, found.map { shape($0, stops: pattern) ?? RouteShape(branches: []) })
    }

    /// For a pattern that was cached before its shape was: the session's copy of the pattern reply,
    /// or that one request again.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        guard let found = try await patterns([line.id]).first, let shape = shape(found, stops: pattern) else {
            throw TransitError.notFound("path of pattern \(line.id)")
        }
        return shape
    }

    /// The path as published, or turned round when only that way do the stops fall along it in
    /// order: 5 of the 748 patterns are stored backwards (Tan96.1712.2, Shuku91.24305.*…). Nine
    /// patterns have no path: nil, and `routeShape` says `notFound`, which the cache keeps.
    private func shape(_ pattern: DTO.Pattern, stops: RoutePattern) -> RouteShape? {
        let line = pattern.region?.points ?? []
        let points = stops.stops.map(\.stop.location)
        let forward = RouteShape(line, version: pattern.date)
        guard !forward.isEmpty else { return nil }
        guard !ShapeCheck.verdict(forward, stops: points, tolerance: shapeTolerance).passes else { return forward }
        let backward = RouteShape(line.reversed(), version: pattern.date)
        return ShapeCheck.verdict(backward, stops: points, tolerance: shapeTolerance).passes ? backward : forward
    }

    // MARK: - Live

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let prefixes = Ref(line).patterns.map(Self.tripPrefix)
        let data = try await Self.fetch(Self.base + "/gtfs/realtime/ToeiBus")
        return try GTFSRealtime.vehicles(data)
            .filter { v in prefixes.contains { v.tripID.hasPrefix($0) } }
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

    /// The stop timetable for the day, with the trips already on the road re-timed by how late
    /// they passed their last stop. Trips that have already passed the rider are dropped.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let ref = Ref(line)
        let poleID = Self.polePrefix + stop.code
        let now = Date()
        async let scheduled = scheduledTimes(ref, pole: poleID, now: now)
        async let live = liveArrivals(ref, pole: poleID, now: now)
        let (plan, (predicted, gone)) = try await (scheduled, live)

        let covered = predicted.compactMap(\.scheduledAt) + gone
        let timetable = plan
            .filter { time in time >= now && !covered.contains { abs($0.timeIntervalSince(time)) < 30 } }
            .map { Arrival(expectedAt: $0, scheduledAt: $0, isRealtime: false) }
        return (predicted + timetable)
            .filter { $0.expectedAt >= now.addingTimeInterval(-60) }
            .sorted { $0.expectedAt < $1.expectedAt }
            .prefix(12)
            .map { $0 }
    }

    // MARK: - Helpers

    /// Scheduled passing times of the line's patterns at the pole, across yesterday's service
    /// (after-midnight trips), today's and tomorrow's.
    private func scheduledTimes(_ ref: Ref, pole: String, now: Date) async throws -> [Date] {
        let calendars = try await ToeiCache.shared.calendars {
            try await http.get([DTO.Calendar].self, Self.base, "/odpt:Calendar", query: [:])
        }
        var tables: [DTO.PoleTimetable] = []
        for route in Set(ref.routes) {
            tables += try await ToeiCache.shared.poleTimetables(key: "\(pole)|\(route)") {
                try await http.get([DTO.PoleTimetable].self, Self.base, "/odpt:BusstopPoleTimetable",
                                   query: ["odpt:busstopPole": pole, "odpt:busroute": route])
            }
        }
        let patterns = Set(ref.patterns)
        var times: [Date] = []
        for day in ServiceDay.around(now) {
            for table in tables where Self.runs(table.calendar, on: day, calendars: calendars) {
                for entry in table.entries where patterns.contains(entry.pattern ?? "") {
                    if let time = day.date(entry.departureTime, midnight: entry.isMidnight) { times.append(time) }
                }
            }
        }
        // The same departure can be listed under more than one of the pole's timetables.
        return Set(times).sorted()
    }

    /// Buses of the line now on the road that have yet to reach the pole, each re-timed by the
    /// delay at the stop it last passed; plus the scheduled times of those already past it.
    private func liveArrivals(_ ref: Ref, pole: String, now: Date) async throws -> ([Arrival], [Date]) {
        let patterns = Set(ref.patterns)
        var buses: [DTO.Bus] = []
        for route in Set(ref.routes) {
            buses += try await http.get([DTO.Bus].self, Self.base, "/odpt:Bus", query: ["odpt:busroute": route])
        }
        buses = buses.filter { patterns.contains($0.pattern ?? "") && $0.timetable != nil }
        guard !buses.isEmpty else { return ([], []) }
        let trips = Dictionary(try await tripTimetables(buses.compactMap(\.timetable)).map { ($0.sameAs, $0) },
                               uniquingKeysWith: { a, _ in a })

        var predicted: [Arrival] = []
        var gone: [Date] = []
        for bus in buses {
            guard let trip = bus.timetable.flatMap({ trips[$0] }) else { continue }
            let stops = trip.entries.sorted { $0.index < $1.index }
            guard let target = stops.first(where: { $0.pole == pole }) else { continue }
            guard let passedPole = bus.fromPole, let passedAt = bus.fromTime.flatMap(DTO.parseDate),
                  let passed = stops.first(where: { $0.pole == passedPole }),
                  let passedPlan = ServiceDay.nearest(passed.departureTime ?? passed.arrivalTime, midnight: passed.isMidnight, to: passedAt),
                  let targetPlan = ServiceDay.nearest(target.arrivalTime ?? target.departureTime, midnight: target.isMidnight, to: passedPlan)
            else { continue }
            if target.index <= passed.index { gone.append(targetPlan); continue }
            // Toei buses do not run ahead of the timetable, and a delay of hours means a stale match.
            let delay = max(0, passedAt.timeIntervalSince(passedPlan))
            guard delay < 2 * 3600 else { continue }
            predicted.append(Arrival(
                expectedAt: max(targetPlan.addingTimeInterval(delay), now),
                scheduledAt: targetPlan,
                isRealtime: true,
                tripId: trip.sameAs.components(separatedBy: ".").last
            ))
        }
        return (predicted, gone)
    }

    /// Lines at each pole: its patterns, grouped by route name and terminus, keeping patterns
    /// that only end there only when nothing else serves the pole.
    private func servingLines(poles: [DTO.Pole]) async throws -> [String: [TransitLine]] {
        let all = try await patterns(Array(Set(poles.flatMap { $0.patterns ?? [] })))
        let byID = Dictionary(all.map { ($0.sameAs, $0) }, uniquingKeysWith: { a, _ in a })
        let ends = Set(all.flatMap { p in [p.stops.min { $0.index < $1.index }?.pole, p.stops.max { $0.index < $1.index }?.pole].compactMap { $0 } })
        let names = Dictionary(try await self.poles(Array(ends)).map { ($0.sameAs, $0) }, uniquingKeysWith: { a, _ in a })
        let language = language

        var result: [String: [TransitLine]] = [:]
        for pole in poles {
            let serving = (pole.patterns ?? []).compactMap { byID[$0] }.filter { p in p.stops.contains { $0.pole == pole.sameAs } }
            let boarding = serving.filter { p in p.stops.max { $0.index < $1.index }?.pole != pole.sameAs }
            let groups = Dictionary(grouping: boarding.isEmpty ? serving : boarding) { p in
                "\(p.shortName(language))|\(p.stops.max { $0.index < $1.index }?.pole ?? "")"
            }
            result[pole.sameAs] = groups.values
                .map { group -> TransitLine in
                    let main = group.max { ($0.stops.count, $1.sameAs) < ($1.stops.count, $0.sameAs) }!
                    let order = main.stops.sorted { $0.index < $1.index }
                    let name = { (entry: DTO.PatternStop?) -> String? in
                        guard let entry else { return nil }
                        return names[entry.pole]?.name(language) ?? entry.note
                    }
                    let destination = name(order.last)
                    return TransitLine(
                        id: main.sameAs,
                        shortName: main.shortName(language),
                        headsign: destination,
                        agency: language == "ja" ? "都営バス" : "Toei Bus",
                        origin: name(order.first),
                        destination: destination,
                        providerRefs: ["patterns": group.map(\.sameAs).sorted().joined(separator: ","),
                                       "routes": Set(group.compactMap(\.route)).sorted().joined(separator: ",")]
                    )
                }
                .sorted {
                    let order = $0.shortName.localizedStandardCompare($1.shortName)
                    return order != .orderedSame ? order == .orderedAscending : $0.id < $1.id
                }
        }
        return result
    }

    /// Route patterns by id, 10 per request, cached for the session (~2-20 KB each with its shape).
    private func patterns(_ ids: [String]) async throws -> [DTO.Pattern] {
        try await ToeiCache.shared.patterns(ids) { missing in
            try await chunked(missing) { chunk in
                try await http.get([DTO.Pattern].self, Self.base, "/odpt:BusroutePattern",
                                   query: ["owl:sameAs": chunk.joined(separator: ",")])
            }
        }
    }

    /// Trip timetables by id, 10 per request, cached for the session (~1.5 KB each).
    private func tripTimetables(_ ids: [String]) async throws -> [DTO.TripTimetable] {
        try await ToeiCache.shared.trips(ids) { missing in
            try await chunked(missing) { chunk in
                try await http.get([DTO.TripTimetable].self, Self.base, "/odpt:BusTimetable",
                                   query: ["owl:sameAs": chunk.joined(separator: ",")])
            }
        }
    }

    /// Poles by id: from the full list when it is already loaded or the ask is large, otherwise
    /// 10 per request.
    private func poles(_ ids: [String]) async throws -> [DTO.Pole] {
        let loaded = await ToeiCache.shared.hasPoleIndex
        if ids.count > 30 || loaded {
            let index = try await poleIndex()
            return ids.compactMap { index[$0] }
        }
        return try await chunked(ids) { chunk in
            try await http.get([DTO.Pole].self, Self.base, "/odpt:BusstopPole", query: ["owl:sameAs": chunk.joined(separator: ",")])
        }
    }

    /// Every Toei pole (~3,700; 5.6 MB of JSON, ~430 KB gzipped), fetched once per session.
    private func poleIndex() async throws -> [String: DTO.Pole] {
        try await ToeiCache.shared.poleIndex {
            let all = try await http.get([DTO.Pole].self, Self.base, "/odpt:BusstopPole",
                                         query: ["odpt:operator": "odpt.Operator:Toei"])
            return Dictionary(all.filter { $0.location != nil }.map { ($0.sameAs, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    private func chunked<T: Sendable>(_ ids: [String], _ load: @escaping @Sendable ([String]) async throws -> [T]) async throws -> [T] {
        let unique = Array(Set(ids)).sorted()
        let chunks = stride(from: 0, to: unique.count, by: 10).map { Array(unique[$0..<min($0 + 10, unique.count)]) }
        return try await withThrowingTaskGroup(of: [T].self) { group in
            for chunk in chunks { group.addTask { try await load(chunk) } }
            var all: [T] = []
            for try await part in group { all += part }
            return all
        }
    }

    /// GTFS-RT trip ids begin with the ODPT pattern number and direction: pattern
    /// `odpt.BusroutePattern:Toei.To07.60101.1` runs trips `60101-1-…`.
    private static func tripPrefix(_ pattern: String) -> String {
        let parts = pattern.split(separator: ".")
        guard parts.count >= 2 else { return pattern }
        return "\(parts[parts.count - 2])-\(parts[parts.count - 1])-"
    }

    /// Toei calendars are `Specific.Toei.*` with explicit dates (holidays included); the generic
    /// weekday ones are approximated from the day of the week.
    private static func runs(_ calendar: String?, on day: ServiceDay, calendars: [String: Set<String>]) -> Bool {
        guard let calendar else { return false }
        if let days = calendars[calendar], !days.isEmpty { return days.contains(day.ymd) }
        let weekday = day.weekday   // 1 = Sunday
        switch calendar.replacingOccurrences(of: "odpt.Calendar:", with: "") {
        case "Everyday": return true
        case "Weekday": return (2...6).contains(weekday)
        case "Saturday": return weekday == 7
        case "Sunday", "Holiday": return weekday == 1
        case "SaturdayHoliday": return weekday == 1 || weekday == 7
        default: return false
        }
    }

    /// GET of a binary body (the JSON client only decodes JSON).
    private static func fetch(_ url: String) async throws -> Data {
        guard let url = URL(string: url) else { throw TransitError.badResponse("invalid URL \(url)") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("BusBus-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTPClient.check(data, response, request, url.path)
        return data
    }

    /// The patterns and routes a line stands for; a line cached without refs is its own pattern.
    private nonisolated struct Ref {
        var patterns: [String]
        var routes: [String]

        init(_ line: TransitLine) {
            patterns = line.providerRefs["patterns"].map { $0.split(separator: ",").map(String.init) } ?? [line.id]
            routes = line.providerRefs["routes"].map { $0.split(separator: ",").map(String.init) } ?? []
            if routes.isEmpty {
                // odpt.BusroutePattern:Toei.To07.60101.1 → odpt.Busroute:Toei.To07
                let parts = line.id.replacingOccurrences(of: "odpt.BusroutePattern:", with: "").split(separator: ".")
                routes = ["odpt.Busroute:" + parts.dropLast(2).joined(separator: ".")]
            }
        }
    }

    /// A service day in Tokyo time. Timetable clock times belong to one; `isMidnight` (or an
    /// hour past 23) moves a time onto the next calendar day.
    private nonisolated struct ServiceDay {
        var start: Date
        var ymd: String
        var weekday: Int

        static var calendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = ToeiBusProvider.timeZone
            return calendar
        }

        init(_ date: Date) {
            let calendar = Self.calendar
            start = calendar.startOfDay(for: date)
            let c = calendar.dateComponents([.year, .month, .day, .weekday], from: start)
            ymd = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            weekday = c.weekday ?? 1
        }

        static func around(_ now: Date) -> [ServiceDay] {
            let calendar = Self.calendar
            return [-1, 0, 1].compactMap { calendar.date(byAdding: .day, value: $0, to: now) }.map(ServiceDay.init)
        }

        func date(_ clock: String?, midnight: Bool?) -> Date? {
            guard let clock else { return nil }
            let parts = clock.split(separator: ":").compactMap { Int($0) }
            guard parts.count >= 2 else { return nil }
            var hour = parts[0]
            if midnight == true, hour < 12 { hour += 24 }
            return Self.calendar.date(byAdding: .minute, value: hour * 60 + parts[1], to: start)
        }

        /// The clock time on whichever of the three service days around `reference` lands closest.
        static func nearest(_ clock: String?, midnight: Bool?, to reference: Date) -> Date? {
            around(reference).compactMap { $0.date(clock, midnight: midnight) }
                .min { abs($0.timeIntervalSince(reference)) < abs($1.timeIntervalSince(reference)) }
        }
    }
}

/// Session caches: the pole list, calendars, and the static pattern / timetable documents. Failed
/// loads are forgotten so the next call retries.
private actor ToeiCache {
    static let shared = ToeiCache()

    private var poleTask: Task<[String: DTO.Pole], any Error>?
    private var calendarTask: Task<[String: Set<String>], any Error>?
    private var patternStore: [String: DTO.Pattern] = [:]
    private var tripStore: [String: DTO.TripTimetable] = [:]
    private var poleTimetableStore: [String: [DTO.PoleTimetable]] = [:]

    var hasPoleIndex: Bool { poleTask != nil }

    func poleIndex(load: @escaping @Sendable () async throws -> [String: DTO.Pole]) async throws -> [String: DTO.Pole] {
        if let poleTask { return try await poleTask.value }
        let task = Task { try await load() }
        poleTask = task
        do { return try await task.value } catch { poleTask = nil; throw error }
    }

    /// Calendar id → dates it runs ("2026-09-22"); ~80 calendars, 115 KB of JSON.
    func calendars(load: @escaping @Sendable () async throws -> [DTO.Calendar]) async throws -> [String: Set<String>] {
        if let calendarTask { return try await calendarTask.value }
        let task = Task {
            Dictionary(try await load().map { ($0.sameAs, Set($0.days ?? [])) }, uniquingKeysWith: { a, _ in a })
        }
        calendarTask = task
        do { return try await task.value } catch { calendarTask = nil; throw error }
    }

    func patterns(_ ids: [String], load: @Sendable ([String]) async throws -> [DTO.Pattern]) async throws -> [DTO.Pattern] {
        let missing = ids.filter { patternStore[$0] == nil }
        if !missing.isEmpty { for p in try await load(missing) { patternStore[p.sameAs] = p } }
        return ids.compactMap { patternStore[$0] }
    }

    func trips(_ ids: [String], load: @Sendable ([String]) async throws -> [DTO.TripTimetable]) async throws -> [DTO.TripTimetable] {
        if tripStore.count > 2_000 { tripStore = [:] }
        let missing = ids.filter { tripStore[$0] == nil }
        if !missing.isEmpty { for t in try await load(missing) { tripStore[t.sameAs] = t } }
        return ids.compactMap { tripStore[$0] }
    }

    /// Up to ~150 KB per busy pole and route; kept for the session (timetables change quarterly).
    func poleTimetables(key: String, load: @Sendable () async throws -> [DTO.PoleTimetable]) async throws -> [DTO.PoleTimetable] {
        if let cached = poleTimetableStore[key] { return cached }
        if poleTimetableStore.count > 50 { poleTimetableStore = [:] }
        let tables = try await load()
        poleTimetableStore[key] = tables
        return tables
    }
}

// MARK: - Wire format (ODPT JSON-LD)

private nonisolated enum DTO {
    struct Titles: Decodable, Sendable {
        var ja: String?
        var en: String?
    }

    struct Pole: Decodable, Sendable {
        var sameAs: String
        var dcTitle: String?
        var title: Titles?
        var kana: String?
        var lat: Double?
        var lon: Double?
        var platformNumber: String?
        var poleNumber: String?
        var patterns: [String]?

        enum CodingKeys: String, CodingKey {
            case title
            case sameAs = "owl:sameAs", dcTitle = "dc:title", kana = "odpt:kana", lat = "geo:lat", lon = "geo:long"
            case platformNumber = "odpt:platformNumber", poleNumber = "odpt:busstopPoleNumber"
            case patterns = "odpt:busroutePattern"
        }

        var location: GeoPoint? { lat.flatMap { lat in lon.map { GeoPoint(lat: lat, lon: $0) } } }

        /// The stop number inside the id: `…KinshichoStation.442.2` → 442.
        var stopNumber: Int? {
            let parts = sameAs.split(separator: ".")
            return parts.count >= 2 ? Int(parts[parts.count - 2]) : nil
        }

        func name(_ language: String) -> String {
            let ja = title?.ja ?? dcTitle ?? sameAs
            return language == "ja" ? ja : (title?.en ?? ja)
        }

        /// Poles of one stop share a name; the platform number riders see on the pole tells them apart.
        func stop(_ language: String, platform: Bool) -> TransitStop {
            var name = name(language)
            if platform, let number = platformNumber ?? poleNumber, !number.isEmpty {
                name += language == "ja" ? " \(number)番のりば" : " (stop \(number))"
            }
            return TransitStop(code: String(sameAs.dropFirst("odpt.BusstopPole:Toei.".count)), name: name, city: nil,
                               location: location ?? GeoPoint(lat: 0, lon: 0))
        }
    }

    struct PatternStop: Decodable, Sendable {
        var index: Int
        var pole: String
        var note: String?
        enum CodingKeys: String, CodingKey { case index = "odpt:index", pole = "odpt:busstopPole", note = "odpt:note" }
    }

    struct Pattern: Decodable, Sendable {
        var sameAs: String
        var title: String?
        var route: String?
        var stops: [PatternStop]
        /// When the pattern was last published ("2026-09-03T03:08:13+09:00"): the shape's version.
        var date: String?
        var region: Region?
        enum CodingKeys: String, CodingKey {
            case sameAs = "owl:sameAs", title = "dc:title", route = "odpt:busroute", stops = "odpt:busstopPoleOrder"
            case date = "dc:date", region = "ug:region"
        }

        /// "都０１(T01) 渋谷駅前行" → "都01" in Japanese, "T01" elsewhere when Toei gives a Latin
        /// code; otherwise the Japanese name, which is what the bus shows.
        func shortName(_ language: String) -> String {
            let raw = (title ?? sameAs).split(separator: " ").first.map(String.init) ?? sameAs
            let name = raw.precomposedStringWithCompatibilityMapping   // full-width digits → ASCII
            guard let open = name.firstIndex(of: "("), let close = name.lastIndex(of: ")"), open < close else { return name }
            let latin = String(name[name.index(after: open)..<close])
            return language == "ja" || latin.isEmpty ? String(name[..<open]) : latin
        }
    }

    /// The pattern's path: a GeoJSON LineString of `[lon, lat]`, a vertex per bend. Anything else
    /// reads as no path rather than failing the pattern.
    struct Region: Decodable, Sendable {
        var points: [GeoPoint]

        enum CodingKeys: String, CodingKey { case coordinates }

        init(from decoder: any Decoder) throws {
            let pairs = (try? decoder.container(keyedBy: CodingKeys.self).decode([[Double]].self, forKey: .coordinates)) ?? []
            points = pairs.compactMap { $0.count >= 2 ? GeoPoint(lat: $0[1], lon: $0[0]) : nil }
        }
    }

    struct Calendar: Decodable, Sendable {
        var sameAs: String
        var days: [String]?
        enum CodingKeys: String, CodingKey { case sameAs = "owl:sameAs", days = "odpt:day" }
    }

    struct TimetableEntry: Decodable, Sendable {
        var departureTime: String?
        var isMidnight: Bool?
        var pattern: String?
        enum CodingKeys: String, CodingKey {
            case departureTime = "odpt:departureTime", isMidnight = "odpt:isMidnight", pattern = "odpt:busroutePattern"
        }
    }

    struct PoleTimetable: Decodable, Sendable {
        var calendar: String?
        var entries: [TimetableEntry]
        enum CodingKeys: String, CodingKey { case calendar = "odpt:calendar", entries = "odpt:busstopPoleTimetableObject" }
    }

    struct TripStop: Decodable, Sendable {
        var index: Int
        var pole: String
        var arrivalTime: String?
        var departureTime: String?
        var isMidnight: Bool?
        enum CodingKeys: String, CodingKey {
            case index = "odpt:index", pole = "odpt:busstopPole", arrivalTime = "odpt:arrivalTime"
            case departureTime = "odpt:departureTime", isMidnight = "odpt:isMidnight"
        }
    }

    struct TripTimetable: Decodable, Sendable {
        var sameAs: String
        var entries: [TripStop]
        enum CodingKeys: String, CodingKey { case sameAs = "owl:sameAs", entries = "odpt:busTimetableObject" }
    }

    /// One bus on the road: the pole it last passed and when, and the trip it is running.
    struct Bus: Decodable, Sendable {
        var pattern: String?
        var timetable: String?
        var fromPole: String?
        var fromTime: String?
        enum CodingKeys: String, CodingKey {
            case pattern = "odpt:busroutePattern", timetable = "odpt:busTimetable"
            case fromPole = "odpt:fromBusstopPole", fromTime = "odpt:fromBusstopPoleTime"
        }
    }

    /// ISO 8601 with the Tokyo offset: "2026-09-22T21:31:59+09:00".
    static func parseDate(_ string: String) -> Date? { ISO8601DateFormatter().date(from: string) }
}

// MARK: - GTFS-Realtime (just the VehiclePosition fields used here; Adelaide Metro reads it too)

nonisolated enum GTFSRealtime {
    struct Vehicle: Sendable {
        var tripID = ""
        var routeID: String?
        var directionID: Int?
        var lat = 0.0
        var lon = 0.0
        var bearing: Double?
        var speed: Double?
        var timestamp: UInt64?
        var label: String?
    }

    /// FeedMessage.entity(2) → FeedEntity.vehicle(4) → VehiclePosition { trip(1){trip_id(1),
    /// route_id(5), direction_id(6)}, position(2){latitude(1), longitude(2), bearing(3), speed(5)}, timestamp(5), vehicle(8).label(2) }.
    static func vehicles(_ data: Data) throws -> [Vehicle] {
        var result: [Vehicle] = []
        try Reader.each(data) { field, value in
            guard field == 2, case .bytes(let entity) = value else { return }
            try Reader.each(entity) { field, value in
                guard field == 4, case .bytes(let body) = value else { return }
                var v = Vehicle()
                try Reader.each(body) { field, value in
                    switch (field, value) {
                    case (1, .bytes(let trip)):
                        try Reader.each(trip) { f, v2 in
                            switch (f, v2) {
                            case (1, .bytes(let s)): v.tripID = String(decoding: s, as: UTF8.self)
                            case (5, .bytes(let s)): v.routeID = String(decoding: s, as: UTF8.self)
                            case (6, .varint(let d)): v.directionID = Int(d)
                            default: break
                            }
                        }
                    case (2, .bytes(let position)):
                        try Reader.each(position) { f, v2 in
                            guard case .fixed32(let bits) = v2 else { return }
                            let x = Double(Float(bitPattern: bits))
                            switch f {
                            case 1: v.lat = x
                            case 2: v.lon = x
                            case 3: v.bearing = x
                            case 5: v.speed = x
                            default: break
                            }
                        }
                    case (5, .varint(let t)): v.timestamp = t
                    case (8, .bytes(let descriptor)):
                        try Reader.each(descriptor) { f, v2 in if f == 2, case .bytes(let s) = v2 { v.label = String(decoding: s, as: UTF8.self) } }
                    default: break
                    }
                }
                if !v.tripID.isEmpty, v.lat != 0, v.lon != 0 { result.append(v) }
            }
        }
        return result
    }

    enum Value { case varint(UInt64), fixed64(UInt64), bytes(Data), fixed32(UInt32) }

    struct Reader {
        private let bytes: [UInt8]
        private var index = 0

        init(_ data: Data) { bytes = [UInt8](data) }

        private mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard index < bytes.count, shift < 64 else { throw TransitError.badResponse("truncated protobuf varint") }
                let byte = bytes[index]; index += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
        }

        private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, index + count <= bytes.count else { throw TransitError.badResponse("truncated protobuf field") }
            defer { index += count }
            return bytes[index..<index + count]
        }

        private static func little(_ slice: ArraySlice<UInt8>) -> UInt64 {
            slice.reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }

        static func each(_ data: Data, _ visit: (Int, Value) throws -> Void) throws {
            var reader = Reader(data)
            try reader.fields(visit)
        }

        mutating func fields(_ visit: (Int, Value) throws -> Void) throws {
            while index < bytes.count {
                let key = try varint()
                let field = Int(key >> 3)
                switch key & 7 {
                case 0: try visit(field, .varint(try varint()))
                case 1: try visit(field, .fixed64(Self.little(try take(8))))
                case 2: try visit(field, .bytes(Data(try take(Int(try varint())))))
                case 5: try visit(field, .fixed32(UInt32(Self.little(try take(4)))))
                default: throw TransitError.badResponse("unsupported protobuf wire type \(key & 7)")
                }
            }
        }
    }
}
