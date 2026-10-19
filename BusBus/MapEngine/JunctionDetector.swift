import Foundation

nonisolated struct JunctionResult: Hashable, Sendable {
    /// Index into the joining line's `stops` of the first stop it shares with the trunk, or nil
    /// when the line keeps its own rail all the way to the node.
    var lineJunctionIndex: Int?
    /// Index into the trunk's `stops` of that same stop.
    var trunkJunctionIndex: Int?
    /// True when the whole line, terminus included, lies on the trunk.
    var lineIsSubsetOfTrunk: Bool

    static let none = JunctionResult(lineJunctionIndex: nil, trunkJunctionIndex: nil, lineIsSubsetOfTrunk: false)

    var hasJunction: Bool { lineJunctionIndex != nil }
}

/// Where a line stops being its own route and starts running with the trunk.
///
/// Merging is data, not decoration: walk both stop sequences backwards from the user's stop and
/// stop at the first divergence. Everything before that point is the line's own rail; everything
/// after it runs parallel to the trunk.
nonisolated enum JunctionDetector {
    static func junction(of line: MapLineInput, onto trunk: MapLineInput, userStopCode: String) -> JunctionResult {
        // `lastIndex` rather than `firstIndex`: on a loop route that passes the user's stop twice,
        // the rider boards on the last pass, and it is that pass whose stop sequence precedes the
        // arrival. Callers normally trim the pattern so this is simply `count - 1`.
        guard let trunkUser = trunk.stops.lastIndex(where: { $0.code == userStopCode }),
              let lineUser = line.stops.lastIndex(where: { $0.code == userStopCode })
        else { return .none }

        var i = trunkUser
        var j = lineUser
        while i > 0, j > 0, trunk.stops[i - 1].code == line.stops[j - 1].code {
            i -= 1
            j -= 1
        }

        if j == lineUser {
            // Nothing shared before the user's stop: an independent rail that meets the trunk
            // only at the node (Main, and line 7 in Merge A).
            return .none
        }
        if j == 0 {
            // The line's terminus is already on the trunk: no own segment, no junction curve.
            return JunctionResult(lineJunctionIndex: 0, trunkJunctionIndex: i, lineIsSubsetOfTrunk: true)
        }
        if i == 0 {
            // We reached the trunk's terminus while the line still has stops of its own further
            // back. There is no room to draw that segment left of the trunk's terminus, so the
            // line is drawn independently and the shared stops appear as rings on both rails.
            return .none
        }
        return JunctionResult(lineJunctionIndex: j, trunkJunctionIndex: i, lineIsSubsetOfTrunk: false)
    }
}
