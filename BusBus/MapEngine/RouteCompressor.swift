import Foundation

nonisolated enum DrawnRunKind: Hashable, Sendable {
    case stop(index: Int)
    case dash(swallowed: Range<Int>)
}

nonisolated struct CompressedLine: Hashable, Sendable {
    var lineID: String
    /// Indices `1 ..< n` in order (the terminus at 0 is always drawn, the user's stop at `n` is
    /// the node), with runs of hidden stops collapsed into `.dash`.
    var runs: [DrawnRunKind]
    /// How many of the line's own stops are drawn between its dash and the junction.
    var ownTailCount: Int
    /// Offsets *within the shared segment* that a bundle dash swallows, or nil when the whole
    /// shared segment is drawn. Offsets rather than absolute indices because every line of a
    /// bundle shares the same suffix of stops but numbers them differently.
    var sharedDashed: Range<Int>?

    var dashes: [Range<Int>] {
        runs.compactMap { if case .dash(let r) = $0 { r } else { nil } }
    }

    var drawnStopIndices: [Int] {
        runs.compactMap { if case .stop(let i) = $0 { i } else { nil } }
    }
}

/// Turns a route that is far too long to draw into the handful of stops that actually get marks.
///
/// Shape: terminus → one or two real stops → a dashed run labelled with the number of stops it
/// swallows → the last few stops before the junction (or before the user's stop). Each line is
/// compressed on its own, so the dashes deliberately do not line up across rows.
nonisolated enum RouteCompressor {
    /// A dash is only worth drawing when it hides at least this many stops. With head 1 and tail 5
    /// this also delivers the brief's "a route of 9 stops or fewer is drawn in full".
    static let minimumSwallowed = 2

    /// - Parameters:
    ///   - shared: indices the line runs together with the trunk — from its junction (inclusive)
    ///     to the user's stop (exclusive). Empty when the line never joins.
    static func compress(line: MapLineInput, shared: Range<Int>, headCount: Int, tailBudget: Int) -> CompressedLine {
        let n = line.stops.count - 1
        guard n >= 1 else {
            return CompressedLine(lineID: line.id, runs: [], ownTailCount: 0, sharedDashed: nil)
        }

        // 1. Bundle compression: the corridor the lines share can itself be too long to draw.
        let sharedCount = shared.count
        var sharedDashed: Range<Int>?
        var sharedRuns: [DrawnRunKind] = []
        var drawnShared = sharedCount

        if sharedCount - tailBudget >= minimumSwallowed {
            let keepAtEnd = max(0, tailBudget - 1)
            let swallowed = 1 ..< (sharedCount - keepAtEnd)
            sharedDashed = swallowed
            drawnShared = tailBudget
            sharedRuns.append(.stop(index: shared.lowerBound))
            sharedRuns.append(.dash(swallowed: (shared.lowerBound + swallowed.lowerBound) ..< (shared.lowerBound + swallowed.upperBound)))
            sharedRuns.append(contentsOf: shared.suffix(keepAtEnd).map { DrawnRunKind.stop(index: $0) })
        } else {
            sharedRuns = shared.map { DrawnRunKind.stop(index: $0) }
        }

        // 2. What is left of the tail budget goes to the line's own stops before the junction.
        let ownTail = max(1, tailBudget - drawnShared)

        // 3. The own segment: everything between the terminus and the junction (or the node).
        // A line that lies entirely on the trunk joins at its own index 0, so it has none.
        let ownUpperBound = max(1, shared.isEmpty ? n : shared.lowerBound)
        let ownRange = 1 ..< ownUpperBound
        var ownRuns: [DrawnRunKind] = []
        var ownTailCount = 0

        if !ownRange.isEmpty {
            let ownCount = ownRange.count
            let head = min(headCount, ownCount)
            let tail = min(ownTail, ownCount - head)
            let middle = (ownRange.lowerBound + head) ..< (ownRange.upperBound - tail)

            if middle.count >= minimumSwallowed {
                ownRuns = ownRange.prefix(head).map { DrawnRunKind.stop(index: $0) }
                ownRuns.append(.dash(swallowed: middle))
                ownRuns.append(contentsOf: ownRange.suffix(tail).map { DrawnRunKind.stop(index: $0) })
                ownTailCount = tail
            } else {
                ownRuns = ownRange.map { DrawnRunKind.stop(index: $0) }
                ownTailCount = ownCount - head
            }
        }

        return CompressedLine(lineID: line.id, runs: ownRuns + sharedRuns,
                              ownTailCount: ownTailCount, sharedDashed: sharedDashed)
    }
}
