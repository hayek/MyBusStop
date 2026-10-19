import Foundation

/// EFA's geo object (`XML_GEOOBJECT_REQUEST`) sends a line's path as loose pieces: in no order,
/// either way round, and the union of every variant — pieces split where variants part, detours,
/// turning stubs past the terminus, now and then a short missing link. Vienna's routing service is
/// an EFA too and sends the same. docs/research/route-shapes/central-east-europe.md (efa-linz).
nonisolated enum EFAShape {
    /// `[[lat, lon], …]`.
    static func points(_ pairs: [[Double]]) -> [GeoPoint] {
        pairs.compactMap { $0.count >= 2 ? GeoPoint(lat: $0[0], lon: $0[1]) : nil }
    }

    /// One line from the first stop to the last: start at the piece end nearest the first stop and
    /// keep adding the piece that touches the tail (within `gap`; where several do, the one heading
    /// for the next stop). When none touches before the last
    /// stop: a piece that starts back on the chain's last kilometre overlaps it, so the chain is cut
    /// back to where it starts; otherwise a short missing link (up to `bridge`) is bridged, and a
    /// longer one ends the chain rather than draw a straight line across town. Then the detour
    /// piece is spliced in for any stop the chain passes by. Whatever is left (stubs, depot spurs,
    /// other variants) is dropped.
    static func stitch(_ pieces: [[GeoPoint]], stops: [GeoPoint], gap: Double = 30, done: Double = 150,
                       bridge: Double = 300, overlap: Double = 1000,
                       offStop: Double = 50, spliceReach: Double = 150) -> [GeoPoint] {
        var unique: [[GeoPoint]] = []
        var seen = Set<[GeoPoint]>()
        for piece in pieces where piece.count >= 2 && !seen.contains(piece) && !seen.contains(Array(piece.reversed())) {
            seen.insert(piece)
            unique.append(piece)
        }
        guard let first = stops.first, let last = stops.last, !unique.isEmpty else { return unique.first ?? [] }
        let meters = ShapeCheck.meters

        /// The unused piece end nearest a point, and whether the piece has to be reversed to start there.
        func nearestEnd(to point: GeoPoint, among indices: [Int]) -> (index: Int, reversed: Bool, distance: Double)? {
            indices.flatMap { index in
                [(index, false, meters(point, unique[index].first!)), (index, true, meters(point, unique[index].last!))]
            }.min { $0.2 < $1.2 }.map { (index: $0.0, reversed: $0.1, distance: $0.2) }
        }

        /// The chain vertex nearest a point among those up to `overlap` metres back from the tail,
        /// when it is within `gap`.
        func overlapping(_ point: GeoPoint, in chain: [GeoPoint]) -> Int? {
            var back = 0.0
            var nearest: (index: Int, distance: Double)?
            for index in chain.indices.dropFirst().reversed() {
                let distance = meters(chain[index], point)
                if distance <= gap, distance < nearest?.distance ?? .infinity { nearest = (index, distance) }
                back += meters(chain[index], chain[index - 1])
                if back > overlap { break }
            }
            return nearest?.index
        }

        /// The piece to add next: the one whose end is nearest the tail, unless several touch it
        /// (variants parting at a junction, or a loop and the road it bypasses). Then the one that
        /// comes nearest the first stop the chain has not reached yet, rather than whichever the
        /// reply happened to list first.
        func nextEnd(after chain: [GeoPoint], among indices: [Int]) -> (index: Int, reversed: Bool, distance: Double)? {
            guard let nearest = nearestEnd(to: chain.last!, among: indices), nearest.distance <= gap else {
                return nearestEnd(to: chain.last!, among: indices)
            }
            let touching = indices.flatMap { index in
                [(index: index, reversed: false, distance: meters(chain.last!, unique[index].first!)),
                 (index: index, reversed: true, distance: meters(chain.last!, unique[index].last!))]
            }.filter { $0.distance <= gap }
            guard Set(touching.map(\.index)).count > 1 else { return nearest }
            let reached = ShapeCheck.Projection(chain)
            guard let ahead = stops.first(where: { reached.nearest($0) > offStop }) else { return nearest }
            return touching.min { a, b in
                let (pa, pb) = (ShapeCheck.Projection(unique[a.index]).nearest(ahead), ShapeCheck.Projection(unique[b.index]).nearest(ahead))
                return pa != pb ? pa < pb : a.distance < b.distance
            }
        }

        var unused = Array(unique.indices)
        let start = nearestEnd(to: first, among: unused)!
        var chain = start.reversed ? Array(unique[start.index].reversed()) : unique[start.index]
        unused.removeAll { $0 == start.index }
        while let next = nextEnd(after: chain, among: unused) {
            let piece = next.reversed ? Array(unique[next.index].reversed()) : unique[next.index]
            if next.distance > gap {
                if meters(chain.last!, last) <= done { break }
                if let cut = overlapping(piece[0], in: chain) {
                    chain.removeSubrange((cut + 1)...)
                } else if next.distance > bridge {
                    break
                }
            }
            chain += meters(chain.last!, piece[0]) < 1 ? Array(piece.dropFirst()) : piece
            unused.removeAll { $0 == next.index }
        }

        /// How many stops lie within `offStop` of a line in travel order: the most that can be met
        /// one after another without the line running backwards.
        func inOrder(_ line: [GeoPoint]) -> Int {
            let projection = ShapeCheck.Projection(line)
            var met: [(along: Double, count: Int)] = []
            for stop in stops {
                let here = projection.candidates(for: stop, within: offStop).map { candidate in
                    (along: candidate.along, count: 1 + (met.filter { $0.along <= candidate.along + 1 }.map(\.count).max() ?? 0))
                }
                met += here
            }
            return met.map(\.count).max() ?? 0
        }

        /// Each place the chain passes within `spliceReach` of a point: the nearest vertex of each pass.
        func passes(by point: GeoPoint, of chain: [GeoPoint]) -> [Int] {
            let distance = chain.map { meters(point, $0) }
            return chain.indices.filter { index in
                distance[index] <= spliceReach
                    && (index == 0 || distance[index] <= distance[index - 1])
                    && (index == chain.count - 1 || distance[index] < distance[index + 1])
            }
        }

        /// The chain with a detour piece in place of the stretch between where the piece leaves it
        /// and where it rejoins, either way round. The chain can pass a piece's end more than once
        /// (a loop's first and last vertices both lie by its terminus), so every pass is tried. The
        /// splice kept is the one that brings the most stops onto the line in order — on a tie, the
        /// one that drops the shorter stretch — and only when that is more than the chain had: a
        /// turning stub must not stand in for the loop whose stops it would drop, while a shortcut
        /// may drop a loop with none of the pattern's stops on it, however long.
        func spliced(_ piece: [GeoPoint], into chain: [GeoPoint]) -> [GeoPoint]? {
            var best: (line: [GeoPoint], count: Int, dropped: Double)?
            for piece in [piece, Array(piece.reversed())] {
                let rejoins = passes(by: piece.last!, of: chain)
                for leave in passes(by: piece.first!, of: chain) {
                    for rejoin in rejoins where rejoin >= leave {
                        let line = Array(chain[...leave]) + piece + Array(chain[rejoin...])
                        let count = inOrder(line)
                        let dropped = ShapeCheck.length(Array(chain[leave...rejoin]))
                        if best.map({ count > $0.count || (count == $0.count && dropped < $0.dropped) }) ?? true {
                            best = (line, count, dropped)
                        }
                    }
                }
            }
            guard let best, best.count > inOrder(chain) else { return nil }
            return best.line
        }

        // Any piece may serve, a chained one too: one the chain was later cut back past (a variant
        // taken at a junction and left again) is off the line now. One the chain still holds whole
        // cannot come nearer the stop than the chain does.
        for stop in stops where ShapeCheck.Projection(chain).nearest(stop) > offStop {
            let near = unique.indices
                .map { (index: $0, distance: ShapeCheck.Projection(unique[$0]).nearest(stop)) }
                .filter { $0.distance <= offStop }
                .min { $0.distance < $1.distance }
            guard let near, let detoured = spliced(unique[near.index], into: chain) else { continue }
            chain = detoured
        }
        return chain
    }
}
