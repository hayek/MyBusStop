import Foundation
import CoreGraphics

// The full route view: every stop of every watched line, terminus to terminus, with nothing folded
// into a dashed run. Where the board's engine works hard to fit a route into one screen, this one
// does the opposite — the route is as long as it is, and the view scrolls along it.
//
// Lines that call at the same stops run together there, as a bundle of parallel rails with one
// capsule and one name per shared stop, and part again where their routes do. The stops are lined
// up across the lines the way two texts are diffed: a stop both lines call at gets one column, and
// stops a line has to itself sit beside the other lines' own stops rather than queue after them.

nonisolated struct FullRouteLineInput: Identifiable, Hashable, Sendable {
    var id: String
    var number: String
    var colorIndex: Int
    /// The whole route, first terminus to last.
    var stops: [MapStopInput]
    /// Where the rider waits. The last visit, as on the board, for a route that calls twice.
    var userStopIndex: Int

    init(id: String, number: String, colorIndex: Int, stops: [MapStopInput], userStopIndex: Int) {
        self.id = id
        self.number = number
        self.colorIndex = colorIndex
        self.stops = stops
        self.userStopIndex = userStopIndex
    }
}

nonisolated struct FullRouteRequest: Hashable, Sendable {
    var lines: [FullRouteLineInput]
    /// `lastStopIndex` counts along the whole route, which starts the same as the board's trimmed one.
    var vehicles: [MapVehicleInput]
    var axis: MapAxis
    /// What the scroller shows at once. The lanes share its width (or height) between them.
    var viewport: CGSize

    init(lines: [FullRouteLineInput], vehicles: [MapVehicleInput] = [], axis: MapAxis, viewport: CGSize) {
        self.lines = lines
        self.vehicles = vehicles
        self.axis = axis
        self.viewport = viewport
    }
}

nonisolated enum FullRouteStopRole: Hashable, Sendable {
    case stop
    case userStop
    case lastStop
}

/// One piece of a line's rail, from one of its stops to the next. Where the line moves into or out
/// of a bundle the piece bends as an S, its handles halfway along.
nonisolated struct FullRouteSegment: Hashable, Sendable {
    var from: CGPoint
    var to: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var bends: Bool
    /// Past the rider's stop.
    var faded: Bool

    func point(at t: CGFloat) -> CGPoint {
        let t = min(max(t, 0), 1)
        guard bends else { return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t) }
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * from.x + b * control1.x + c * control2.x + d * to.x,
                       y: a * from.y + b * control1.y + c * control2.y + d * to.y)
    }
}

/// One watched line as drawn: where each of its stops sits and the rail between them.
nonisolated struct FullRouteLine: Identifiable, Hashable, Sendable {
    var id: String { lineID }
    var lineID: String
    var number: String
    var colorIndex: Int
    var badgeCenter: CGPoint
    /// Where each of the line's own stops is drawn, by its index along the route.
    var stopCenters: [CGPoint]
    /// `segments[i]` runs from stop `i` to stop `i + 1`.
    var segments: [FullRouteSegment]
    var userStopIndex: Int
}

/// A stop as drawn: one mark and one name, for every watched line that calls there together.
nonisolated struct FullRouteStop: Identifiable, Hashable, Sendable {
    var id: String
    var code: String
    var name: String
    /// The lines calling here, in lane order: one on its own, more where they run together.
    var lineIDs: [String]
    var colorIndex: Int
    var center: CGPoint
    /// Each calling line's rail through the stop; a shared stop's capsule spans them.
    var memberCenters: [CGPoint]
    var role: FullRouteStopRole
    /// Past the rider's stop: drawn back, since no bus there is coming to them.
    var isPastUserStop: Bool
    var labelAnchor: CGPoint
    /// As far as the name may run before it would reach the next rail.
    var labelMaxWidth: CGFloat

    var isShared: Bool { lineIDs.count > 1 }
}

nonisolated struct FullRouteScene: Hashable, Sendable {
    var axis: MapAxis
    var contentSize: CGSize
    var lines: [FullRouteLine]
    var stops: [FullRouteStop]
    var pucks: [PuckMark]
    /// Where the rider's stop is along the route, for opening the view on it.
    var userStopAlong: CGFloat
    /// The middle of the rider's stop node, for opening the view on it across as well.
    var userStopCenter: CGPoint

    // Shared by every mark of one kind, so they live here rather than on each mark.
    var railWidth: CGFloat
    var ringRadius: CGFloat
    var ringStroke: CGFloat
    var nodeRadius: CGFloat
    var badgeSide: CGFloat
    var labelRotation: Double
    var labelFontSize: CGFloat

    static let empty = FullRouteScene(axis: .horizontal, contentSize: .zero, lines: [], stops: [], pucks: [],
                                      userStopAlong: 0, userStopCenter: .zero, railWidth: 0, ringRadius: 0, ringStroke: 0,
                                      nodeRadius: 0, badgeSide: 0, labelRotation: 0, labelFontSize: 0)

    var isEmpty: Bool { lines.isEmpty }

    /// The span across the content that the rails take, bends included; what the strip shows.
    var railsAcross: ClosedRange<CGFloat>? {
        let values = lines.flatMap(\.stopCenters).map { axis == .horizontal ? $0.y : $0.x }
        guard let low = values.min(), let high = values.max() else { return nil }
        return low...high
    }

    /// The point to scroll to so the rider's stop sits in the middle of `viewport`, kept inside
    /// the content. Across too: lanes too wide for the view would otherwise open on the first,
    /// whichever lane the rider's stop gathers on.
    func offset(centeringUserStopIn viewport: CGSize) -> CGPoint {
        FullRouteMinimap.clamp(CGPoint(x: userStopCenter.x - viewport.width / 2,
                                       y: userStopCenter.y - viewport.height / 2),
                               visible: viewport, content: contentSize)
    }
}

nonisolated enum FullRouteLayout {
    /// Room for a name at −35° between two stops, and for a finger on either.
    static let horizontalPitch: CGFloat = 72
    /// Two lines of a name stacked between two stops.
    static let verticalPitch: CGFloat = 48
    /// Before the first column: the margin before the line's badge.
    static let leadingMargin: CGFloat = 16
    /// After the last stop: room for its name, which runs on past it at −35° in landscape.
    static let horizontalTrailingInset: CGFloat = 120
    static let verticalTrailingInset: CGFloat = 48
    /// Above the first lane in landscape, for the rise of the top lane's longest names.
    static let horizontalTopInset: CGFloat = 20
    /// A lane is never squeezed below this, even with three lines on a short screen; the view
    /// scrolls across too rather than overlap them.
    static let minimumHorizontalLane: CGFloat = 140
    static let minimumVerticalLane: CGFloat = 132
    /// Where a horizontal lane's rail sits, up from its foot: below it only the pucks' lower half.
    static let horizontalRailFromFoot: CGFloat = 30
    /// Where a vertical lane's rail sits, in from its leading edge.
    static let verticalRailInset: CGFloat = 30
    /// Rails running together, centre to centre: a rail's width and a sliver of ground.
    static let bundleSpacing: CGFloat = 14
    static let railWidth: CGFloat = 10
    static let badgeSide: CGFloat = 34
    /// In landscape a stop's name starts this far above its stop and climbs at −35° for at most
    /// `horizontalLabelReach`, in two lines of 12-point type.
    static let horizontalLabelGap: CGFloat = 23
    static let horizontalLabelReach: CGFloat = 112
    static let labelFontSize: CGFloat = 12
    static let horizontalLabelAngle = CGFloat.pi * 35 / 180
    /// How high the names reach above a landscape rail, and how far the buses hang below it: the
    /// band a lane's drawing takes, which landscape centres in the view.
    static let horizontalNameRise = horizontalLabelGap + horizontalLabelReach * sin(horizontalLabelAngle)
        + 2 * labelFontSize * 1.25 * cos(horizontalLabelAngle)
    static let horizontalBelowRail: CGFloat = 17

    static func layout(_ request: FullRouteRequest) -> FullRouteScene {
        let lines = request.lines.filter { $0.stops.count >= 2 }
        guard !lines.isEmpty else { return .empty }
        let horizontal = request.axis == .horizontal
        let pitch = horizontal ? horizontalPitch : verticalPitch
        let userIndex = lines.map { min(max(0, $0.userStopIndex), $0.stops.count - 1) }

        // 1. Columns: which stop of which line sits where along the route.
        let columns = RouteAlignment.columns(lines: lines.map { $0.stops.map(\.code) }, userIndices: userIndex)
        let userColumn = columns.firstIndex { column in
            column.count == lines.count && column.allSatisfy { userIndex[$0.key] == $0.value }
        } ?? 0
        /// Per line, the column each of its stops is in.
        var columnOf = lines.map { [Int](repeating: 0, count: $0.stops.count) }
        for (c, column) in columns.enumerated() { for (line, stop) in column { columnOf[line][stop] = c } }

        // 2. Who runs with whom: per column, the lines calling at the same stop.
        let groups: [[[Int]]] = columns.map { column in
            Dictionary(grouping: column.keys) { lines[$0].stops[column[$0]!].code }
                .values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
        }
        let lane = laneOrder(lineCount: lines.count, groups: groups, userColumn: userColumn)

        // 3. Across: each line's slot at each of its stops — its own lane alone, a bundle's slot
        // together. A line alone between two stops it shares with the same lines stays in the
        // bundle: an express passing a stop the others serve, not a detour.
        let acrossViewport = horizontal ? request.viewport.height : request.viewport.width
        let topInset = horizontal ? horizontalTopInset : 0
        // The lanes share what the inset leaves, so lanes that fit never scroll across.
        let laneSize = max(horizontal ? minimumHorizontalLane : minimumVerticalLane,
                           (acrossViewport - topInset) / CGFloat(lines.count))
        // In landscape a lane's rail sits at its foot, under the names that climb from it, so one
        // line on a tall view would run along the bottom. The drawing — the top lane's names down
        // to the bottom lane's buses — is raised until it sits in the middle of the view, but never
        // so far that the top lane's names lose the room they climb into.
        let raise: CGFloat = {
            guard horizontal else { return 0 }
            let topRail = topInset + laneSize - horizontalRailFromFoot
            let bottomRail = topInset + CGFloat(lines.count) * laneSize - horizontalRailFromFoot
            let top = topRail - horizontalNameRise, bottom = bottomRail + horizontalBelowRail
            let toMiddle = acrossViewport / 2 - (top + bottom) / 2
            return min(0, max(toMiddle, -top))
        }()

        func slot(of line: Int, in group: [Int]) -> CGFloat {
            let members = group.sorted { lane[$0] < lane[$1] }
            let k = CGFloat(members.firstIndex(of: line) ?? 0)
            if horizontal {
                // Gathered on the lowest member's rail: the names rise into the lanes above, which
                // the bundle has emptied.
                let anchor = members.map { lane[$0] }.max() ?? lane[line]
                let base = topInset + CGFloat(anchor + 1) * laneSize - horizontalRailFromFoot + raise
                return base - CGFloat(members.count - 1) * bundleSpacing + k * bundleSpacing
            } else {
                // Gathered on the first member's rail: the names run on into the lanes after it.
                let anchor = members.map { lane[$0] }.min() ?? lane[line]
                return CGFloat(anchor) * laneSize + verticalRailInset + k * bundleSpacing
            }
        }

        var groupAt = lines.indices.map { line in
            lines[line].stops.indices.map { stop -> [Int] in
                let c = columnOf[line][stop]
                return groups[c].first { $0.contains(line) } ?? [line]
            }
        }
        for line in lines.indices {
            let own = groupAt[line]
            for stop in own.indices where own[stop].count == 1 {
                guard let before = own[..<stop].last(where: { $0.count > 1 }),
                      let after = own[(stop + 1)...].first(where: { $0.count > 1 }),
                      before == after else { continue }
                // The others must be passing, not calling somewhere of their own.
                let column = columns[columnOf[line][stop]]
                guard before.allSatisfy({ $0 == line || column[$0] == nil }) else { continue }
                groupAt[line][stop] = before
            }
        }
        let across = lines.indices.map { line in
            lines[line].stops.indices.map { slot(of: line, in: groupAt[line][$0]) }
        }

        // 4. Along: a pitch per column, and more where a line bends into or out of a bundle, so
        // the bend is a curve rather than a step.
        var along = [CGFloat](repeating: 0, count: columns.count)
        let firstColumns = lines.indices.map { columnOf[$0][0] }
        // The badges of lines starting at the same column stack along, ahead of their first stop.
        let badgeStack = lines.indices.map { line in
            lines.indices.filter { $0 < line && firstColumns[$0] == firstColumns[line] && across[$0][0] != across[line][0]
                && abs(across[$0][0] - across[line][0]) < badgeSide }.count
        }
        let badgeReach = (badgeSide + 6) * CGFloat((badgeStack.max() ?? 0) + 1) + 8
        along[0] = leadingMargin + badgeReach
        for c in columns.indices.dropFirst() {
            var position = along[c - 1] + pitch
            for line in lines.indices {
                for stop in lines[line].stops.indices.dropFirst() where columnOf[line][stop] == c {
                    let shift = abs(across[line][stop] - across[line][stop - 1])
                    guard shift > 0.5 else { continue }
                    let bend = max(pitch * 1.5, shift * 0.7)
                    position = max(position, along[columnOf[line][stop - 1]] + bend)
                }
            }
            along[c] = position
        }

        func point(along a: CGFloat, across x: CGFloat) -> CGPoint {
            horizontal ? CGPoint(x: a, y: x) : CGPoint(x: x, y: a)
        }

        // 5. Rails.
        var routeLines: [FullRouteLine] = []
        for (line, input) in lines.enumerated() {
            let centers = input.stops.indices.map { point(along: along[columnOf[line][$0]], across: across[line][$0]) }
            let segments: [FullRouteSegment] = centers.indices.dropLast().map { i in
                let from = centers[i], to = centers[i + 1]
                let a0 = along[columnOf[line][i]], a1 = along[columnOf[line][i + 1]]
                let half = (a1 - a0) / 2
                return FullRouteSegment(from: from, to: to,
                                        control1: point(along: a0 + half, across: across[line][i]),
                                        control2: point(along: a1 - half, across: across[line][i + 1]),
                                        bends: abs(across[line][i] - across[line][i + 1]) > 0.5,
                                        faded: i >= userIndex[line])
            }
            let badgeAlong = along[columnOf[line][0]] - badgeSide / 2 - 14
                - CGFloat(badgeStack[line]) * (badgeSide + 6)
            routeLines.append(FullRouteLine(lineID: input.id, number: input.number, colorIndex: input.colorIndex,
                                            badgeCenter: point(along: badgeAlong, across: across[line][0]),
                                            stopCenters: centers, segments: segments,
                                            userStopIndex: userIndex[line]))
        }

        /// Where a line's rail is at a point along the route, between its stops or on a bend; nil
        /// before its first stop or after its last.
        func railAcross(_ line: Int, atAlong a: CGFloat) -> CGFloat? {
            let cols = columnOf[line]
            guard let first = cols.first, let last = cols.last,
                  a >= along[first] - 0.5, a <= along[last] + 0.5 else { return nil }
            guard let next = cols.firstIndex(where: { along[$0] >= a }) else { return nil }
            if next == 0 || abs(along[cols[next]] - a) < 0.5 { return across[line][next] }
            let a0 = along[cols[next - 1]], a1 = along[cols[next]]
            let p = routeLines[line].segments[next - 1].point(at: (a - a0) / max(1, a1 - a0))
            return horizontal ? p.y : p.x
        }

        // 6. Marks and names: one per stop per group of lines calling there.
        let contentAcross = topInset + laneSize * CGFloat(lines.count)
        let labelGap: CGFloat = horizontal ? horizontalLabelGap : 32
        let fontSize = labelFontSize
        var stops: [FullRouteStop] = []
        for (c, column) in columns.enumerated() {
            for group in groups[c] {
                let members = group.sorted { lane[$0] < lane[$1] }
                let first = members[0]
                let stopIndex = column[first]!
                let stop = lines[first].stops[stopIndex]
                let memberAcross = members.map { across[$0][column[$0]!] }
                let centers = memberAcross.map { point(along: along[c], across: $0) }
                let low = memberAcross.min()!, high = memberAcross.max()!
                let otherLines = lines.indices.filter { !members.contains($0) }
                let others = otherLines.compactMap { railAcross($0, atAlong: along[c]) }
                let role: FullRouteStopRole = c == userColumn ? .userStop
                    : members.allSatisfy({ column[$0]! == lines[$0].stops.count - 1 }) && members.count == 1 ? .lastStop
                    : .stop
                let anchor: CGPoint
                let width: CGFloat
                if horizontal {
                    anchor = point(along: along[c], across: low - labelGap)
                    // The name climbs at −35° from its stop and reaches on past it, so it is
                    // walked along: it stops short of the first rail it would meet, whether that
                    // rail runs straight above or bends down across its path.
                    let angle = horizontalLabelAngle
                    let textLines: CGFloat = role == .userStop ? 3 : 2
                    let thickness = textLines * fontSize * 1.25 / cos(angle)
                    var reach = horizontalLabelReach
                    for step in 0...14 {
                        let dx = CGFloat(step) * horizontalLabelReach * cos(angle) / 14
                        let baseline = anchor.y - dx * tan(angle)
                        let top = baseline - thickness
                        let hit = otherLines.compactMap { railAcross($0, atAlong: along[c] + dx) }.contains {
                            $0 + railWidth / 2 + 4 > top && $0 - railWidth / 2 < anchor.y && $0 < low - 1
                        }
                        // Above the content's top edge counts as a rail too.
                        if hit || top < 0 { reach = dx / cos(angle) - 6; break }
                    }
                    width = min(horizontalLabelReach, max(40, reach))
                } else {
                    anchor = point(along: along[c], across: high + labelGap)
                    // Two lines of name take a band either side of the stop; a rail bending
                    // through that band is as much in the way as one running past.
                    let band = fontSize * 1.25
                    let nearby = otherLines.flatMap { line in
                        [-band, 0, band].compactMap { railAcross(line, atAlong: along[c] + $0) }
                    }
                    let wall = nearby.filter { $0 > high + 1 }.min().map { $0 - railWidth / 2 - 8 } ?? contentAcross - 8
                    width = min(240, max(48, wall - anchor.x))
                }
                stops.append(FullRouteStop(id: "\(c)#\(stop.code)", code: stop.code, name: stop.name,
                                           lineIDs: members.map { lines[$0].id },
                                           colorIndex: lines[first].colorIndex,
                                           center: point(along: along[c], across: (low + high) / 2),
                                           memberCenters: centers, role: role,
                                           isPastUserStop: c > userColumn,
                                           labelAnchor: anchor, labelMaxWidth: width))
            }
        }

        // 7. Buses, on the same curves as the rails.
        let pucks: [PuckMark] = request.vehicles.compactMap { vehicle in
            guard let line = lines.firstIndex(where: { $0.id == vehicle.lineID }) else { return nil }
            let route = routeLines[line]
            let index = min(max(0, vehicle.lastStopIndex), route.stopCenters.count - 1)
            let center = index < route.segments.count
                ? route.segments[index].point(at: CGFloat(vehicle.progressToNext))
                : route.stopCenters[index]
            return PuckMark(id: vehicle.id, vehicleID: vehicle.id, lineID: route.lineID, lineNumber: route.number,
                            colorIndex: route.colorIndex, center: center,
                            size: CGSize(width: 44, height: 34), cornerRadius: 10, fontSize: 18,
                            haloWidth: 4, ringWidth: 4, isSelected: vehicle.isSelected, dimmed: false)
        }

        let alongLength = (along.last ?? 0) + (horizontal ? horizontalTrailingInset : verticalTrailingInset)
        return FullRouteScene(axis: request.axis,
                              contentSize: horizontal ? CGSize(width: alongLength, height: contentAcross)
                                                      : CGSize(width: contentAcross, height: alongLength),
                              lines: routeLines, stops: stops, pucks: pucks,
                              userStopAlong: along[userColumn],
                              userStopCenter: stops.first { $0.role == .userStop }?.center
                                ?? point(along: along[userColumn], across: 0),
                              railWidth: railWidth, ringRadius: 8, ringStroke: 4, nodeRadius: 12,
                              badgeSide: badgeSide, labelRotation: horizontal ? -35 : 0,
                              labelFontSize: fontSize)
    }

    /// Lanes in the order that keeps lines running together side by side, so no line has to cross
    /// another to join its bundle. Ties keep the order the lines were picked in.
    static func laneOrder(lineCount: Int, groups: [[[Int]]], userColumn: Int) -> [Int] {
        let identity = Array(0..<lineCount)
        guard lineCount > 2, lineCount <= 4 else { return identity }
        func penalty(_ lane: [Int]) -> Int {
            var total = 0
            for (c, column) in groups.enumerated() where c != userColumn {
                for group in column where group.count > 1 {
                    let lanes = group.map { lane[$0] }
                    if lanes.max()! - lanes.min()! != group.count - 1 { total += 1 }
                }
            }
            return total
        }
        var best = identity
        var bestPenalty = penalty(identity)
        for order in permutations(identity) {
            // `order[k]` is the line in lane k; `lane[line]` is the inverse.
            var lane = identity
            for (k, line) in order.enumerated() { lane[line] = k }
            let p = penalty(lane)
            if p < bestPenalty { best = lane; bestPenalty = p }
        }
        return best
    }

    private static func permutations(_ items: [Int]) -> [[Int]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { i -> [[Int]] in
            var rest = items
            let head = rest.remove(at: i)
            return permutations(rest).map { [head] + $0 }
        }
    }
}

/// Lines up the stops of several routes into shared columns, as a diff lines up two texts.
///
/// Every route is cut at the rider's stop, which is one column for all of them. The parts before it
/// are aligned to end there and the parts after it to start there. Within a part a stop two lines
/// share is worth a column of its own; stops a line has to itself sit beside the others' own stops
/// rather than after them, so independent stretches run in parallel instead of end to end.
nonisolated enum RouteAlignment {
    static let matchScore = 4
    static let gapScore = -1

    /// Each column maps a line's index to the index of its stop there.
    static func columns(lines: [[String]], userIndices: [Int]) -> [[Int: Int]] {
        let before = lines.indices.map { line in
            (0..<userIndices[line]).map { (line: line, stop: $0, code: lines[line][$0]) }
        }
        let after = lines.indices.map { line in
            ((userIndices[line] + 1)..<lines[line].count).map { (line: line, stop: $0, code: lines[line][$0]) }
        }
        let userColumn = Dictionary(uniqueKeysWithValues: lines.indices.map { ($0, userIndices[$0]) })
        // After the stop the parts start together, so they are aligned back to front, reversed.
        let reversedAfter = progressive(after.map { Array($0.reversed()) })
        return progressive(before) + [userColumn] + reversedAfter.reversed()
    }

    private typealias Entry = (line: Int, stop: Int, code: String)

    /// Aligns each part to the columns of the parts before it, ending all of them together.
    private static func progressive(_ parts: [[Entry]]) -> [[Int: Int]] {
        var profile: [[Entry]] = []
        for part in parts where !part.isEmpty {
            profile = profile.isEmpty ? part.map { [$0] } : align(profile, part)
        }
        return profile.map { column in Dictionary(uniqueKeysWithValues: column.map { ($0.line, $0.stop) }) }
    }

    /// Needleman–Wunsch with free leading gaps: the columns and the new part must end together,
    /// but either may start later. Ties go to pairing, which pushes the gaps to the front.
    private static func align(_ profile: [[Entry]], _ part: [Entry]) -> [[Entry]] {
        let n = profile.count, m = part.count
        var score = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        func pair(_ i: Int, _ j: Int) -> Int {
            profile[i].contains { $0.code == part[j].code } ? matchScore : 0
        }
        for i in 1...n {
            for j in 1...m {
                score[i][j] = max(score[i - 1][j - 1] + pair(i - 1, j - 1),
                                  score[i - 1][j] + gapScore,
                                  score[i][j - 1] + gapScore)
            }
        }
        var result: [[Entry]] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, score[i][j] == score[i - 1][j - 1] + pair(i - 1, j - 1) {
                result.append(profile[i - 1] + [part[j - 1]])
                i -= 1; j -= 1
            } else if i > 0, j == 0 || score[i][j] == score[i - 1][j] + gapScore {
                result.append(profile[i - 1])
                i -= 1
            } else {
                result.append([part[j - 1]])
                j -= 1
            }
        }
        return result.reversed()
    }
}

/// The strip under the full route: the whole of it squeezed into a few points, with a window on
/// the part the main view shows. The route always runs left to right in the strip, whichever way
/// the main view scrolls, so the strip reads the same in both orientations.
///
/// Across, the strip shows only the band the rails take, centred: a lane's names take most of its
/// height and mean nothing at this size, so one line is drawn through the middle of the strip
/// rather than along its foot.
nonisolated struct FullRouteMinimap: Hashable, Sendable {
    var axis: MapAxis
    var content: CGSize
    var strip: CGSize
    /// The span the rails take across the content. Nil maps the whole content across.
    var railsAcross: ClosedRange<CGFloat>? = nil

    /// Kept clear at the strip's top and bottom, for a rail's stroke and a bus's mark.
    static let padding: CGFloat = 6
    /// How far the window's outline sits inside the strip, so it is never cut off at an edge.
    static let windowInset: CGFloat = 1.5

    private var contentAlong: CGFloat { axis == .horizontal ? content.width : content.height }
    private var contentAcross: CGFloat { axis == .horizontal ? content.height : content.width }
    private var alongScale: CGFloat { contentAlong > 0 ? strip.width / contentAlong : 0 }
    private var band: ClosedRange<CGFloat> { railsAcross ?? 0...contentAcross }
    private var bandMiddle: CGFloat { (band.lowerBound + band.upperBound) / 2 }
    private var acrossScale: CGFloat {
        let span = band.upperBound - band.lowerBound
        guard span > 0 else { return 0 }
        return railsAcross == nil ? strip.height / span : max(0, strip.height - 2 * Self.padding) / span
    }

    /// A point of the content, in the strip.
    func point(_ p: CGPoint) -> CGPoint {
        let along = axis == .horizontal ? p.x : p.y
        let across = axis == .horizontal ? p.y : p.x
        return CGPoint(x: along * alongScale, y: strip.height / 2 + (across - bandMiddle) * acrossScale)
    }

    /// What the main view shows, in the strip, kept inside it so its outline is drawn whole. A
    /// view that takes in every rail across is the strip's full height.
    func window(visible: CGRect) -> CGRect {
        let a = point(visible.origin)
        let b = point(CGPoint(x: visible.maxX, y: visible.maxY))
        let inset = Self.windowInset
        let visibleAcross = axis == .horizontal ? visible.minY...visible.maxY : visible.minX...visible.maxX
        let coversBand = visibleAcross.lowerBound <= band.lowerBound + 0.5
            && visibleAcross.upperBound >= band.upperBound - 0.5
        let x0 = min(max(min(a.x, b.x), inset), strip.width - inset)
        let x1 = min(max(max(a.x, b.x), inset), strip.width - inset)
        let y0 = coversBand ? inset : min(max(min(a.y, b.y), inset), strip.height - inset)
        let y1 = coversBand ? strip.height - inset : min(max(max(a.y, b.y), inset), strip.height - inset)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    /// Where to scroll the main view so its window centres on a point of the strip.
    func offset(centeredOn stripPoint: CGPoint, visible: CGSize) -> CGPoint {
        let along = alongScale > 0 ? stripPoint.x / alongScale : 0
        let across = acrossScale > 0 ? bandMiddle + (stripPoint.y - strip.height / 2) / acrossScale : bandMiddle
        let center = axis == .horizontal ? CGPoint(x: along, y: across) : CGPoint(x: across, y: along)
        return Self.clamp(CGPoint(x: center.x - visible.width / 2, y: center.y - visible.height / 2),
                          visible: visible, content: content)
    }

    /// Keeps a scroll offset inside the content; a content smaller than the view stays at zero.
    static func clamp(_ offset: CGPoint, visible: CGSize, content: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, offset.x), max(0, content.width - visible.width)),
                y: min(max(0, offset.y), max(0, content.height - visible.height)))
    }
}

/// Prev and next in the full route: from one bus to the one before or after it along the route.
/// Buses run in order of how far along they are, and across the lanes where two sit level.
nonisolated enum FullRouteNavigation {
    /// What the view was last moved to. A rider's own scroll lets go of it, and the steps then go
    /// from whatever is in the middle of the view.
    enum Focus: Hashable, Sendable {
        case userStop
        case bus(String)
        case free
    }

    static func ordered(_ pucks: [PuckMark], axis: MapAxis) -> [PuckMark] {
        pucks.sorted { a, b in
            let (alongA, acrossA) = axis == .horizontal ? (a.center.x, a.center.y) : (a.center.y, a.center.x)
            let (alongB, acrossB) = axis == .horizontal ? (b.center.x, b.center.y) : (b.center.y, b.center.x)
            return abs(alongA - alongB) > 0.5 ? alongA < alongB : acrossA < acrossB
        }
    }

    /// The bus one step before (`-1`) or after (`+1`) the focus, or nil at the end of the line.
    /// - Parameter visibleCenterAlong: the middle of the view along the route, for a free focus.
    static func step(_ direction: Int, from focus: Focus, in scene: FullRouteScene,
                     visibleCenterAlong: CGFloat) -> PuckMark? {
        let buses = ordered(scene.pucks, axis: scene.axis)
        func along(_ puck: PuckMark) -> CGFloat { scene.axis == .horizontal ? puck.center.x : puck.center.y }
        let reference: CGFloat
        switch focus {
        case .bus(let id):
            if let index = buses.firstIndex(where: { $0.vehicleID == id }) {
                let next = index + direction
                return buses.indices.contains(next) ? buses[next] : nil
            }
            // The bus finished its run since: step from where the view is.
            reference = visibleCenterAlong
        case .userStop:
            reference = scene.userStopAlong
        case .free:
            reference = visibleCenterAlong
        }
        // A bus standing at the rider's stop is the first one back from it, not one to skip.
        let slack: CGFloat = focus == .userStop ? -0.5 : 0.5
        return direction < 0 ? buses.last { along($0) < reference - slack }
                             : buses.first { along($0) > reference + 0.5 }
    }
}
