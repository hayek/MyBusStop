import Foundation

/// Whether a shape may be drawn for a pattern, and why not.
nonisolated struct ShapeVerdict: Codable, Hashable, Sendable {
    var passes: Bool
    /// Why it was rejected; nil when it passes.
    var reason: String?
    /// The farthest any stop stands from the line, matched in order, in metres; nil when the stops
    /// could not be matched at all.
    var worstOffset: Double?

    static func rejected(_ reason: String, worstOffset: Double? = nil) -> ShapeVerdict {
        ShapeVerdict(passes: false, reason: reason, worstOffset: worstOffset)
    }
}

/// Checks a shape against the stops it is meant to serve, and the small geometry the providers
/// need to assemble one. The rules come from checking every region live
/// (docs/research/route-shapes.md §2, `route-shapes/shapecheck.py` is the reference).
nonisolated enum ShapeCheck {
    // MARK: Verdict

    /// A shape passes when every stop is near it, in order along a single branch (loops and
    /// streets driven twice included), and it is not merely straight lines between the stops.
    /// With several branches each stop only has to be near one of them: they are variants.
    /// Length is not judged — real mountain and express routes run more than twice their stops'
    /// straight-line distance.
    static func verdict(_ shape: RouteShape, stops: [GeoPoint], tolerance: ShapeTolerance = .platforms) -> ShapeVerdict {
        guard !shape.isEmpty else { return .rejected("no geometry") }
        guard stops.count >= 2 else { return ShapeVerdict(passes: true, reason: nil, worstOffset: 0) }
        if isStraightLines(shape, stops: stops) {
            return .rejected("straight lines between stops")
        }

        let offsets: [Double]
        if shape.branches.count == 1 {
            guard let inOrder = orderedOffsets(shape.branches[0], stops: stops) else {
                return .rejected("stops are not in order along the line")
            }
            offsets = inOrder
        } else {
            let projections = shape.branches.map(Projection.init)
            offsets = stops.map { stop in projections.map { $0.nearest(stop) }.min() ?? .infinity }
        }

        let worst = offsets.max().flatMap { $0.isFinite ? $0 : nil }
        for (index, offset) in offsets.enumerated() {
            let isEnd = index == 0 || index == offsets.count - 1
            let limit = isEnd ? tolerance.ends : tolerance.stops
            if offset > limit {
                return .rejected("stop \(index + 1) of \(offsets.count) is \(offset.isFinite ? "\(Int(offset)) m" : "far") from the line", worstOffset: worst)
            }
        }
        return ShapeVerdict(passes: true, reason: nil, worstOffset: worst ?? 0)
    }

    /// A feed with no real shape sometimes sends the stops joined up: nearly every vertex is a stop.
    /// Real shapes had 0.2–8 % of their vertices on a stop.
    static func isStraightLines(_ shape: RouteShape, stops: [GeoPoint]) -> Bool {
        let vertices = shape.branches.flatMap { $0 }
        guard vertices.count >= 2 else { return true }
        let frame = LocalFrame(around: vertices[0])
        let grid = PointGrid(stops.map(frame.xy), cell: 20)
        let onStops = vertices.filter { grid.hasPoint(within: 10, of: frame.xy($0)) }.count
        return Double(onStops) / Double(vertices.count) >= 0.8
    }

    /// Each stop's distance from the line when the stops are matched in travel order, or nil when
    /// they cannot all be matched in order. Dynamic programming over every place a stop comes near
    /// the line, minimising the worst offset: a stop on a street the line drives twice may take
    /// either pass, but never one behind the previous stop.
    static func orderedOffsets(_ line: [GeoPoint], stops: [GeoPoint], searchRadius: Double = 400) -> [Double]? {
        orderedMatches(line, stops: stops, searchRadius: searchRadius)?.map(\.offset)
    }

    /// Where each stop meets the line when matched in order; see `orderedOffsets`.
    static func orderedMatches(_ line: [GeoPoint], stops: [GeoPoint], searchRadius: Double = 400) -> [Projection.Candidate]? {
        guard line.count >= 2, !stops.isEmpty else { return nil }
        let projection = Projection(line)
        let candidates = stops.map { projection.candidates(for: $0, within: searchRadius) }
        guard candidates.allSatisfy({ !$0.isEmpty }) else { return nil }

        // best[i][j]: (worst, sum) of the cheapest in-order assignment ending with stop i on candidate j.
        var best: [[(worst: Double, sum: Double, from: Int)]] = [candidates[0].map { ($0.offset, $0.offset, -1) }]
        for i in 1..<candidates.count {
            var row: [(worst: Double, sum: Double, from: Int)] = []
            for candidate in candidates[i] {
                var chosen: (worst: Double, sum: Double, from: Int)?
                for (j, previous) in candidates[i - 1].enumerated() where previous.along <= candidate.along + 1 {
                    let before = best[i - 1][j]
                    guard before.worst.isFinite else { continue }
                    let option = (worst: max(before.worst, candidate.offset), sum: before.sum + candidate.offset, from: j)
                    // On a tie the later pass wins: the shortest stretch between the two stops.
                    if chosen == nil || (option.worst, option.sum) <= (chosen!.worst, chosen!.sum) { chosen = option }
                }
                row.append(chosen ?? (.infinity, .infinity, -1))
            }
            best.append(row)
        }

        guard let last = best[best.count - 1].indices.min(by: {
            (best[best.count - 1][$0].worst, best[best.count - 1][$0].sum) < (best[best.count - 1][$1].worst, best[best.count - 1][$1].sum)
        }), best[best.count - 1][last].worst.isFinite else { return nil }

        var matches = [Projection.Candidate](repeating: .init(along: 0, offset: 0), count: stops.count)
        var j = last
        for i in stride(from: stops.count - 1, through: 0, by: -1) {
            matches[i] = candidates[i][j]
            j = best[i][j].from
        }
        return matches
    }

    // MARK: Assembling a shape

    /// The line pointing the way the stops run: reversed when it starts nearer the last stop
    /// than the first (some feeds store a direction backwards).
    static func oriented(_ line: [GeoPoint], stops: [GeoPoint]) -> [GeoPoint] {
        guard let first = stops.first, let last = stops.last, let start = line.first, stops.count >= 2 else { return line }
        return meters(start, last) < meters(start, first) ? line.reversed() : line
    }

    /// Of several candidate lines (a feed's branches, duplicates, short workings), the shortest
    /// one that passes for these stops, turned to run their way. Nil when none passes.
    static func bestPiece(_ pieces: [[GeoPoint]], stops: [GeoPoint], tolerance: ShapeTolerance = .platforms) -> [GeoPoint]? {
        var seen = Set<[GeoPoint]>()
        return pieces
            .map { oriented($0, stops: stops) }
            .filter { $0.count >= 2 && seen.insert($0).inserted }
            .filter { verdict(RouteShape($0), stops: stops, tolerance: tolerance).passes }
            .min { length($0) < length($1) }
    }

    /// Joins pieces that meet end to end (within `gap` metres), reversing a piece where it runs
    /// the other way. Pieces that join nothing stay separate, so the result may be several branches.
    static func chained(_ pieces: [[GeoPoint]], gap: Double = 30) -> [[GeoPoint]] {
        var remaining = pieces.filter { $0.count >= 2 }
        var chains: [[GeoPoint]] = []
        while !remaining.isEmpty {
            var chain = remaining.removeFirst()
            var grew = true
            while grew {
                grew = false
                for (index, piece) in remaining.enumerated() {
                    if meters(chain.last!, piece.first!) <= gap { chain += piece.dropFirst() }
                    else if meters(chain.last!, piece.last!) <= gap { chain += piece.reversed().dropFirst() }
                    else if meters(piece.last!, chain.first!) <= gap { chain = piece + chain.dropFirst() }
                    else if meters(piece.first!, chain.first!) <= gap { chain = piece.reversed() + chain.dropFirst() }
                    else { continue }
                    remaining.remove(at: index)
                    grew = true
                    break
                }
            }
            chains.append(chain)
        }
        return chains
    }

    /// The part of a line between the points nearest the first and the last stop: a route-level
    /// shape cut down to the variant's own ends.
    static func trimmed(_ line: [GeoPoint], stops: [GeoPoint]) -> [GeoPoint] {
        // The ends where the stops meet the line in order, so a loop is not cut at the wrong pass.
        guard line.count >= 2, let first = stops.first, let last = stops.last,
              let ends = orderedMatches(line, stops: [first, last]), ends[1].along > ends[0].along else { return line }
        return Projection(line).slice(from: ends[0].along, to: ends[1].along)
    }

    /// Douglas–Peucker in metres: what the map draws. About 3 m keeps every bend a rider can see.
    static func simplified(_ line: [GeoPoint], tolerance: Double = 3) -> [GeoPoint] {
        guard line.count > 2 else { return line }
        let frame = LocalFrame(around: line[0])
        let xy = line.map(frame.xy)
        var keep = [Bool](repeating: false, count: line.count)
        keep[0] = true
        keep[line.count - 1] = true
        var stack = [(0, line.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var farthest = first, distance = 0.0
            for index in (first + 1)..<last {
                let d = segmentDistance(xy[index], xy[first], xy[last]).distance
                if d > distance { distance = d; farthest = index }
            }
            if distance > tolerance {
                keep[farthest] = true
                stack.append((first, farthest))
                stack.append((farthest, last))
            }
        }
        return line.indices.filter { keep[$0] }.map { line[$0] }
    }

    static func length(_ line: [GeoPoint]) -> Double {
        zip(line, line.dropFirst()).reduce(0) { $0 + meters($1.0, $1.1) }
    }

    static func meters(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let frame = LocalFrame(around: a)
        let p = frame.xy(b)
        return (p.x * p.x + p.y * p.y).squareRoot()
    }

    // MARK: Plane geometry

    /// Metres east and north of a reference point. Equirectangular: accurate at city scale.
    struct LocalFrame {
        var origin: GeoPoint
        var metersPerDegreeLon: Double
        static let metersPerDegreeLat = 111_320.0

        init(around origin: GeoPoint) {
            self.origin = origin
            metersPerDegreeLon = Self.metersPerDegreeLat * cos(origin.lat * .pi / 180)
        }

        func xy(_ point: GeoPoint) -> SIMD2<Double> {
            SIMD2((point.lon - origin.lon) * metersPerDegreeLon, (point.lat - origin.lat) * Self.metersPerDegreeLat)
        }

        func point(_ xy: SIMD2<Double>) -> GeoPoint {
            GeoPoint(lat: origin.lat + xy.y / Self.metersPerDegreeLat, lon: origin.lon + xy.x / metersPerDegreeLon)
        }
    }

    static func segmentDistance(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> (distance: Double, t: Double) {
        let ab = b - a
        let lengthSquared = (ab * ab).sum()
        let t = lengthSquared > 0 ? min(1, max(0, ((p - a) * ab).sum() / lengthSquared)) : 0
        let d = p - (a + t * ab)
        return ((d * d).sum().squareRoot(), t)
    }

    /// A polyline in metres with each vertex's distance along it, for projecting stops onto it.
    struct Projection {
        struct Candidate { var along: Double; var offset: Double }

        let frame: LocalFrame
        let points: [GeoPoint]
        let xy: [SIMD2<Double>]
        let cumulative: [Double]

        init(_ line: [GeoPoint]) {
            points = line
            frame = LocalFrame(around: line.first ?? GeoPoint(lat: 0, lon: 0))
            xy = line.map(frame.xy)
            var total = 0.0
            var cumulative = [0.0]
            for index in xy.indices.dropFirst() {
                let d = xy[index] - xy[index - 1]
                total += (d * d).sum().squareRoot()
                cumulative.append(total)
            }
            self.cumulative = cumulative
        }

        func nearest(_ point: GeoPoint) -> Double {
            let p = frame.xy(point)
            var best = Double.infinity
            for index in xy.indices.dropLast() {
                best = min(best, ShapeCheck.segmentDistance(p, xy[index], xy[index + 1]).distance)
            }
            return best
        }

        /// Every separate place the line passes within `radius` of the point: the closest spot of
        /// each pass, passes told apart by 30 m along the line.
        func candidates(for point: GeoPoint, within radius: Double) -> [Candidate] {
            let p = frame.xy(point)
            var found: [Candidate] = []
            for index in xy.indices.dropLast() {
                let (distance, t) = ShapeCheck.segmentDistance(p, xy[index], xy[index + 1])
                guard distance <= radius else { continue }
                let along = cumulative[index] + t * (cumulative[index + 1] - cumulative[index])
                if let last = found.last, along - last.along < 30 {
                    if distance < last.offset { found[found.count - 1] = Candidate(along: along, offset: distance) }
                } else {
                    found.append(Candidate(along: along, offset: distance))
                }
            }
            return found
        }

        /// The point `along` metres from the start, clamped to the line's ends.
        func point(at along: Double) -> GeoPoint {
            guard let index = cumulative.lastIndex(where: { $0 <= along }), index < xy.count - 1 else { return points.last! }
            let span = cumulative[index + 1] - cumulative[index]
            let t = span > 0 ? (along - cumulative[index]) / span : 0
            return frame.point(xy[index] + t * (xy[index + 1] - xy[index]))
        }

        func slice(from start: Double, to end: Double) -> [GeoPoint] {
            let inside = points.indices.filter { cumulative[$0] > start && cumulative[$0] < end }.map { points[$0] }
            return [point(at: start)] + inside + [point(at: end)]
        }
    }

    /// Points bucketed into square cells, for "is any of them near here?".
    struct PointGrid {
        private var cells: [SIMD2<Int>: [SIMD2<Double>]] = [:]
        private let cell: Double

        init(_ points: [SIMD2<Double>], cell: Double) {
            self.cell = cell
            for point in points { cells[key(point), default: []].append(point) }
        }

        private func key(_ p: SIMD2<Double>) -> SIMD2<Int> { SIMD2(Int((p.x / cell).rounded(.down)), Int((p.y / cell).rounded(.down))) }

        func hasPoint(within radius: Double, of p: SIMD2<Double>) -> Bool {
            let center = key(p), reach = Int((radius / cell).rounded(.up))
            for dx in -reach...reach {
                for dy in -reach...reach {
                    for q in cells[center &+ SIMD2(dx, dy)] ?? [] where ((q - p) * (q - p)).sum() <= radius * radius {
                        return true
                    }
                }
            }
            return false
        }
    }
}
