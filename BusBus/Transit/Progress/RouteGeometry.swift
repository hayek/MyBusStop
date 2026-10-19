import Foundation

/// Measures positions along a route pattern, so providers that only give bare GPS
/// (bus.gov.il, most GTFS-RT feeds) can still drive a progress bar.
/// The polyline is stop-to-stop straight segments. Good enough for "how far along";
/// GTFS shapes would be more precise.
nonisolated struct RouteGeometry: Sendable {
    let pattern: RoutePattern
    /// Metres from route start for each stop in `pattern.stops`.
    let stopDistances: [Double]

    init(pattern: RoutePattern) {
        self.pattern = pattern
        let points = pattern.stops.map(\.stop.location)
        let published = pattern.stops.map(\.distanceAlongRoute)

        // Prefer provider distances when every stop has one and they increase; otherwise measure.
        if published.allSatisfy({ $0 != nil }), zip(published, published.dropFirst()).allSatisfy({ $0! <= $1! }) {
            stopDistances = published.map { $0! }
        } else {
            var total = 0.0
            stopDistances = points.indices.map { index in
                if index > 0 { total += Self.meters(points[index - 1], points[index]) }
                return total
            }
        }
    }

    var totalLength: Double { stopDistances.last ?? 0 }

    func distance(ofStopCode code: String) -> Double? {
        pattern.stops.firstIndex { $0.stop.code == code }.map { stopDistances[$0] }
    }

    /// Snaps a point to the nearest segment. Returns metres along the route and how far off-route it is.
    /// Note: a route that passes the same street twice can snap to the wrong pass. Fine for the POC.
    func project(_ point: GeoPoint) -> (distanceAlong: Double, offRoute: Double)? {
        let stops = pattern.stops.map(\.stop.location)
        guard stops.count >= 2 else { return nil }

        var best: (distanceAlong: Double, offRoute: Double)?
        for index in 0..<(stops.count - 1) {
            let a = stops[index], b = stops[index + 1]
            // Local equirectangular frame around `a` (metres) — accurate at city scale.
            let metersPerDegLat = 111_320.0
            let metersPerDegLon = 111_320.0 * cos(a.lat * .pi / 180)
            let bx = (b.lon - a.lon) * metersPerDegLon, by = (b.lat - a.lat) * metersPerDegLat
            let px = (point.lon - a.lon) * metersPerDegLon, py = (point.lat - a.lat) * metersPerDegLat
            let lengthSquared = bx * bx + by * by
            let t = lengthSquared > 0 ? max(0, min(1, (px * bx + py * by) / lengthSquared)) : 0
            let dx = px - t * bx, dy = py - t * by
            let offRoute = (dx * dx + dy * dy).squareRoot()

            if best == nil || offRoute < best!.offRoute {
                let along = stopDistances[index] + t * (stopDistances[index + 1] - stopDistances[index])
                best = (along, offRoute)
            }
        }
        return best
    }

    /// Index of the last stop at or before a distance along the route.
    func lastStopIndex(atDistance distance: Double) -> Int {
        stopDistances.lastIndex { $0 <= distance + 1 } ?? 0
    }

    static func meters(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let r = 6_371_000.0
        let dLat = (b.lat - a.lat) * .pi / 180, dLon = (b.lon - a.lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.lat * .pi / 180) * cos(b.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, h.squareRoot()))
    }
}
