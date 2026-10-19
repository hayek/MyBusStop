import Foundation

/// The Transport Department's drawn routes, the only official line geometry for Hong Kong: the
/// operators' APIs have none and TD's GTFS has no shapes.txt. Served by the CSDI portal's ArcGIS
/// server, slowly (2–8 s) and now and then not at all. Free to use, crediting the Government and the
/// CSDI Portal. docs/research/route-shapes/asia-oceania.md.
///
/// TD numbers the variants itself (`ROUTE_ID`) and no operator API says which is which; even
/// `ROUTE_SEQ` is not the direction. So one query fetches every variant of a route number in both
/// directions, and the one the pattern's stops lie along is kept, cut to its first and last stop.
nonisolated enum HKRouteLines {
    /// Franchised buses: KMB, Long Win, Citybus, NLB, and four MTR feeders filed as KMB.
    static let busLayer = "https://portal.csdi.gov.hk/server/rest/services/common/td_rcd_1638844988873_41214/MapServer/0"
    /// Green minibuses, where `ROUTE_ID` and `ROUTE_SEQ` are the GMB API's own `route_id` and `route_seq`.
    static let minibusLayer = "https://portal.csdi.gov.hk/server/rest/services/common/td_rcd_1697082463580_57453/MapServer/0"

    /// How far a stop may stand from every drawn variant and still be left as a marker beside the
    /// line (`shape(_:stops:misses:)`); Citybus' Ice House Street stop is 131 m from route 11's.
    static let missReach = 150.0

    /// One drawn route direction, its stop-to-stop pieces joined into one line.
    struct Feature: Sendable {
        var routeID: Int
        var seq: Int
        var line: [GeoPoint]
    }

    private static let store = Memo<[Feature]>()
    private static let tolerance = ShapeTolerance.platforms

    /// The line of `route` (a route number) for this pattern, among the variants `company` selects.
    static func shape(route: String, company: String?, pattern: RoutePattern, misses: Int = 0,
                      http: HTTPClient) async throws -> RouteShape {
        let name = "ROUTE_NAMEE = '\(route.replacingOccurrences(of: "'", with: "''"))'"
        let clause = ([name] + [company].compactMap { $0 }).joined(separator: " AND ")
        return try await shape(busLayer, where: clause, pattern: pattern, misses: misses, http: http)
    }

    /// The pattern's line among the route lines matching `clause`; `notFound` when TD has not drawn
    /// the route or no drawn variant serves the pattern's stops, which the cache keeps as such.
    static func shape(_ layer: String, where clause: String, pattern: RoutePattern, misses: Int = 0,
                      http: HTTPClient) async throws -> RouteShape {
        let found = try await features(layer, where: clause, http: http)
        guard let shape = shape(found, stops: pattern.stops.map(\.stop.location), misses: misses) else {
            throw TransitError.notFound("route line for \(clause)")
        }
        return shape
    }

    /// The route lines matching `clause`. A rider opening one direction often opens the other next,
    /// so a reply is kept ten minutes; the shapes themselves are cached for a month. Simplified to
    /// ~3 m on the server (NLB 3M: 167 KB → 35 KB), piece by piece, so the pieces still meet.
    /// The portal's firewall answers 403 to `IN (…)`, so callers stick to `=`, `<>`, `LIKE` and `AND`.
    static func features(_ layer: String, where clause: String, http: HTTPClient) async throws -> [Feature] {
        try await store.value(layer + "|" + clause, ttl: .seconds(600)) {
            var http = http
            http.timeout = 15
            let query = [
                "where": clause, "outFields": "ROUTE_ID,ROUTE_SEQ", "returnGeometry": "true", "outSR": "4326",
                "geometryPrecision": "5", "maxAllowableOffset": "0.00003", "f": "geojson",
            ]
            do {
                return try await http.get(Wire.Collection.self, layer, "/query", query: query).features.compactMap(\.feature)
            } catch let error as URLError where [.timedOut, .networkConnectionLost].contains(error.code) {
                // About one query in ten timed out or was reset during research, and passed when asked again.
                try await Task.sleep(for: .seconds(3))
                return try await http.get(Wire.Collection.self, layer, "/query", query: query).features.compactMap(\.feature)
            }
        }
    }

    /// The pattern's line among the drawn variants, in order of preference:
    /// - one variant all the stops lie along, in order;
    /// - two variants run one after the other, where TD draws a circular route as two directions
    ///   meeting at the far end (MTR Bus K18: out to Kwong Fuk, back to Tai Po Market);
    /// - two variants as branches, each with the stops along it in order, when the operator's list
    ///   merges two of TD's (Citybus 1 outbound: one via Chater Road, one via Des Voeux Road Central);
    /// - one variant missing at most `misses` stops, each within `missReach`, when a stop is on no
    ///   drawn variant at all (Citybus 11 inbound's Ice House Street stop); it stays a marker.
    /// Otherwise, or when TD has not drawn the route, nil. (Not the nearest variant: Citybus'
    /// looser tolerance would let one through that misses more stops than allowed here.)
    static func shape(_ features: [Feature], stops: [GeoPoint], misses: Int = 0) -> RouteShape? {
        let version = { (picked: [Feature]) in picked.map { "\($0.routeID).\($0.seq)" }.joined(separator: ",") }

        let whole = features.compactMap { feature in fit(feature.line, stops).map { (feature: feature, line: $0.line, worst: $0.worst) } }
        if let best = whole.min(by: { ($0.worst, ShapeCheck.length($0.line)) < ($1.worst, ShapeCheck.length($1.line)) }) {
            return RouteShape(best.line, version: version([best.feature]))
        }

        var joined: (line: [GeoPoint], worst: Double, picked: [Feature])?
        for first in features {
            for then in features where then.routeID == first.routeID && then.seq != first.seq
                && ShapeCheck.meters(first.line.last!, then.line.first!) <= 30 {
                guard let line = fit(first.line + then.line.dropFirst(), stops) else { continue }
                if joined == nil || line.worst < joined!.worst { joined = (line.line, line.worst, [first, then]) }
            }
        }
        if let joined { return RouteShape(joined.line, version: version(joined.picked)) }

        let offsets = features.map { feature in
            let projection = ShapeCheck.Projection(feature.line)
            return stops.map(projection.nearest)
        }
        let limit = { (index: Int) in index == 0 || index == stops.count - 1 ? tolerance.ends : tolerance.stops }
        let along = { (k: Int) in stops.indices.filter { offsets[k][$0] <= limit($0) } }

        var pair: (branches: [[GeoPoint]], worst: Double, picked: [Feature])?
        for a in features.indices {
            for b in features.indices where b > a {
                let (onA, onB) = (along(a), along(b))
                guard onA.count >= 2, onB.count >= 2, Set(onA).union(onB).count == stops.count,
                      let lineA = fit(features[a].line, onA.map { stops[$0] }),
                      let lineB = fit(features[b].line, onB.map { stops[$0] }) else { continue }
                let worst = max(lineA.worst, lineB.worst)
                if pair == nil || worst < pair!.worst { pair = ([lineA.line, lineB.line], worst, [features[a], features[b]]) }
            }
        }
        if let pair { return RouteShape(branches: pair.branches, version: version(pair.picked)) }

        if misses > 0 {
            // Matched in order: on a loop, a stop can stand by the other half of it.
            let partial = features.compactMap { feature -> (feature: Feature, line: [GeoPoint], worst: Double)? in
                guard let ordered = ShapeCheck.orderedOffsets(feature.line, stops: stops) else { return nil }
                let missed = stops.indices.filter { ordered[$0] > limit($0) }
                guard missed.count <= misses, missed.allSatisfy({ ordered[$0] <= missReach }),
                      let kept = fit(feature.line, stops.indices.filter { !missed.contains($0) }.map { stops[$0] })
                else { return nil }
                return (feature, kept.line, kept.worst)
            }
            if let best = partial.min(by: { $0.worst < $1.worst }) { return RouteShape(best.line, version: version([best.feature])) }
        }

        return nil
    }

    /// The line cut to the stretch from the first stop to the last when it still fits them so
    /// (a loop drawn whole, of which the pattern is one half), else whole; nil when the stops do
    /// not lie along it in order.
    private static func fit(_ line: [GeoPoint], _ stops: [GeoPoint]) -> (line: [GeoPoint], worst: Double)? {
        let whole = ShapeCheck.verdict(RouteShape(line), stops: stops, tolerance: tolerance)
        guard whole.passes, let first = line.first, let last = line.last else { return nil }
        var cuts = [ShapeCheck.trimmed(line, stops: stops)]
        // A half starting (or ending) at a loop's seam is as near the loop's end as its start, and
        // the plain cut cannot tell which is meant: cut that half at its other end only.
        if ShapeCheck.meters(first, last) <= 30, stops.count >= 2 {
            cuts.append(ShapeCheck.trimmed(line, stops: [first] + stops.dropFirst()))
            cuts.append(ShapeCheck.trimmed(line, stops: stops.dropLast() + [last]))
        }
        let best = cuts
            .map { (line: $0, verdict: ShapeCheck.verdict(RouteShape($0), stops: stops, tolerance: tolerance)) }
            .filter(\.verdict.passes)
            .min { ShapeCheck.length($0.line) < ShapeCheck.length($1.line) }
        return best.map { ($0.line, $0.verdict.worstOffset ?? 0) } ?? (line, whole.worstOffset ?? 0)
    }

    /// The query's GeoJSON reply. Bus features are MultiLineStrings with one piece per
    /// stop-to-stop link, already in travel order and meeting end to end; minibus ones LineStrings.
    private enum Wire {
        struct Collection: Decodable, Sendable { var features: [Item] }

        struct Item: Decodable, Sendable {
            var geometry: Geometry?
            var properties: Properties

            var feature: Feature? {
                let pieces = geometry?.pieces ?? []
                var line: [GeoPoint] = []
                for piece in pieces {
                    let points = piece.compactMap { $0.count >= 2 ? GeoPoint(lat: $0[1], lon: $0[0]) : nil }
                    line += points.first == line.last ? points.dropFirst() : points[...]
                }
                guard line.count >= 2 else { return nil }
                return Feature(routeID: properties.ROUTE_ID, seq: properties.ROUTE_SEQ, line: line)
            }
        }

        struct Properties: Decodable, Sendable {
            var ROUTE_ID: Int
            var ROUTE_SEQ: Int
        }

        /// `[lon, lat]` pairs, as one LineString or the pieces of a MultiLineString.
        struct Geometry: Decodable, Sendable {
            var pieces: [[[Double]]]

            enum CodingKeys: String, CodingKey { case coordinates }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let multi = try? container.decode([[[Double]]].self, forKey: .coordinates) {
                    pieces = multi
                } else {
                    pieces = [try container.decode([[Double]].self, forKey: .coordinates)]
                }
            }
        }
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
