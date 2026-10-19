import Foundation

/// Umo IQ's "retro" NextBus public feed (retro.umoiq.com/service/publicJSONFeed) — the legacy
/// NextBus XML feed served as JSON. Keyless, one host for every agency still on it (`agencyList`:
/// TTC Toronto plus ~16 small US agencies), so the adapter is parametrised by agency tag and only the
/// agencies listed in `Agency` are wired up. See docs/research/worldwide-apis.md §7.7.
///
/// It is an unsupported legacy feed: Umo "reserves the right to terminate … at any time". The feed
/// document (rev 1.24) caps each IP at ~2 MB per 20 s and asks for polls no faster than every 10 s;
/// predictions stop at five per direction.
///
/// Shape of the data:
/// - A route has one stop list (`stop[]`, with the public `stopId` riders see on the pole) and many
///   directions: one "useForUI" direction per way plus short-turn/garage variants, all carrying a
///   `name` ("North", "South"). A line here is one route in one named way; vehicles and predictions
///   come tagged with whichever variant they run (`29_0_29A`), so they are matched by the way's
///   name, not by tag. `terse=true&verbose=true` returns every variant without the path geometry.
/// - There is no stop search and no proximity query. A number is looked up as a public stop id; a
///   name is matched against route titles (TTC routes are named after their streets) and then
///   against the stops of the few routes that match.
/// - JSON is a mechanical XML translation: every value is a string, and any element that occurs
///   once is an object instead of a one-element array.
nonisolated struct UmoNextBusProvider: TransitProvider {
    /// One agency on the feed. Each is a separate provider (and dataset) of its own.
    struct Agency: Sendable {
        var tag: String
        var displayName: String
        var shortName: String
        /// Whose copyright the feed's notice names ("All data copyright … <year>.").
        var copyrightHolder: String
        var timeZone: TimeZone

        static let ttc = Agency(
            tag: "ttc", displayName: "TTC (Toronto)", shortName: "TTC",
            copyrightHolder: "Toronto Transit Commission",
            timeZone: TimeZone(identifier: "America/Toronto")!
        )
    }

    var agency: Agency = .ttc
    var http = HTTPClient()

    var id: String { "umo-\(agency.tag)" }
    var displayName: String { agency.displayName }
    /// The feed's licence asks that its copyright notice be kept; this is the notice it sends.
    var attribution: String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = agency.timeZone
        return "All data copyright \(agency.copyrightHolder) \(calendar.component(.year, from: Date()))."
    }
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .routeShape,
    ]
    /// Upstream refreshes every ~10 s; a board poll is two small calls (≈3 KB), far inside the budget.
    let suggestedRefreshInterval: Duration = .seconds(20)

    private let base = "https://retro.umoiq.com/service/publicJSONFeed"
    /// Full route configs, with the paths, for the line card.
    private static let fullConfigs = Memo<DTO.Route>()
    /// Route configs fetched to answer a name search (~18 KB each).
    private static let maxRoutesPerSearch = 6

    // MARK: - Stops

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        if query.allSatisfy(\.isNumber) {
            if let stop = try await stop(publicID: query) { return [stop] }
            // Not a stop number: a route number lists that route's stops.
            let routes = try await routeList()
            guard routes.contains(where: { $0.tag == query }) else { return [] }
            return try await config(route: query).publicStops
        }
        // Routes are ranked by the query words in their title, a word counting less the more titles
        // share it ("st", "west" hardly narrow anything; "king" does).
        let words = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let routes = try await routeList().map { ($0.tag, Self.fold($0.title)) }
        let weight = Dictionary(uniqueKeysWithValues: Set(words).map { word in
            (word, 1 / Double(max(routes.count { $0.1.contains(word) }, 1)))
        })
        let ranked = routes
            .map { route in (route.0, Set(words).filter(route.1.contains).reduce(0) { $0 + weight[$1, default: 0] }) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.maxRoutesPerSearch)
            .map(\.0)
        let configs = try await withThrowingTaskGroup(of: DTO.Route.self) { group in
            for tag in ranked { group.addTask { try await config(route: tag) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        let cached = await UmoRouteCache.shared.loaded(agency: agency.tag)
        var seen = Set<String>()
        let candidates = (configs + cached).flatMap(\.publicStops).filter { seen.insert($0.code).inserted }
        return Self.match(query, in: candidates)
    }

    /// A public stop id, resolved through `predictions` (which names the routes and the stop tag)
    /// and the first route's config (which has the coordinates).
    private func stop(publicID: String) async throws -> TransitStop? {
        let response = try await feed(["command": "predictions", "stopId": publicID])
        guard response.error == nil, let first = response.predictions?.items.first else { return nil }
        let route = try await config(route: first.routeTag)
        return route.publicStops.first { $0.code == publicID }
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        // Which routes serve the stop, and the stop's tag on each.
        var served: [(route: String, stopTag: String)]
        if let tag = Self.tagOnly(stop.code) {
            served = await UmoRouteCache.shared.loaded(agency: agency.tag)
                .filter { $0.stop.items.contains { $0.tag == tag } }
                .map { ($0.tag, tag) }
        } else {
            let response = try await feed(["command": "predictions", "stopId": stop.code])
            if let error = response.error { throw TransitError.notFound("stop \(stop.code): \(error.content ?? "")") }
            served = (response.predictions?.items ?? []).map { ($0.routeTag, $0.stopTag) }
        }
        var seen = Set<String>()
        served = served.filter { seen.insert($0.route).inserted }
        let configs = try await withThrowingTaskGroup(of: (Int, DTO.Route).self) { group in
            for (index, entry) in served.enumerated() {
                group.addTask { (index, try await config(route: entry.route)) }
            }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        return served.indices.flatMap { index -> [TransitLine] in
            guard let route = configs[index] else { return [] }
            return route.ways(through: served[index].stopTag).map { line(route, $0) }
        }
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let ref = Ref(line)
        let route = try await config(route: ref.route)
        guard let direction = route.direction.items.first(where: { $0.tag == ref.direction }) else {
            throw TransitError.notFound("direction \(ref.direction) of route \(ref.route)")
        }
        let stops = route.stopsByTag
        let pattern = direction.stop.items.compactMap { stops[$0.tag]?.transitStop }
        return RoutePattern(
            line: line,
            stops: pattern.enumerated().map { PatternStop(stop: $1, sequence: $0 + 1, distanceAlongRoute: nil) }
        )
    }

    /// The variant's path from the full `routeConfig` (without `terse`): one call, 50–150 KB with
    /// no gzip offered and up to 30 s on a big route, so it is asked for only when a rider opens the
    /// line, never for the configs a stop or a search loads. Each `path` is the stretch between two
    /// timepoints, tagged `<dirTag>_<seq>_<from>_<to>` once for every variant that drives it; the
    /// variant's own stretches, in `seq` order, meet end to end and pass through its stops. The
    /// reply holds every direction's paths, so it is kept ten minutes: the other way's card, opened
    /// next, costs nothing.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        let ref = Ref(line)
        let route = try await Self.fullConfigs.value("\(agency.tag)|\(ref.route)", ttl: .seconds(600)) { [http, base, agency] in
            var http = http
            http.timeout = 60
            let response = try await http.get(DTO.Response.self, base, "",
                                              query: ["command": "routeConfig", "a": agency.tag, "r": ref.route, "verbose": "true"])
            guard let route = response.route else {
                throw TransitError.notFound("route \(ref.route): \(response.error?.content ?? "no config")")
            }
            return route
        }
        let points = route.path(of: ref.direction)
        guard points.count >= 2 else { throw TransitError.notFound("path of \(ref.direction)") }
        return RouteShape(points)
    }

    // MARK: - Live

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        let ref = Ref(line)
        async let configRequest = config(route: ref.route)
        let response = try await feed(["command": "vehicleLocations", "r": ref.route, "t": "0"])
        // A refusal (over the per-IP byte budget, feed down) is an HTTP 200 with only an `Error`;
        // read as a list it would say no bus is running.
        if let error = response.error { throw TransitError.badResponse(error.content ?? "vehicleLocations") }
        let variants = try await configRequest.variants(of: ref.direction, way: ref.way)
        let now = response.lastTime.flatMap { Double($0.time) }.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        return (response.vehicle?.items ?? []).compactMap { vehicle in
            guard let dirTag = vehicle.dirTag, variants.contains(dirTag),
                  let lat = Double(vehicle.lat), let lon = Double(vehicle.lon) else { return nil }
            let heading = vehicle.heading.flatMap(Double.init)
            return VehiclePosition(
                location: GeoPoint(lat: lat, lon: lon),
                recordedAt: vehicle.secsSinceReport.flatMap(Double.init).map { now.addingTimeInterval(-$0) },
                plateNumber: vehicle.id,
                bearing: heading.flatMap { $0 >= 0 ? $0 : nil },   // -4 means "unknown"
                speedKmh: vehicle.speedKmHr.flatMap(Double.init)
            )
        }
    }

    /// Predictions are GPS-based unless flagged `isScheduleBased`; the feed has no timetable time
    /// to put next to them.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        let ref = Ref(line)
        async let configRequest = config(route: ref.route)
        var query = ["command": "predictions"]
        if let tag = Self.tagOnly(stop.code) {
            query["r"] = ref.route
            query["s"] = tag
        } else {
            query["stopId"] = stop.code
            query["routeTag"] = ref.route
        }
        let response = try await feed(query)
        if let error = response.error { throw TransitError.badResponse(error.content ?? "predictions") }
        let variants = try await configRequest.variants(of: ref.direction, way: ref.way)
        return (response.predictions?.items ?? [])
            .filter { $0.routeTag == ref.route }
            .flatMap { $0.direction?.items ?? [] }
            .flatMap { $0.prediction?.items ?? [] }
            .compactMap { prediction -> Arrival? in
                guard variants.contains(prediction.dirTag ?? ref.direction),
                      let epoch = Double(prediction.epochTime) else { return nil }
                return Arrival(
                    expectedAt: Date(timeIntervalSince1970: epoch / 1000),
                    scheduledAt: nil,
                    isRealtime: prediction.isScheduleBased != "true",
                    tripId: prediction.tripTag
                )
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }

    // MARK: - Helpers

    private struct Ref {
        var route: String
        var direction: String
        var way: String

        init(_ line: TransitLine) {
            let parts = line.id.split(separator: "|", maxSplits: 1).map(String.init)
            route = line.providerRefs["route"] ?? parts.first ?? line.shortName
            direction = line.providerRefs["direction"] ?? (parts.count > 1 ? parts[1] : "")
            way = line.providerRefs["way"] ?? ""
        }
    }

    private func line(_ route: DTO.Route, _ direction: DTO.Direction) -> TransitLine {
        let stops = route.stopsByTag
        let tags = direction.stop.items
        return TransitLine(
            id: "\(route.tag)|\(direction.tag)",
            shortName: route.tag,
            headsign: direction.headsign,
            agency: agency.shortName,
            origin: tags.first.flatMap { stops[$0.tag]?.title },
            destination: tags.last.flatMap { stops[$0.tag]?.title },
            providerRefs: ["route": route.tag, "direction": direction.tag, "way": direction.way]
        )
    }

    private func config(route: String) async throws -> DTO.Route {
        try await UmoRouteCache.shared.route(agency: agency.tag, tag: route) {
            let response = try await feed(["command": "routeConfig", "r": route, "terse": "true", "verbose": "true"])
            guard let config = response.route else {
                throw TransitError.notFound("route \(route): \(response.error?.content ?? "no config")")
            }
            return config
        }
    }

    private func routeList() async throws -> [DTO.RouteSummary] {
        try await UmoRouteCache.shared.routeList(agency: agency.tag) {
            try await feed(["command": "routeList"]).routeSummaries?.items ?? []
        }
    }

    private func feed(_ query: [String: String]) async throws -> DTO.Response {
        var query = query
        query["a"] = agency.tag
        return try await http.get(DTO.Response.self, base, "", query: query)
    }

    /// Stops the feed gives no public id (terminal arrival points like "14316_ar") are addressed by tag.
    private static let tagPrefix = "tag:"
    fileprivate static func tagOnly(_ code: String) -> String? {
        code.hasPrefix(tagPrefix) ? String(code.dropFirst(tagPrefix.count)) : nil
    }
    fileprivate static func code(for stop: DTO.Stop) -> String { stop.stopId ?? tagPrefix + stop.tag }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Every query word appears in the stop name; exact and prefix matches first.
    private static func match(_ query: String, in stops: [TransitStop], limit: Int = 40) -> [TransitStop] {
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

/// Route configs and route lists, fetched once per session (they change with board periods, a few
/// times a year). A TTC route config is 10–25 KB; a full search touches at most six of them.
private actor UmoRouteCache {
    static let shared = UmoRouteCache()

    private var routes: [String: Task<DTO.Route, any Error>] = [:]
    private var lists: [String: Task<[DTO.RouteSummary], any Error>] = [:]
    private var done: [String: DTO.Route] = [:]

    func route(agency: String, tag: String, load: @escaping @Sendable () async throws -> DTO.Route) async throws -> DTO.Route {
        let key = "\(agency)|\(tag)"
        let task = routes[key] ?? Task { try await load() }
        routes[key] = task
        do {
            let route = try await task.value
            done[key] = route
            return route
        } catch {
            routes[key] = nil
            throw error
        }
    }

    func routeList(agency: String, load: @escaping @Sendable () async throws -> [DTO.RouteSummary]) async throws -> [DTO.RouteSummary] {
        let task = lists[agency] ?? Task { try await load() }
        lists[agency] = task
        do { return try await task.value } catch { lists[agency] = nil; throw error }
    }

    /// Configs already in hand, so a search also finds stops on routes the rider looked at before.
    func loaded(agency: String) -> [DTO.Route] {
        done.filter { $0.key.hasPrefix("\(agency)|") }.map(\.value)
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

// MARK: - Wire format

private nonisolated enum DTO {
    /// An XML element that may occur once (an object) or many times (an array).
    struct OneOrMany<T: Decodable & Sendable>: Decodable, Sendable {
        var items: [T]
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let many = try? container.decode([T].self) { items = many } else { items = [try container.decode(T.self)] }
        }
    }

    struct Response: Decodable, Sendable {
        var route: Route?
        var routeSummaries: OneOrMany<RouteSummary>?
        var predictions: OneOrMany<Predictions>?
        var vehicle: OneOrMany<Vehicle>?
        var lastTime: LastTime?
        var error: FeedError?

        enum CodingKeys: String, CodingKey { case route, predictions, vehicle, lastTime, error = "Error" }

        /// `routeList` and `routeConfig` both answer under `route`: a list of summaries for one, a
        /// single config object for the other.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let config = try? c.decode(Route.self, forKey: .route) {
                route = config
            } else {
                routeSummaries = try c.decodeIfPresent(OneOrMany<RouteSummary>.self, forKey: .route)
            }
            predictions = try c.decodeIfPresent(OneOrMany<Predictions>.self, forKey: .predictions)
            vehicle = try c.decodeIfPresent(OneOrMany<Vehicle>.self, forKey: .vehicle)
            lastTime = try c.decodeIfPresent(LastTime.self, forKey: .lastTime)
            // One `Error` is an object; several (a bad agency repeats it) an array.
            error = try c.decodeIfPresent(OneOrMany<FeedError>.self, forKey: .error)?.items.first
        }
    }

    struct FeedError: Decodable, Sendable { var content: String? }
    struct LastTime: Decodable, Sendable { var time: String }
    struct RouteSummary: Decodable, Sendable { var tag: String; var title: String }

    struct Route: Decodable, Sendable {
        var tag: String
        var title: String
        var stop: OneOrMany<Stop>
        var direction: OneOrMany<Direction>
        /// Only in a config asked for without `terse`.
        var path: OneOrMany<Path>?

        var stopsByTag: [String: Stop] {
            Dictionary(stop.items.map { ($0.tag, $0) }, uniquingKeysWith: { first, _ in first })
        }

        /// Stops a rider can look up: the ones with a public number.
        var publicStops: [TransitStop] { stop.items.filter { $0.stopId != nil }.compactMap(\.transitStop) }

        /// One direction per way ("North", "South") that stops at the tag: the UI direction when it
        /// does, else the longest variant that does (a stop only a branch serves).
        func ways(through stopTag: String) -> [Direction] {
            var order: [String] = []
            var best: [String: Direction] = [:]
            for direction in direction.items where direction.stop.items.contains(where: { $0.tag == stopTag }) {
                let way = direction.way
                guard let current = best[way] else { order.append(way); best[way] = direction; continue }
                let better = direction.isUI != current.isUI
                    ? direction.isUI
                    : direction.stop.items.count > current.stop.items.count
                if better { best[way] = direction }
            }
            return order.compactMap { best[$0] }
        }

        /// The direction's stretches joined in order. A stretch belongs to the longest direction tag
        /// its id starts with, since tags may contain "_" and one may extend another; what follows
        /// is the sequence number (stop tags after it can contain "_" too, so they are not read).
        func path(of directionTag: String) -> [GeoPoint] {
            let tags = direction.items.map(\.tag).sorted { $0.count > $1.count }
            var stretches: [(seq: Int, points: [GeoPoint])] = []
            for segment in path?.items ?? [] {
                for id in segment.tag.items.map(\.id) {
                    guard tags.first(where: { id.hasPrefix($0 + "_") }) == directionTag,
                          let seq = Int(id.dropFirst(directionTag.count + 1).prefix { $0 != "_" }) else { continue }
                    stretches.append((seq, segment.point.items.compactMap(\.geoPoint)))
                    break
                }
            }
            var joined: [GeoPoint] = []
            for stretch in stretches.sorted(by: { $0.seq < $1.seq }) {
                var points = stretch.points
                // Neighbouring stretches share their timepoint.
                if let last = joined.last, let first = points.first, ShapeCheck.meters(last, first) < 1 { points.removeFirst() }
                joined += points
            }
            return joined
        }

        /// Every direction tag running the same way as the line's, which is what vehicles and
        /// predictions are tagged with.
        func variants(of tag: String, way: String) -> Set<String> {
            let way = way.isEmpty ? direction.items.first { $0.tag == tag }?.way ?? tag : way
            return Set(direction.items.filter { $0.way == way }.map(\.tag)).union([tag])
        }
    }

    struct Stop: Decodable, Sendable {
        var tag: String
        var title: String
        var lat: String
        var lon: String
        var stopId: String?

        var transitStop: TransitStop? {
            guard let lat = Double(lat), let lon = Double(lon) else { return nil }
            return TransitStop(code: UmoNextBusProvider.code(for: self), name: title, city: nil,
                               location: GeoPoint(lat: lat, lon: lon))
        }
    }

    struct Path: Decodable, Sendable {
        struct Tag: Decodable, Sendable { var id: String }
        struct Point: Decodable, Sendable {
            var lat: String
            var lon: String
            var geoPoint: GeoPoint? { Double(lat).flatMap { lat in Double(lon).map { GeoPoint(lat: lat, lon: $0) } } }
        }
        var tag: OneOrMany<Tag>
        var point: OneOrMany<Point>
    }

    struct Direction: Decodable, Sendable {
        struct StopRef: Decodable, Sendable { var tag: String }
        var tag: String
        var title: String
        var name: String?
        var useForUI: String?
        var stop: OneOrMany<StopRef>

        var isUI: Bool { useForUI == "true" }
        /// The way it runs; agencies that leave `name` empty get one way per direction tag.
        var way: String { (name?.isEmpty == false ? name : nil) ?? tag }
        /// "South - 29c Dufferin towards Exhibition (Princes' Gates)" → "Exhibition (Princes' Gates)".
        var headsign: String {
            guard let range = title.range(of: " towards ") else { return title }
            return String(title[range.upperBound...])
        }
    }

    struct Predictions: Decodable, Sendable {
        var routeTag: String
        var stopTag: String
        var direction: OneOrMany<PredictionDirection>?
    }

    struct PredictionDirection: Decodable, Sendable {
        var prediction: OneOrMany<Prediction>?
    }

    struct Prediction: Decodable, Sendable {
        var epochTime: String
        var dirTag: String?
        var tripTag: String?
        var isScheduleBased: String?
    }

    struct Vehicle: Decodable, Sendable {
        var id: String
        var lat: String
        var lon: String
        var dirTag: String?
        var heading: String?
        var speedKmHr: String?
        var secsSinceReport: String?
    }
}
