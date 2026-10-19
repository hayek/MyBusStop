import Foundation
#if canImport(BusBus)
@testable import BusBus
#endif

/// One provider's real-world smoke route: a stop that must be findable, and optionally the line and
/// point to use. Everything else is discovered from the live API, so fixtures survive timetable churn.
nonisolated struct LiveFixture: Sendable, CustomStringConvertible {
    var provider: any TransitProvider
    /// Name search that must return at least one stop.
    var stopQuery: String
    /// Pick this stop out of the search results (by `TransitStop.code`); first result otherwise.
    var stopCode: String?
    /// Prefer this line at the stop (by `shortName`); lines are tried in order otherwise.
    var lineShortName: String?
    /// A point with stops around it, for providers with `.nearbyStops`.
    var nearby: GeoPoint?
    /// The provider's local time zone — an empty vehicle feed only counts as broken in daytime.
    var timeZone: TimeZone

    var description: String { provider.id }

    /// The provider as the checks call it: a transient 5xx or dropped connection is retried, so a
    /// failure here means the API is down or changed, not that one request was unlucky.
    var api: any TransitProvider { RetryingProvider(base: provider) }
}

/// Makes up to three attempts at each call on server errors (HTTP 5xx) and network failures, backing
/// off 2 s then 4 s. Anything else — a 4xx, a decoding error, an empty answer — fails at once,
/// because those are the changes the live checks exist to catch.
nonisolated struct RetryingProvider: TransitProvider {
    var base: any TransitProvider

    var id: String { base.id }
    var displayName: String { base.displayName }
    var capabilities: ProviderCapabilities { base.capabilities }
    var suggestedRefreshInterval: Duration { base.suggestedRefreshInterval }
    var refreshInterval: Duration { base.refreshInterval }
    var datasetID: String { base.datasetID }
    var attribution: String? { base.attribution }
    var requiredAPIKey: String? { base.requiredAPIKey }
    var reportsShadowTrips: Bool { base.reportsShadowTrips }
    var shapeDatasetID: String { base.shapeDatasetID }
    var shapeTolerance: ShapeTolerance { base.shapeTolerance }
    func hasRouteShape(for line: TransitLine) -> Bool { base.hasRouteShape(for: line) }

    func searchStops(query: String) async throws -> [TransitStop] { try await retrying { try await base.searchStops(query: query) } }
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] { try await retrying { try await base.lines(atStop: stop) } }
    func routePattern(for line: TransitLine) async throws -> RoutePattern { try await retrying { try await base.routePattern(for: line) } }
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { try await retrying { try await base.vehicles(for: line) } }
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] { try await retrying { try await base.arrivals(for: line, at: stop) } }
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        try await retrying { try await base.stopsNearby(point, radiusMeters: radiusMeters) }
    }
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        try await retrying { try await base.routeShape(for: line, pattern: pattern) }
    }
    func routePatternWithShape(for line: TransitLine) async throws -> (pattern: RoutePattern, shape: RouteShape?) {
        try await retrying { try await base.routePatternWithShape(for: line) }
    }

    private func retrying<T>(_ call: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await call()
            } catch where attempt < 3 && Self.isTransient(error) {
                try await Task.sleep(for: .seconds(2 * attempt))
                attempt += 1
            }
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case TransitError.badResponse(let message) = error { return message.hasPrefix("HTTP 5") }
        return false
    }
}

/// The live checks, as plain async functions so they run both under Swift Testing and from
/// `scripts/live-probe.sh` (a standalone build that needs no simulator).
nonisolated enum LiveProbe {
    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    static func stop(_ f: LiveFixture) async throws -> TransitStop {
        let results = try await f.api.searchStops(query: f.stopQuery)
        guard !results.isEmpty else { throw Failure("search \"\(f.stopQuery)\" returned no stops") }
        for stop in results where !isValid(stop.location) {
            throw Failure("stop \(stop.code) has invalid coordinates \(stop.location)")
        }
        guard let code = f.stopCode else { return results[0] }
        guard let stop = results.first(where: { $0.code == code }) else {
            throw Failure("stop \(code) not among \(results.prefix(10).map(\.code)) for \"\(f.stopQuery)\"")
        }
        return stop
    }

    /// Lines at the fixture stop, preferred line first.
    static func lines(_ f: LiveFixture) async throws -> (TransitStop, [TransitLine]) {
        let stop = try await stop(f)
        var lines = try await f.api.lines(atStop: stop)
        guard !lines.isEmpty else { throw Failure("no lines at stop \(stop.code) \(stop.name)") }
        if let preferred = f.lineShortName, let index = lines.firstIndex(where: { $0.shortName == preferred }) {
            lines.insert(lines.remove(at: index), at: 0)
        }
        return (stop, lines)
    }

    static func pattern(_ f: LiveFixture) async throws -> (TransitStop, RoutePattern) {
        let (stop, lines) = try await lines(f)
        let pattern = try await f.api.routePattern(for: lines[0])
        try check(pattern, servesNear: stop)
        return (stop, pattern)
    }

    /// A shape for one of the stop's first three lines, through the pattern reply when it carries
    /// one (no request of its own) and `routeShape` otherwise, judged against the pattern's stops as
    /// the cache judges it. One bad line is the feed's data (TfL places a stop on the 88 almost a
    /// kilometre off); three is the adapter.
    static func shape(_ f: LiveFixture) async throws -> (line: String, shape: RouteShape, verdict: ShapeVerdict,
                                                         piggybacked: Bool, rejected: [String]) {
        let (_, lines) = try await lines(f)
        var rejected: [String] = []
        for line in lines.prefix(3) {
            let (pattern, carried) = try await f.api.routePatternWithShape(for: line)
            let shape: RouteShape
            do {
                if let carried { shape = carried } else { shape = try await f.api.routeShape(for: pattern.line, pattern: pattern) }
            } catch where TransitCache.isLasting(error) {
                rejected.append("\(line.shortName): \(error.localizedDescription)")
                continue
            }
            let verdict = StoredShape(judging: shape, for: pattern, tolerance: f.api.shapeTolerance).verdict
            if verdict.passes { return (line.shortName, shape, verdict, carried != nil, rejected) }
            rejected.append("\(line.shortName): \(verdict.reason ?? "?")")
        }
        throw Failure("no shape passed: \(rejected.joined(separator: "; "))")
    }

    /// Vehicles of the first line that has any (up to five lines are tried). Empty is only a
    /// failure in the provider's daytime, when a dead feed and a quiet night can be told apart.
    static func vehicles(_ f: LiveFixture) async throws -> [VehiclePosition] {
        let (_, lines) = try await lines(f)
        for line in lines.prefix(5) {
            let vehicles = try await f.api.vehicles(for: line)
            guard !vehicles.isEmpty else { continue }
            for vehicle in vehicles where !isValid(vehicle.location) {
                throw Failure("vehicle on \(line.shortName) has invalid coordinates \(vehicle.location)")
            }
            let pattern = try await f.api.routePattern(for: line)
            let offRoute = vehicles.filter { v in
                !pattern.stops.contains { RouteGeometry.meters($0.stop.location, v.location) < 5_000 }
            }
            if offRoute.count == vehicles.count {
                throw Failure("all \(vehicles.count) vehicles of \(line.shortName) are >5 km from its route")
            }
            return vehicles
        }
        if isDaytime(f.timeZone) {
            throw Failure("no vehicles on any of \(lines.prefix(5).map(\.shortName)) in local daytime")
        }
        return []
    }

    /// Arrivals of the first line that has any. Same daytime rule as vehicles.
    static func arrivals(_ f: LiveFixture) async throws -> [Arrival] {
        let (stop, lines) = try await lines(f)
        let now = Date()
        for line in lines.prefix(5) {
            let arrivals = try await f.api.arrivals(for: line, at: stop)
            guard !arrivals.isEmpty else { continue }
            guard arrivals.map(\.expectedAt) == arrivals.map(\.expectedAt).sorted() else {
                throw Failure("arrivals of \(line.shortName) are not soonest-first")
            }
            let window = now.addingTimeInterval(-15 * 60)...now.addingTimeInterval(24 * 3600)
            guard let bad = arrivals.first(where: { !window.contains($0.expectedAt) }) else { return arrivals }
            throw Failure("arrival of \(line.shortName) at \(bad.expectedAt) is outside \(window)")
        }
        if isDaytime(f.timeZone) {
            throw Failure("no arrivals for any of \(lines.prefix(5).map(\.shortName)) at \(stop.code) in local daytime")
        }
        return []
    }

    static func nearby(_ f: LiveFixture) async throws -> [NearbyStop] {
        guard let point = f.nearby else { throw Failure("fixture has no nearby point") }
        let radius = 500.0
        let stops = try await f.api.stopsNearby(point, radiusMeters: radius)
        guard !stops.isEmpty else { throw Failure("no stops within \(Int(radius)) m of \(point)") }
        if let far = stops.first(where: { $0.distanceMeters > radius * 2 }) {
            throw Failure("nearby stop \(far.stop.code) is \(Int(far.distanceMeters)) m away")
        }
        return stops
    }

    // MARK: - Checks

    static func check(_ pattern: RoutePattern, servesNear stop: TransitStop) throws {
        guard pattern.stops.count >= 2 else { throw Failure("pattern of \(pattern.line.shortName) has \(pattern.stops.count) stops") }
        let sequences = pattern.stops.map(\.sequence)
        guard sequences == sequences.sorted() else { throw Failure("pattern of \(pattern.line.shortName) is not in sequence order") }
        let nearest = pattern.stops.map { RouteGeometry.meters($0.stop.location, stop.location) }.min() ?? .infinity
        guard nearest < 1_000 else {
            throw Failure("pattern of \(pattern.line.shortName) passes no closer than \(Int(nearest)) m to stop \(stop.code)")
        }
    }

    static func isValid(_ p: GeoPoint) -> Bool {
        (-90...90).contains(p.lat) && (-180...180).contains(p.lon) && !(p.lat == 0 && p.lon == 0)
    }

    static func isDaytime(_ zone: TimeZone, at date: Date = Date()) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return (8..<20).contains(calendar.component(.hour, from: date))
    }

    // MARK: - Report (for the CLI probe)

    static func report(_ f: LiveFixture) async -> Bool {
        var ok = true
        func line(_ step: String, _ body: () async throws -> String) async {
            do { print("  ✓ \(step): \(try await body())") } catch { ok = false; print("  ✗ \(step): \(error)") }
        }
        print("\(f.provider.id) — \(f.provider.displayName)")
        await line("searchStops") { let s = try await stop(f); return "\(s.code) \(s.name) @ \(s.location.lat),\(s.location.lon)" }
        await line("lines(atStop:)") { let (_, l) = try await lines(f); return "\(l.count) lines: \(l.prefix(8).map(\.shortName))" }
        await line("routePattern") { let (_, p) = try await pattern(f); return "\(p.line.shortName) → \(p.stops.count) stops, \(p.firstStop?.name ?? "?") … \(p.lastStop?.name ?? "?")" }
        if f.provider.capabilities.contains(.vehiclePositions) {
            await line("vehicles") { let v = try await vehicles(f); return "\(v.count) vehicles, first \(v.first.map { "\($0.location.lat),\($0.location.lon)" } ?? "-")" }
        }
        if f.provider.capabilities.contains(.realtimeArrivals) || f.provider.capabilities.contains(.scheduledArrivals) {
            await line("arrivals") { let a = try await arrivals(f); return "\(a.count) arrivals, next \(a.first.map { "\($0.expectedAt) rt=\($0.isRealtime)" } ?? "-")" }
        }
        if f.provider.capabilities.contains(.routeShape) {
            await line("routeShape") {
                let s = try await shape(f)
                return "\(s.line): \(s.shape.branches.count) branch(es), \(s.shape.pointCount) points, worst stop \(Int(s.verdict.worstOffset ?? 0)) m\(s.piggybacked ? ", from the pattern reply" : "")\(s.rejected.isEmpty ? "" : " (rejected \(s.rejected.joined(separator: "; ")))")"
            }
        }
        if f.provider.capabilities.contains(.nearbyStops) {
            await line("stopsNearby") { let n = try await nearby(f); return "\(n.count) stops, nearest \(n[0].stop.name) \(Int(n[0].distanceMeters)) m, \(n[0].lines.count) lines" }
        }
        return ok
    }
}
