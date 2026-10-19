import Foundation
import CoreGraphics

/// Turns route data plus live positions into the value-typed scene the views draw.
///
/// Pure and deterministic: no clock, no randomness, no SwiftUI. It computes in (along, across)
/// — along being the direction of travel — and converts to view coordinates exactly once, at the
/// end, so landscape and portrait share every rule.
nonisolated enum MapLayoutEngine {

    // MARK: Internal working state

    /// One stretch of rail between two anchors.
    private struct Piece {
        var from: CGFloat
        var to: CGFloat
        var dashed: Bool
    }

    private struct Placement {
        var positions: [Int: CGFloat] = [:]
        var dashSpans: [(range: Range<Int>, from: CGFloat, to: CGFloat)] = []
        var tailPitch: CGFloat = 0
        var lastDrawnAlong: CGFloat = 0
    }

    private struct LineLayout {
        var line: MapLineInput
        var isTrunk: Bool
        var rowAcross: CGFloat
        var parallelAcross: CGFloat?
        var junction: JunctionResult
        var compressed: CompressedLine
        var stopAlong: [CGFloat]
        var drawnOwnIndices: [Int] = []
        var dashes: [DashRun] = []
        var pieces: [(piece: Piece, across: CGFloat)] = []
        var segments: [RailSegment] = []
        var dimmed: Bool = false
    }

    // MARK: Entry point

    static func layout(_ request: MapLayoutRequest) -> MapScene {
        let axis = request.axis
        let alongExtent = axis == .horizontal ? request.canvasSize.width : request.canvasSize.height
        let acrossExtent = axis == .horizontal ? request.canvasSize.height : request.canvasSize.width

        // 1. Drop anything that cannot be drawn: a line must reach the user's stop and have a route.
        let valid = request.lines.filter { line in
            line.stops.count >= 2 && line.stops.contains { $0.code == request.userStopCode }
        }
        let metrics = MapMetrics(preset: request.preset, scale: request.scale, lineCount: valid.count)
        let tailBudget = max(1, request.tailBudget ?? metrics.tailBudget)
        let headCount = max(0, request.headCount ?? metrics.headCount)
        let minimumPitch = request.minimumStopPitch ?? 0
        let center = acrossExtent / 2

        guard let trunk = valid.first(where: { $0.id == request.trunkLineID }) ?? valid.first else {
            return emptyScene(request: request, metrics: metrics,
                              nodeAlong: alongExtent - metrics.nodeInsetFromEnd, center: center)
        }
        // Where the trunk goes on past the user's stop, the node moves back to make room for its
        // next stop; everything measured from the node moves with it.
        let nodeAlong = alongExtent - onwardRoom(trunk.onward, metrics: metrics)
        let others = valid.filter { $0.id != trunk.id }

        // 2. Across position of each line's own rail.
        let rowAcross = acrossPositions(trunk: trunk, others: others, selectionOrder: valid,
                                        center: center, metrics: metrics)

        // 3. Junctions, measured against the trunk only — never line against line.
        var junctions: [String: JunctionResult] = [:]
        for line in others {
            junctions[line.id] = JunctionDetector.junction(of: line, onto: trunk, userStopCode: request.userStopCode)
        }

        // 4. Which side of the trunk each joined rail runs on. Two rails never share an offset.
        let parallelAcross = parallelSides(others: others, junctions: junctions, rowAcross: rowAcross,
                                           center: center, trunk: trunk, metrics: metrics)

        // 5. The trunk's shared corridor starts at the earliest junction any line makes with it.
        let trunkN = (trunk.stops.count - 1)
        let earliestJunction = others.compactMap { junctions[$0.id]?.trunkJunctionIndex }.min()
        let trunkShared = earliestJunction.map { $0 ..< trunkN } ?? (trunkN ..< trunkN)

        // 6. Compress and place the trunk.
        let lastTailAlong = nodeAlong - metrics.lastTailFromNode
        let terminusEnd = metrics.terminusCenterAlong + metrics.terminusAlong / 2
        var trunkCompressed = RouteCompressor.compress(line: trunk, shared: trunkShared,
                                                       headCount: headCount, tailBudget: tailBudget)
        var trunkPlacement = place(runs: trunkCompressed.runs, firstAlong: metrics.firstStopAlong,
                                   endAlong: lastTailAlong, terminusEnd: terminusEnd,
                                   minimumPitch: minimumPitch, metrics: metrics)
        // A canvas too short for the tail: spend the head on the dash instead of crushing the pitch.
        if trunkPlacement.tailPitch < 0.6 * metrics.stopPitch && headCount > 0 {
            trunkCompressed = RouteCompressor.compress(line: trunk, shared: trunkShared,
                                                       headCount: 0, tailBudget: tailBudget)
            trunkPlacement = place(runs: trunkCompressed.runs, firstAlong: metrics.firstStopAlong,
                                   endAlong: lastTailAlong, terminusEnd: terminusEnd,
                                   minimumPitch: minimumPitch, metrics: metrics)
        }

        var layouts: [LineLayout] = []

        var trunkLayout = LineLayout(line: trunk, isTrunk: true, rowAcross: center, parallelAcross: nil,
                                     junction: .none, compressed: trunkCompressed,
                                     stopAlong: alongArray(count: trunk.stops.count, placement: trunkPlacement,
                                                           nodeAlong: nodeAlong, metrics: metrics))
        trunkLayout.drawnOwnIndices = trunkCompressed.drawnStopIndices
        layouts.append(trunkLayout)

        // 7. Place every other line against the trunk's positions.
        for line in others {
            let junction = junctions[line.id] ?? .none
            let row = rowAcross[line.id] ?? center
            let n = line.stops.count - 1
            var stopAlong = [CGFloat](repeating: 0, count: line.stops.count)
            stopAlong[n] = nodeAlong
            var drawnOwn: [Int] = []
            var dashSpans: [(range: Range<Int>, from: CGFloat, to: CGFloat)] = []

            if let lineJunction = junction.lineJunctionIndex, let trunkJunction = junction.trunkJunctionIndex {
                // Shared stops take the trunk's positions, which is what makes capsules and bundle
                // dashes line up across the whole bundle.
                for j in lineJunction ..< n {
                    let trunkIndex = trunkJunction + (j - lineJunction)
                    stopAlong[j] = trunkLayout.stopAlong[min(trunkIndex, trunkN)]
                }
                let junctionAlong = stopAlong[lineJunction]

                let ownRuns = trailingTrimmed(runs: RouteCompressor.compress(
                    line: line, shared: lineJunction ..< n,
                    headCount: headCount, tailBudget: tailBudget).runs, below: lineJunction)
                if !ownRuns.isEmpty {
                    let placement = place(runs: ownRuns, firstAlong: metrics.firstStopAlong,
                                          endAlong: max(terminusEnd + metrics.stopPitch,
                                                        junctionAlong - metrics.stopPitch),
                                          terminusEnd: terminusEnd, minimumPitch: minimumPitch, metrics: metrics)
                    for (index, along) in placement.positions { stopAlong[index] = along }
                    drawnOwn = ownRuns.compactMap { if case .stop(let i) = $0 { i } else { nil } }
                    dashSpans = placement.dashSpans
                }
                stopAlong[0] = junction.lineIsSubsetOfTrunk ? junctionAlong : metrics.terminusCenterAlong

                var layout = LineLayout(line: line, isTrunk: false, rowAcross: row,
                                        parallelAcross: parallelAcross[line.id], junction: junction,
                                        compressed: CompressedLine(lineID: line.id, runs: ownRuns,
                                                                   ownTailCount: drawnOwn.count, sharedDashed: nil),
                                        stopAlong: stopAlong)
                layout.drawnOwnIndices = drawnOwn
                layout.dashes = dashRuns(spans: dashSpans, lineID: line.id, across: row, metrics: metrics, showLabel: true)
                layouts.append(layout)
            } else {
                // Independent all the way: laid out exactly like the trunk, so the stop columns
                // still line up across rows.
                var compressed = RouteCompressor.compress(line: line, shared: n ..< n,
                                                          headCount: headCount, tailBudget: tailBudget)
                var placement = place(runs: compressed.runs, firstAlong: metrics.firstStopAlong,
                                      endAlong: lastTailAlong, terminusEnd: terminusEnd,
                                      minimumPitch: minimumPitch, metrics: metrics)
                if placement.tailPitch < 0.6 * metrics.stopPitch && headCount > 0 {
                    compressed = RouteCompressor.compress(line: line, shared: n ..< n,
                                                          headCount: 0, tailBudget: tailBudget)
                    placement = place(runs: compressed.runs, firstAlong: metrics.firstStopAlong,
                                      endAlong: lastTailAlong, terminusEnd: terminusEnd,
                                      minimumPitch: minimumPitch, metrics: metrics)
                }
                var layout = LineLayout(line: line, isTrunk: false, rowAcross: row, parallelAcross: nil,
                                        junction: .none, compressed: compressed,
                                        stopAlong: alongArray(count: line.stops.count, placement: placement,
                                                              nodeAlong: nodeAlong, metrics: metrics))
                layout.drawnOwnIndices = compressed.drawnStopIndices
                layout.dashes = dashRuns(spans: placement.dashSpans, lineID: line.id, across: row,
                                         metrics: metrics, showLabel: true)
                layouts.append(layout)
            }
        }

        layouts[0].dashes = dashRuns(spans: trunkPlacement.dashSpans, lineID: trunk.id, across: center,
                                     metrics: metrics, showLabel: true)

        // 8. Rails.
        let railsEnd = nodeAlong - metrics.railsEndFromNode
        for index in layouts.indices {
            layouts[index].dimmed = request.highlightedLineID != nil && layouts[index].line.id != request.highlightedLineID
            layouts[index].segments = railSegments(for: layouts[index], trunkLayout: layouts[0],
                                                   trunkPlacement: trunkPlacement, center: center,
                                                   nodeAlong: nodeAlong, railsEnd: railsEnd,
                                                   terminusEnd: terminusEnd, metrics: metrics)
        }

        // 9. Bundle dashes repeat on every rail of the bundle, but the caption is written once.
        for index in layouts.indices where layouts[index].parallelAcross != nil {
            guard let trunkJunction = layouts[index].junction.trunkJunctionIndex else { continue }
            let across = layouts[index].parallelAcross ?? center
            let shared = trunkPlacement.dashSpans.filter { $0.range.lowerBound >= trunkJunction }
            layouts[index].dashes += dashRuns(spans: shared, lineID: layouts[index].line.id,
                                              across: across, metrics: metrics, showLabel: false)
        }

        // 10. Marks, labels and pucks.
        let marks = stopMarks(layouts: layouts, trunkLayout: layouts[0], center: center, metrics: metrics)
        // Portrait names sit in a column outside the widest point of the bundle; landscape names
        // rise away from the rail and need no such clearance.
        let labelColumn = request.axis == .vertical
            ? max(center + metrics.labelOffset,
                  (marks.filter { $0.kind == .capsule }.map(\.capsuleRect.maxY).max() ?? center) + 14 * request.scale)
            : center + metrics.labelOffset
        let labels = stopLabels(layouts: layouts, trunkLayout: layouts[0], request: request,
                                center: center, trunkLabelAcross: labelColumn, metrics: metrics)
        let termini = terminusMarks(layouts: layouts, metrics: metrics)
        let pucks = puckMarks(layouts: layouts, request: request, nodeAlong: nodeAlong, metrics: metrics)
        let convergence = convergenceMark(nodeAlong: nodeAlong, center: center, metrics: metrics, axis: axis)
        let onward = onwardMark(trunk: trunk, nodeAlong: nodeAlong, center: center,
                                labelAcross: labelColumn, metrics: metrics)

        // 11. Convert to view coordinates.
        let rails = layouts.map { layout in
            RailNode(lineID: layout.line.id, colorIndex: layout.line.colorIndex,
                     width: metrics.railWidth,
                     segments: layout.segments.map { MapAxisTransform.segment($0, axis) },
                     isTrunk: layout.isTrunk, dimmed: layout.dimmed)
        }
        // Non-trunk rails first so the trunk reads as the spine, drawn over them.
        let orderedRails = rails.filter { !$0.isTrunk } + rails.filter(\.isTrunk)

        var stopAlongByLine: [String: [CGFloat]] = [:]
        for layout in layouts { stopAlongByLine[layout.line.id] = layout.stopAlong }

        let scene = MapScene(
            axis: axis,
            preset: request.preset,
            scale: request.scale,
            trunkLineID: trunk.id,
            rails: orderedRails,
            termini: termini.map { mark in
                var m = mark
                m.rect = MapAxisTransform.rect(mark.rect, axis)
                return m
            },
            dashes: layouts.flatMap(\.dashes).map { dash in
                var d = dash
                if axis == .vertical {
                    // Put the caption in the same column as the names rather than centred on the
                    // rail, where the words would sit on top of the track.
                    if abs(dash.from.y - center) <= metrics.parallelOffset {
                        d.labelCenter = CGPoint(x: dash.labelCenter.x, y: labelColumn)
                        d.labelAlignment = .leading
                    } else if metrics.namesSitRightOfEveryRail {
                        d.labelCenter = CGPoint(x: dash.labelCenter.x, y: dash.from.y + metrics.labelOffset)
                        d.labelAlignment = .leading
                    } else {
                        d.labelCenter = CGPoint(x: dash.labelCenter.x, y: dash.from.y - metrics.trailingLabelOffset)
                        d.labelAlignment = .trailing
                    }
                }
                d.from = MapAxisTransform.point(d.from, axis)
                d.to = MapAxisTransform.point(d.to, axis)
                d.labelCenter = MapAxisTransform.point(d.labelCenter, axis)
                d.dimmed = layouts.first { $0.line.id == dash.lineID }?.dimmed ?? false
                // A distance spine says where the bus is, not what it passes — so it carries no
                // stop names and no "+N STOPS" either.
                if let named = request.namedLineIDs, !named.contains(dash.lineID) { d.showLabel = false }
                return d
            },
            stops: marks.map { mark in
                var m = mark
                m.center = MapAxisTransform.point(mark.center, axis)
                m.capsuleRect = MapAxisTransform.rect(mark.capsuleRect, axis)
                return m
            },
            labels: labels.map { label in
                var l = label
                l.anchor = MapAxisTransform.point(label.anchor, axis)
                return l
            },
            pucks: pucks.map { puck in
                var p = puck
                p.center = MapAxisTransform.point(puck.center, axis)
                return p
            },
            convergence: convergence,
            hintAnchor: request.preset == .landscape
                ? MapAxisTransform.point(CGPoint(x: 40 * request.scale, y: acrossExtent - 32 * request.scale), axis)
                : nil,
            stopAlong: stopAlongByLine,
            onward: onward.map { mark in
                var m = mark
                m.segments = mark.segments.map { MapAxisTransform.segment($0, axis) }
                m.stop = mark.stop.map { stop in
                    var s = stop
                    s.center = MapAxisTransform.point(stop.center, axis)
                    return s
                }
                m.terminus = mark.terminus.map { terminus in
                    var t = terminus
                    t.rect = MapAxisTransform.rect(terminus.rect, axis)
                    return t
                }
                m.label.anchor = MapAxisTransform.point(mark.label.anchor, axis)
                m.fadeFrom = MapAxisTransform.point(mark.fadeFrom, axis)
                m.fadeTo = MapAxisTransform.point(mark.fadeTo, axis)
                return m
            }
        )
        return scene.keepingNamesInside(height: acrossExtent)
    }
}

// MARK: - Geometry helpers

private nonisolated extension MapLayoutEngine {

    private static func emptyScene(request: MapLayoutRequest, metrics: MapMetrics,
                           nodeAlong: CGFloat, center: CGFloat) -> MapScene {
        MapScene(axis: request.axis, preset: request.preset, scale: request.scale,
                 trunkLineID: "", rails: [], termini: [], dashes: [], stops: [], labels: [],
                 pucks: [], convergence: convergenceMark(nodeAlong: nodeAlong, center: center,
                                                         metrics: metrics, axis: request.axis),
                 hintAnchor: nil, stopAlong: [:])
    }

    /// The trunk owns the centre. In landscape and on iPad the other lines take a side each; the
    /// phone puts them all to the left so the trunk's names always own the right of the screen.
    private static func acrossPositions(trunk: MapLineInput, others: [MapLineInput], selectionOrder: [MapLineInput],
                                center: CGFloat, metrics: MapMetrics) -> [String: CGFloat] {
        var result: [String: CGFloat] = [trunk.id: center]
        guard !others.isEmpty else { return result }

        if metrics.rowsAreSigned {
            if others.count >= 2 {
                result[others[0].id] = center - metrics.rowOffsets[0]
                result[others[1].id] = center + metrics.rowOffsets[1]
            } else {
                let otherIsFirst = (selectionOrder.firstIndex { $0.id == others[0].id } ?? 0)
                    < (selectionOrder.firstIndex { $0.id == trunk.id } ?? 0)
                result[others[0].id] = otherIsFirst ? center - metrics.rowOffsets[0] : center + metrics.rowOffsets[0]
            }
        } else {
            for (index, line) in others.enumerated() {
                result[line.id] = center - metrics.rowOffsets[min(index, metrics.rowOffsets.count - 1)]
            }
        }
        return result
    }

    /// A joined rail runs 18 pt above or below the trunk, keeping its own colour. Two rails of one
    /// bundle never take the same offset: the line that joins earlier keeps the side it wants.
    private static func parallelSides(others: [MapLineInput], junctions: [String: JunctionResult],
                              rowAcross: [String: CGFloat], center: CGFloat,
                              trunk: MapLineInput, metrics: MapMetrics) -> [String: CGFloat] {
        let joined = others
            .filter { junctions[$0.id]?.hasJunction == true }
            .sorted { (junctions[$0.id]?.trunkJunctionIndex ?? 0) < (junctions[$1.id]?.trunkJunctionIndex ?? 0) }

        var used: Set<CGFloat> = []
        var result: [String: CGFloat] = [:]
        for line in joined {
            let row = rowAcross[line.id] ?? center
            var sign: CGFloat = metrics.rowsAreSigned ? (row < center ? -1 : 1) : -1
            if used.contains(sign) { sign = -sign }
            used.insert(sign)
            result[line.id] = center + sign * metrics.parallelOffset
        }
        return result
    }

    /// Places one contiguous stretch of a route: head stops run forward from the front, tail stops
    /// run backwards from the end, and the dash takes whatever is between them.
    private static func place(runs: [DrawnRunKind], firstAlong: CGFloat, endAlong: CGFloat,
                      terminusEnd: CGFloat, minimumPitch: CGFloat, metrics: MapMetrics) -> Placement {
        var placement = Placement(tailPitch: metrics.stopPitch)
        let drawn = runs.compactMap { if case .stop(let i) = $0 { i } else { nil } }
        guard !drawn.isEmpty else {
            placement.lastDrawnAlong = terminusEnd
            return placement
        }

        let clearance = 4 * metrics.scale
        guard let firstDash = runs.firstIndex(where: { if case .dash = $0 { true } else { false } }) else {
            // Everything is drawn. Spread backwards from the end so stop columns still line up
            // across rows, never starting before the first-stop mark.
            let gaps = max(1, drawn.count - 1)
            let pitch = min(metrics.stopPitch, max(0, (endAlong - firstAlong) / CGFloat(gaps)))
            for (offset, index) in drawn.enumerated() {
                placement.positions[index] = endAlong - CGFloat(drawn.count - 1 - offset) * pitch
            }
            placement.tailPitch = pitch
            placement.lastDrawnAlong = endAlong
            return placement
        }

        let head = runs[..<firstDash].compactMap { if case .stop(let i) = $0 { i } else { nil } }
        let rest = Array(runs[firstDash...])

        for (offset, index) in head.enumerated() {
            placement.positions[index] = firstAlong + CGFloat(offset) * metrics.stopPitch
        }
        let lastHeadAlong = head.isEmpty ? terminusEnd : (placement.positions[head[head.count - 1]] ?? firstAlong)

        // A route can need more than one dashed run — its own compression and the bundle's. Each
        // dash is a gap between two stops, and every stop that does not follow one is a pitch on
        // from the stop before it, so the space after the head divides into those two kinds of step.
        var dashCount = 0
        var pitchSteps = 0
        var followsDash = false
        for run in rest {
            if case .stop = run {
                if !followsDash { pitchSteps += 1 }
                followsDash = false
            } else {
                dashCount += 1
                followsDash = true
            }
        }

        // Shrink the tail pitch, not the dash: a dash below its minimum length stops reading as one.
        let room = endAlong - lastHeadAlong
        var tailPitch = metrics.stopPitch
        if pitchSteps > 0 {
            let reserved = CGFloat(dashCount) * (2 * (metrics.ringOuter + clearance) + metrics.minimumDashLength)
            tailPitch = min(metrics.stopPitch, max(0, (room - reserved) / CGFloat(pitchSteps)))
            // Held apart where the caller asks, out of the dashes' share, as far as there is room.
            if dashCount > 0 { tailPitch = max(tailPitch, min(minimumPitch, room / CGFloat(pitchSteps))) }
        }
        placement.tailPitch = tailPitch
        // Whatever the stops leave over belongs to the dashes, shared evenly between them.
        let dashGap = dashCount > 0 ? (room - CGFloat(pitchSteps) * tailPitch) / CGFloat(dashCount) : 0

        var cursor = lastHeadAlong
        var cursorIsStop = !head.isEmpty
        for run in rest {
            switch run {
            case .stop(let index):
                if cursorIsStop { cursor += tailPitch }
                placement.positions[index] = cursor
                cursorIsStop = true
            case .dash(let swallowed):
                let from = cursor + (cursorIsStop ? metrics.ringOuter + clearance : clearance)
                let nextStopAlong = cursor + dashGap
                let to = max(from, nextStopAlong - metrics.ringOuter - clearance)
                placement.dashSpans.append((range: swallowed, from: from, to: to))

                // Swallowed stops still exist: give them positions inside the dash so a bus crossing
                // that stretch keeps moving smoothly instead of jumping.
                let steps = CGFloat(swallowed.count + 1)
                for (offset, index) in swallowed.enumerated() {
                    placement.positions[index] = from + (to - from) * CGFloat(offset + 1) / steps
                }
                cursor = nextStopAlong
                cursorIsStop = false
            }
        }

        placement.lastDrawnAlong = endAlong
        return placement
    }

    private static func alongArray(count: Int, placement: Placement, nodeAlong: CGFloat, metrics: MapMetrics) -> [CGFloat] {
        var result = [CGFloat](repeating: 0, count: count)
        result[0] = metrics.terminusCenterAlong
        if count > 1 { result[count - 1] = nodeAlong }
        for (index, along) in placement.positions where index >= 0 && index < count {
            result[index] = along
        }
        return result
    }

    /// Keeps only the runs belonging to a line's own segment, before it reaches the trunk.
    private static func trailingTrimmed(runs: [DrawnRunKind], below limit: Int) -> [DrawnRunKind] {
        runs.filter { run in
            switch run {
            case .stop(let index): index < limit
            case .dash(let range): range.upperBound <= limit
            }
        }
    }

    private static func dashRuns(spans: [(range: Range<Int>, from: CGFloat, to: CGFloat)], lineID: String,
                         across: CGFloat, metrics: MapMetrics, showLabel: Bool,
                         labelAcross: CGFloat? = nil,
                         labelAlignment: LabelAlignment = .center) -> [DashRun] {
        spans.map { span in
            DashRun(id: "\(lineID)#dash\(span.range.lowerBound)-\(span.range.upperBound)", lineID: lineID,
                    from: CGPoint(x: span.from, y: across),
                    to: CGPoint(x: span.to, y: across),
                    swallowedCount: span.range.count,
                    fontSize: metrics.dashFontSize, trackingEm: metrics.dashTrackingEm,
                    labelCenter: CGPoint(x: (span.from + span.to) / 2,
                                         y: labelAcross ?? (across + metrics.dashLabelOffset)),
                    labelAlignment: labelAlignment,
                    showLabel: showLabel, dimmed: false)
        }
    }

    /// Solid stretches broken by the dashed runs that fall inside them.
    private static func pieces(from start: CGFloat, to end: CGFloat,
                       dashes: [(from: CGFloat, to: CGFloat)]) -> [Piece] {
        var result: [Piece] = []
        var cursor = start
        for dash in dashes.sorted(by: { $0.from < $1.from }) where dash.from >= start && dash.to <= end {
            if dash.from > cursor { result.append(Piece(from: cursor, to: dash.from, dashed: false)) }
            result.append(Piece(from: dash.from, to: dash.to, dashed: true))
            cursor = dash.to
        }
        if end > cursor { result.append(Piece(from: cursor, to: end, dashed: false)) }
        return result
    }

    private static func segments(_ pieces: [Piece], across: CGFloat, metrics: MapMetrics) -> [RailSegment] {
        var result: [RailSegment] = []
        for piece in pieces {
            let from = CGPoint(x: piece.from, y: across)
            let to = CGPoint(x: piece.to, y: across)
            if piece.dashed {
                result.append(.dashed(from: from, to: to, on: metrics.dashOn, off: metrics.dashOff))
            } else if case .line(let previousFrom, let previousTo)? = result.last,
                      previousTo == from, previousFrom.y == across {
                // Merge collinear solid stretches so a rail reads as one run of track.
                result[result.count - 1] = .line(from: previousFrom, to: to)
            } else {
                result.append(.line(from: from, to: to))
            }
        }
        return result
    }
}

// MARK: - Rails, marks, labels, pucks

private nonisolated extension MapLayoutEngine {

    private static func spans(_ dashes: [DashRun]) -> [(from: CGFloat, to: CGFloat)] {
        dashes.map { (from: $0.from.x, to: $0.to.x) }
    }

    private static func spans(_ dashes: [(range: Range<Int>, from: CGFloat, to: CGFloat)]) -> [(from: CGFloat, to: CGFloat)] {
        dashes.map { (from: $0.from, to: $0.to) }
    }

    private static func railSegments(for layout: LineLayout, trunkLayout: LineLayout,
                             trunkPlacement: Placement, center: CGFloat, nodeAlong: CGFloat,
                             railsEnd: CGFloat, terminusEnd: CGFloat, metrics: MapMetrics) -> [RailSegment] {
        if layout.isTrunk {
            // The spine: dead straight from its terminus to the stub, and it never bends.
            return segments(pieces(from: terminusEnd, to: railsEnd, dashes: spans(trunkPlacement.dashSpans)),
                            across: center, metrics: metrics)
        }

        guard let parallel = layout.parallelAcross,
              let lineJunction = layout.junction.lineJunctionIndex,
              let trunkJunction = layout.junction.trunkJunctionIndex else {
            // Independent rail: one curve into the stub at the very end.
            let curveStart = nodeAlong - metrics.curveStartFromNode
            var result = segments(pieces(from: terminusEnd, to: curveStart, dashes: spans(layout.dashes)),
                                  across: layout.rowAcross, metrics: metrics)
            result.append(.cubic(from: CGPoint(x: curveStart, y: layout.rowAcross),
                                 c1: CGPoint(x: nodeAlong - metrics.curveC1FromNode, y: layout.rowAcross),
                                 c2: CGPoint(x: nodeAlong - metrics.curveC2FromNode, y: center),
                                 to: CGPoint(x: railsEnd, y: center)))
            return result
        }

        var result: [RailSegment] = []
        let junctionAlong = layout.stopAlong[lineJunction]

        if !layout.drawnOwnIndices.isEmpty {
            // Its own route, then one curve onto the trunk's shoulder.
            let ownEnd = junctionAlong - metrics.junctionCurveLength
            result = segments(pieces(from: terminusEnd, to: ownEnd, dashes: spans(layout.dashes)),
                              across: layout.rowAcross, metrics: metrics)
            let mid = junctionAlong - metrics.junctionCurveLength / 2
            result.append(.cubic(from: CGPoint(x: ownEnd, y: layout.rowAcross),
                                 c1: CGPoint(x: mid, y: layout.rowAcross),
                                 c2: CGPoint(x: mid, y: parallel),
                                 to: CGPoint(x: junctionAlong, y: parallel)))
        }

        // From the junction on it runs parallel to the trunk, keeping its own colour, over exactly
        // the stops the trunk draws — which is what makes the bundle read as one corridor.
        let joinedCurveStart = nodeAlong - metrics.joinedCurveStartFromNode
        let sharedDashes = trunkPlacement.dashSpans.filter { $0.range.lowerBound >= trunkJunction }
        result += segments(pieces(from: junctionAlong, to: joinedCurveStart, dashes: spans(sharedDashes)),
                           across: parallel, metrics: metrics)
        result.append(.cubic(from: CGPoint(x: joinedCurveStart, y: parallel),
                             c1: CGPoint(x: nodeAlong - metrics.joinedCurveC1FromNode, y: parallel),
                             c2: CGPoint(x: nodeAlong - metrics.joinedCurveC2FromNode, y: center),
                             to: CGPoint(x: railsEnd, y: center)))
        return result
    }

    /// A stop served by more than one drawn line is one capsule spanning the whole bundle — the
    /// interchange mark. A stop on a single line is a ring in that line's colour.
    private static func stopMarks(layouts: [LineLayout], trunkLayout: LineLayout,
                          center: CGFloat, metrics: MapMetrics) -> [StopMark] {
        var rings: [StopMark] = []
        var capsules: [StopMark] = []
        let joined = layouts.filter { $0.parallelAcross != nil }
        let trunkLast = trunkLayout.line.stops.count - 1

        for index in trunkLayout.drawnOwnIndices where index < trunkLast {
            let along = trunkLayout.stopAlong[index]
            let code = trunkLayout.line.stops[index].code
            let active = joined.filter { ($0.junction.trunkJunctionIndex ?? Int.max) <= index }

            if active.isEmpty {
                rings.append(ring(id: "\(trunkLayout.line.id)#\(index)", code: code,
                                  center: CGPoint(x: along, y: center), colorIndex: trunkLayout.line.colorIndex,
                                  lineIDs: [trunkLayout.line.id], dimmed: trunkLayout.dimmed, metrics: metrics))
            } else {
                let acrossValues = [center] + active.compactMap(\.parallelAcross)
                let lowest = acrossValues.min() ?? center
                let highest = acrossValues.max() ?? center
                let rect = CGRect(x: along - metrics.capsuleWidth / 2,
                                  y: lowest - metrics.capsuleMargin,
                                  width: metrics.capsuleWidth,
                                  height: (highest - lowest) + 2 * metrics.capsuleMargin)
                capsules.append(StopMark(id: "shared#\(code)#\(index)", stopCode: code, kind: .capsule,
                                         center: CGPoint(x: along, y: (lowest + highest) / 2),
                                         ringRadius: 0, strokeWidth: metrics.capsuleStroke,
                                         capsuleRect: rect, capsuleCornerRadius: metrics.capsuleCornerRadius,
                                         lineIDs: [trunkLayout.line.id] + active.map(\.line.id),
                                         dimmed: trunkLayout.dimmed && active.allSatisfy(\.dimmed)))
            }
        }

        for layout in layouts where !layout.isTrunk {
            let last = layout.line.stops.count - 1
            for index in layout.drawnOwnIndices where index < last {
                rings.append(ring(id: "\(layout.line.id)#\(index)", code: layout.line.stops[index].code,
                                  center: CGPoint(x: layout.stopAlong[index], y: layout.rowAcross),
                                  colorIndex: layout.line.colorIndex, lineIDs: [layout.line.id],
                                  dimmed: layout.dimmed, metrics: metrics))
            }
        }

        return rings + capsules
    }

    private static func ring(id: String, code: String, center: CGPoint, colorIndex: Int,
                     lineIDs: [String], dimmed: Bool, metrics: MapMetrics) -> StopMark {
        StopMark(id: id, stopCode: code, kind: .ring(colorIndex: colorIndex), center: center,
                 ringRadius: metrics.ringRadius, strokeWidth: metrics.ringStroke,
                 capsuleRect: .zero, capsuleCornerRadius: 0, lineIDs: lineIDs, dimmed: dimmed)
    }

    /// Stop names sit at −35° in landscape, anchored at the dot and rising to the right: parallel
    /// lines of text can never collide, so a name can be any length. Portrait has room to set them
    /// horizontally, outside each rail.
    private static func stopLabels(layouts: [LineLayout], trunkLayout: LineLayout, request: MapLayoutRequest,
                           center: CGFloat, trunkLabelAcross: CGFloat, metrics: MapMetrics) -> [StopLabel] {
        let named = request.namedLineIDs
        var labels: [StopLabel] = []
        let joined = layouts.filter { $0.parallelAcross != nil }
        let junctionIndices = Set(joined.compactMap(\.junction.trunkJunctionIndex))

        func anchor(along: CGFloat, across: CGFloat, onBundle: Bool) -> (CGPoint, LabelAlignment) {
            if metrics.labelRotation != 0 {
                return (CGPoint(x: along, y: across - metrics.labelOffset), .leading)
            }
            if onBundle {
                // Names on the bundle share one column, set clear of the widest capsule.
                return (CGPoint(x: along, y: trunkLabelAcross), .leading)
            }
            if metrics.namesSitRightOfEveryRail {
                return (CGPoint(x: along, y: across + metrics.labelOffset), .leading)
            }
            return (CGPoint(x: along, y: across - metrics.trailingLabelOffset), .trailing)
        }

        /// How high the bundle reaches at a given trunk stop, so a name can clear the capsule there.
        func bundleTop(atTrunkIndex index: Int) -> CGFloat {
            let active = joined.filter { ($0.junction.trunkJunctionIndex ?? Int.max) <= index }
            guard !active.isEmpty else { return center }
            return min(center, active.compactMap(\.parallelAcross).min() ?? center) - metrics.capsuleMargin
        }

        for layout in layouts {
            guard named?.contains(layout.line.id) ?? true else { continue }
            let isTrunk = layout.isTrunk
            let across = layout.parallelAcross != nil && layout.drawnOwnIndices.isEmpty
                ? (layout.parallelAcross ?? layout.rowAcross) : layout.rowAcross

            // A line drawn entirely on the bundle starts there, so its terminus name belongs to the
            // bundle's column; every other name is set beside the line's own rail.
            let startsOnBundle = layout.parallelAcross != nil && layout.drawnOwnIndices.isEmpty
            let (terminusAnchor, terminusAlignment) = anchor(along: layout.stopAlong[0], across: across,
                                                             onBundle: isTrunk || startsOnBundle)
            labels.append(StopLabel(id: "\(layout.line.id)#terminus", lineID: layout.line.id,
                                    stopCode: layout.line.stops[0].code,
                                    text: layout.line.stops[0].name.uppercased(),
                                    anchor: terminusAnchor, rotationDegrees: metrics.labelRotation,
                                    alignment: terminusAlignment, role: .terminus(colorIndex: layout.line.colorIndex),
                                    fontSize: metrics.stopNameFontSize, trackingEm: metrics.stopNameTrackingEm,
                                    maxWidth: metrics.labelMaxWidth(for: layout.line.stops[0].name),
                                    lineLimit: metrics.labelLineLimit,
                                    dimmed: layout.dimmed))

            let last = layout.line.stops.count - 1
            for index in layout.drawnOwnIndices where index < last {
                // A stop shared by the bundle is named once, from the trunk's row, and clears the
                // capsule rather than the rail.
                let markAcross = isTrunk ? bundleTop(atTrunkIndex: index) : layout.rowAcross
                let (point, alignment) = anchor(along: layout.stopAlong[index], across: markAcross,
                                                onBundle: isTrunk)
                let role: StopLabelRole = isTrunk && junctionIndices.contains(index) ? .junction : .stop
                labels.append(StopLabel(id: "\(layout.line.id)#\(index)", lineID: layout.line.id,
                                        stopCode: layout.line.stops[index].code,
                                        text: layout.line.stops[index].name.uppercased(),
                                        anchor: point, rotationDegrees: metrics.labelRotation,
                                        alignment: alignment, role: role,
                                        fontSize: metrics.stopNameFontSize, trackingEm: metrics.stopNameTrackingEm,
                                        maxWidth: metrics.labelMaxWidth(for: layout.line.stops[index].name),
                                        lineLimit: metrics.labelLineLimit,
                                        dimmed: layout.dimmed))
            }
        }
        return labels
    }

    private static func terminusMarks(layouts: [LineLayout], metrics: MapMetrics) -> [TerminusMark] {
        layouts.map { layout in
            // A line that lies entirely on the trunk starts on the parallel rail, at the junction.
            let across = layout.drawnOwnIndices.isEmpty && layout.parallelAcross != nil
                ? (layout.parallelAcross ?? layout.rowAcross) : layout.rowAcross
            let rect = CGRect(x: layout.stopAlong[0] - metrics.terminusAlong / 2,
                              y: across - metrics.terminusAcross / 2,
                              width: metrics.terminusAlong, height: metrics.terminusAcross)
            return TerminusMark(lineID: layout.line.id, colorIndex: layout.line.colorIndex,
                                rect: rect, cornerRadius: metrics.terminusCornerRadius,
                                style: metrics.terminusIsBadge ? .badge(number: layout.line.number) : .bar,
                                fontSize: metrics.terminusFontSize, dimmed: layout.dimmed)
        }
    }

    private static func puckMarks(layouts: [LineLayout], request: MapLayoutRequest,
                          nodeAlong: CGFloat, metrics: MapMetrics) -> [PuckMark] {
        var pucks: [PuckMark] = []
        for vehicle in request.vehicles {
            guard let layout = layouts.first(where: { $0.line.id == vehicle.lineID }) else { continue }
            let last = layout.line.stops.count - 1
            guard last >= 1 else { continue }
            let index = min(max(vehicle.lastStopIndex, 0), last - 1)
            let from = layout.stopAlong[index]
            let to = layout.stopAlong[index + 1]
            let selected = vehicle.isSelected
            let size = selected ? metrics.selectedPuckSize : metrics.puckSize
            // The white stub is the last stretch into the rider's own stop; a bus stops short of it
            // rather than being drawn over the one mark that says the route ends here.
            let puckAlong = request.axis == .horizontal ? size.width : size.height
            let limit = nodeAlong - metrics.stubStartFromNode - (puckAlong / 2 + metrics.puckHalo + metrics.puckRing)
            let along = min(from + (to - from) * CGFloat(min(max(vehicle.progressToNext, 0), 1)), limit)
            let across = RailPath(segments: layout.segments).across(atAlong: along)
            pucks.append(PuckMark(id: vehicle.id, vehicleID: vehicle.id, lineID: layout.line.id,
                                  lineNumber: layout.line.number, colorIndex: layout.line.colorIndex,
                                  center: CGPoint(x: along, y: across),
                                  size: size,
                                  cornerRadius: metrics.puckCornerRadius, fontSize: metrics.puckFontSize,
                                  haloWidth: metrics.puckHalo, ringWidth: metrics.puckRing,
                                  isSelected: selected, dimmed: layout.dimmed))
        }
        // The bus you are waiting for is drawn last so its ring is never clipped by another puck.
        return pucks.filter { !$0.isSelected } + pucks.filter(\.isSelected)
    }

    /// How far before the canvas's end the node sits: the design's inset, or, where the trunk goes
    /// on past the user's stop, one pitch to its next stop and room for a dashed run past that.
    /// A terminus keeps the dash's room too: an angled name needs it, and the node stays put
    /// whichever the next stop is.
    private static func onwardRoom(_ onward: [MapStopInput], metrics: MapMetrics) -> CGFloat {
        guard !onward.isEmpty else { return metrics.nodeInsetFromEnd }
        let pastStop = metrics.ringOuter + 4 * metrics.scale + metrics.onwardDashLength
        return max(metrics.nodeInsetFromEnd, metrics.stopPitch + pastStop + metrics.onwardEndInset)
    }

    /// The trunk's next stop past the user's: a ring and a dashed run where the route goes on, a
    /// terminus where that stop is the end of the line. Named like every other stop of the trunk.
    private static func onwardMark(trunk: MapLineInput, nodeAlong: CGFloat, center: CGFloat,
                                   labelAcross: CGFloat, metrics: MapMetrics) -> OnwardMark? {
        guard let next = trunk.onward.first else { return nil }
        let isLast = trunk.onward.count == 1
        let along = nodeAlong + metrics.stopPitch
        let dashFrom = along + metrics.ringOuter + 4 * metrics.scale
        // The node and a ring are filled with the ground, so the rail can run under them; a faded
        // terminus is not, and the rail stops at its edge rather than showing through it.
        let railEnd = isLast ? along - metrics.terminusAlong / 2 : along
        var segments: [RailSegment] = [.line(from: CGPoint(x: nodeAlong, y: center), to: CGPoint(x: railEnd, y: center))]
        var stop: StopMark?
        var terminus: TerminusMark?
        if isLast {
            terminus = TerminusMark(lineID: trunk.id, colorIndex: trunk.colorIndex,
                                    rect: CGRect(x: along - metrics.terminusAlong / 2,
                                                 y: center - metrics.terminusAcross / 2,
                                                 width: metrics.terminusAlong, height: metrics.terminusAcross),
                                    cornerRadius: metrics.terminusCornerRadius,
                                    style: metrics.terminusIsBadge ? .badge(number: trunk.number) : .bar,
                                    fontSize: metrics.terminusFontSize, dimmed: false)
        } else {
            segments.append(.dashed(from: CGPoint(x: dashFrom, y: center),
                                    to: CGPoint(x: dashFrom + metrics.onwardDashLength, y: center),
                                    on: metrics.dashOn, off: metrics.dashOff))
            stop = ring(id: "\(trunk.id)#onward", code: next.code, center: CGPoint(x: along, y: center),
                        colorIndex: trunk.colorIndex, lineIDs: [trunk.id], dimmed: false, metrics: metrics)
        }
        let anchor = metrics.labelRotation != 0
            ? CGPoint(x: along, y: center - metrics.labelOffset)
            : CGPoint(x: along, y: labelAcross)
        let label = StopLabel(id: "\(trunk.id)#onward", lineID: trunk.id, stopCode: next.code,
                              text: next.name.uppercased(), anchor: anchor,
                              rotationDegrees: metrics.labelRotation, alignment: .leading,
                              role: isLast ? .terminus(colorIndex: trunk.colorIndex) : .stop,
                              fontSize: metrics.stopNameFontSize, trackingEm: metrics.stopNameTrackingEm,
                              maxWidth: metrics.labelMaxWidth(for: next.name),
                              lineLimit: metrics.labelLineLimit, dimmed: false)
        return OnwardMark(lineID: trunk.id, colorIndex: trunk.colorIndex, width: metrics.railWidth,
                          segments: segments, stop: stop, terminus: terminus, label: label,
                          fadeFrom: CGPoint(x: nodeAlong, y: center),
                          // Past the dash's end, and in landscape past the angled name's, so the
                          // name fades with the rest rather than being cut off before its end.
                          fadeTo: CGPoint(x: max(dashFrom + metrics.onwardDashLength,
                                                 along + label.alongReach + metrics.ringOuter),
                                          y: center))
    }

    private static func convergenceMark(nodeAlong: CGFloat, center: CGFloat,
                                metrics: MapMetrics, axis: MapAxis) -> ConvergenceMark {
        ConvergenceMark(
            stubFrom: MapAxisTransform.point(CGPoint(x: nodeAlong - metrics.stubStartFromNode, y: center), axis),
            stubTo: MapAxisTransform.point(CGPoint(x: nodeAlong - metrics.stubEndFromNode, y: center), axis),
            stubWidth: metrics.stubWidth,
            nodeCenter: MapAxisTransform.point(CGPoint(x: nodeAlong, y: center), axis),
            nodeRadius: metrics.nodeRadius,
            nodeStrokeWidth: metrics.nodeStroke,
            captionAnchor: MapAxisTransform.point(CGPoint(x: nodeAlong, y: center + metrics.captionOffset), axis),
            captionAlignment: .leading,
            captionIsBelow: axis == .horizontal,
            captionFontSize: metrics.captionFontSize,
            captionTrackingEm: metrics.captionTrackingEm)
    }
}
