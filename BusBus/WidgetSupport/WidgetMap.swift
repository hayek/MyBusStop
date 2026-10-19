import Foundation
import CoreGraphics

/// What the larger widgets draw the board's map from at one moment of their timeline: the routes,
/// which line is the trunk, and where the buses are by then.
nonisolated struct WidgetMapFrame: Hashable, Sendable {
    /// In the order the rider chose them.
    var lines: [MapLineInput]
    var trunkLineID: String
    var userStopCode: String
    var vehicles: [MapVehicleInput]
    /// The positions come from numbers no longer live: the pucks are drawn back, like a board's
    /// puck whose fix has gone old.
    var vehiclesAreStale: Bool
}

nonisolated enum WidgetMap {
    /// Whether `routes` hold a map of `setup` at all, buses or none.
    static func canDraw(_ setup: SavedSetup, routes: WidgetRoutes?) -> Bool {
        frame(setup: setup, routes: routes, arrivals: [], fetchedAt: nil, liveness: .expired, palette: [:], date: .distantPast) != nil
    }

    /// The map for `setup` at `date`, or nil when no route of it reaches the stop.
    ///
    /// `arrivals` are those still to come at `date`, soonest first. The first on each line whose bus
    /// the board placed puts a puck on the map: where it was when the numbers were fetched, moved on
    /// towards the rider's stop in step with its countdown, so by the time it reads NOW it is at the
    /// stop. Only the first: a widget's "+N STOPS" run is a few points long, and the buses behind
    /// would be drawn on top of one another there.
    static func frame(setup: SavedSetup, routes: WidgetRoutes?, arrivals: [WidgetArrival], fetchedAt: Date?,
                      liveness: WidgetLiveness, palette: [String: Int], date: Date) -> WidgetMapFrame? {
        guard let routes, routes.setupID == setup.id else { return nil }
        let lines: [MapLineInput] = setup.lines.compactMap { line in
            guard let stops = routes.lines[line.id], stops.count >= 2, stops.last?.code == setup.stop.code else { return nil }
            return MapLineInput(id: line.id, number: line.shortName,
                                colorIndex: LineColorAssigner.provisionalIndex(for: line.id, persisted: palette),
                                stops: stops)
        }
        guard let first = lines.first else { return nil }
        // The board's trunk is the line of the next bus (`TrunkSelector`); a widget's picture is
        // redrawn only as often as that changes anyway.
        let trunk = arrivals.first { arrival in lines.contains { $0.id == arrival.lineID } }?.lineID ?? first.id

        var vehicles: [MapVehicleInput] = []
        var placedLines: Set<String> = []
        if let fetchedAt, liveness != .expired {
            for (index, arrival) in arrivals.enumerated() where !placedLines.contains(arrival.lineID) {
                guard let line = lines.first(where: { $0.id == arrival.lineID }),
                      let position = position(of: arrival, stopCount: line.stops.count, fetchedAt: fetchedAt, at: date)
                else { continue }
                placedLines.insert(line.id)
                let id = arrival.busID ?? "\(arrival.lineID)@\(arrival.expectedAt.timeIntervalSinceReferenceDate)"
                // The ring goes on the bus the readout counts down to, as on the board.
                vehicles.append(MapVehicleInput(id: id, lineID: line.id, lastStopIndex: position.lastStopIndex,
                                                progressToNext: position.progressToNext, isSelected: index == 0))
            }
        }
        let stale = if case .stale = liveness { true } else { false }
        return WidgetMapFrame(lines: lines, trunkLineID: trunk, userStopCode: setup.stop.code,
                              vehicles: vehicles, vehiclesAreStale: stale)
    }

    /// How many stops an arrival's bus still has to go at `date`, as the board counts them
    /// (`BoardBus.stopsAway`): the sub-line says what the puck shows.
    static func stopsAway(of arrival: WidgetArrival, fetchedAt: Date, at date: Date) -> Int? {
        guard let stopsAway = arrival.stopsAway else { return nil }
        let left = max(0, Double(stopsAway) - (arrival.progressToNext ?? 0)) * (1 - fraction(of: arrival, fetchedAt: fetchedAt, at: date))
        return max(1, Int((left - 1e-9).rounded(.up)))
    }

    /// How much of its wait an arrival has served by `date`: 0 when fetched, 1 once due.
    private static func fraction(of arrival: WidgetArrival, fetchedAt: Date, at date: Date) -> Double {
        let total = arrival.expectedAt.timeIntervalSince(fetchedAt)
        return total > 0 ? min(max(date.timeIntervalSince(fetchedAt) / total, 0), 1) : 1
    }

    /// Where an arrival's bus is at `date`, in the board's terms (`BoardBus`): the last stop it
    /// passed on the route and how far on it is towards the next. Nil when the board had no
    /// position for it.
    ///
    /// The bus covers the stops it had left at the pace its countdown does, reaching the rider's
    /// stop as it comes due; before the fetch it stays where it was seen.
    static func position(of arrival: WidgetArrival, stopCount: Int, fetchedAt: Date, at date: Date)
        -> (lastStopIndex: Int, progressToNext: Double)? {
        guard let stopsAway = arrival.stopsAway, stopCount >= 2 else { return nil }
        let last = Double(stopCount - 1)
        let seen = min(max(last - Double(stopsAway) + (arrival.progressToNext ?? 0), 0), last)
        let along = seen + (last - seen) * fraction(of: arrival, fetchedAt: fetchedAt, at: date)
        let index = min(Int(along.rounded(.down)), stopCount - 2)
        return (index, min(max(along - Double(index), 0), 1))
    }
}

/// The board's portrait map, fitted to a widget.
///
/// The engine lays it out at a scale taken from the box, as the phone's board does from the screen.
/// A widget is far shorter than a phone, so the "+N STOPS" runs do the work: the tail gives up stop
/// marks to them, then the head stop goes, and last a second line's names, until no two names or
/// stops touch. The whole map is moved, and names that still run past an edge are cut short, until
/// everything it draws is inside the box. Names stay at the readable minimum.
nonisolated enum WidgetMapLayout {
    /// The phone board's map width at scale 1: 390 pt less its margins.
    static let referenceWidth: CGFloat = 350
    /// How tall a widget map has to be to draw at the phone's own scale.
    static let referenceHeight: CGFloat = 300
    static let scales: ClosedRange<CGFloat> = 0.6...1
    /// How far the geometry may shrink below that for a box too short for it. The names do not.
    static let smallestScale: CGFloat = 0.45

    /// What the text on the map reads, for measuring it. Kept out of the pure layout, which does
    /// not know the language.
    struct Captions: Sendable {
        var yourStop: String
        var dash: @Sendable (Int) -> String

        static var english: Captions { Captions(yourStop: "YOUR STOP", dash: { "+\($0) STOPS" }) }
    }

    static func scale(for size: CGSize) -> CGFloat {
        min(max(min(size.width / referenceWidth, size.height / referenceHeight), scales.lowerBound), scales.upperBound)
    }

    static func scene(for frame: WidgetMapFrame, in size: CGSize, captions: Captions = .english) -> MapScene {
        let trunkOnly: Set<String> = [frame.trunkLineID]
        // The phone names only the trunk once there are three: three named columns need 390 pt.
        var namings: [Set<String>?] = frame.lines.count >= 3 ? [trunkOnly] : [nil]
        if frame.lines.count == 2 { namings.append(trunkOnly) }
        // Smaller geometry leaves the names their size and the dashes more room.
        let largest = scale(for: size)
        let scales = stride(from: largest, through: min(largest, smallestScale), by: -0.08)

        func layout(named: Set<String>?, scale: CGFloat, head: Int?, budget: Int?, height: CGFloat) -> MapScene {
            let metrics = MapMetrics(preset: .phone, scale: scale, lineCount: frame.lines.count)
            // No two stops closer than a line of names, or than two rings with a gap between them
            // (`hasCrowdedStops`): the dashes give way first.
            let pitch = max(TypeStyle.readableMinimum * MapMetrics.lineHeightEm + 2,
                            2 * metrics.ringOuter + metrics.ringRadius / 2 + 1).rounded(.up)
            return MapLayoutEngine.layout(MapLayoutRequest(
                lines: frame.lines, trunkLineID: frame.trunkLineID, userStopCode: frame.userStopCode,
                vehicles: frame.vehicles, axis: .vertical, preset: .phone,
                canvasSize: CGSize(width: size.width, height: max(1, height)), scale: scale,
                namedLineIDs: named, tailBudget: budget, headCount: head, minimumStopPitch: pitch))
        }

        // Most stops first: the preset's tail, then less of it; a head stop before the dash only
        // where it has room; smaller geometry; and on a two-line map, the other line's names last.
        var fallback: MapScene?
        for named in namings {
            for scale in scales {
                let metrics = MapMetrics(preset: .phone, scale: scale, lineCount: frame.lines.count)
                for budget in stride(from: metrics.tailBudget, through: 1, by: -1) {
                    for head in Set([metrics.headCount, 0]).sorted(by: >) {
                        // Shortened by whatever reaches past the top or the foot, and moved down
                        // clear of the top.
                        var height = size.height
                        var scene = layout(named: named, scale: scale, head: head, budget: budget, height: height)
                        for _ in 0..<3 {
                            let bounds = scene.drawnBounds(captions: captions)
                            let top = max(0, -bounds.minY), foot = max(0, bounds.maxY - size.height)
                            guard top + foot > 0.5 else { break }
                            height -= top + foot
                            scene = layout(named: named, scale: scale, head: head, budget: budget, height: height)
                            scene = scene.offsetBy(dx: 0, dy: max(0, -scene.drawnBounds(captions: captions).minY))
                        }
                        scene = scene.fittingWidth(size.width, captions: captions)
                        let fits = scene.drawnBounds(captions: captions).width <= size.width + 0.5
                        if fits, !scene.hasCollidingText(captions: captions), !scene.hasCrowdedStops { return scene }
                        fallback = fallback ?? scene
                    }
                }
            }
        }
        // Nothing fits cleanly: the fullest try, which the fit tests keep every widget size from needing.
        return fallback ?? layout(named: nil, scale: largest, head: nil, budget: nil, height: size.height)
    }
}

// MARK: - Measuring a scene

/// Where everything a scene draws ends up, measured rather than rendered: Space Mono sets every
/// glyph 0.6 em wide (`MapMetrics.monoAdvanceEm`), so a name's width is known from its length.
nonisolated extension MapScene {
    /// A piece of text, and whether it is a stop name that may be cut short.
    struct TextBox {
        var rect: CGRect
        var labelIndex: Int?
    }

    /// The width of a one-line caption set with `busFont`, whose tracking follows the floored size.
    static func captionWidth(_ text: String, size: CGFloat, trackingEm: CGFloat) -> CGFloat {
        let drawn = max(TypeStyle.readableMinimum, size)
        return CGFloat(text.count) * drawn * (MapMetrics.monoAdvanceEm + trackingEm)
    }

    static func box(anchor: CGPoint, width: CGFloat, height: CGFloat, alignment: LabelAlignment) -> CGRect {
        let x = switch alignment {
        case .leading: anchor.x
        case .trailing: anchor.x - width
        case .center: anchor.x - width / 2
        }
        return CGRect(x: x, y: anchor.y - height / 2, width: width, height: height)
    }

    /// Every piece of text on the map. Portrait only: its names are level, anchored at the middle
    /// of an edge (`StopLabelsLayer`).
    func textBoxes(captions: WidgetMapLayout.Captions) -> [TextBox] {
        var boxes: [TextBox] = []
        for (index, label) in labels.enumerated() {
            let drawn = max(TypeStyle.readableMinimum, label.fontSize)
            // Tracking is set from the geometric size, not the floored one (StopLabelsLayer).
            let width = CGFloat(label.text.count) * (drawn * MapMetrics.monoAdvanceEm + label.fontSize * label.trackingEm)
            boxes.append(TextBox(rect: Self.box(anchor: label.anchor, width: width,
                                                height: drawn * MapMetrics.lineHeightEm, alignment: label.alignment),
                                 labelIndex: index))
        }
        for dash in dashes where dash.showLabel {
            let drawn = max(TypeStyle.readableMinimum, dash.fontSize)
            let width = Self.captionWidth(captions.dash(dash.swallowedCount), size: dash.fontSize, trackingEm: dash.trackingEm)
            boxes.append(TextBox(rect: Self.box(anchor: dash.labelCenter, width: width,
                                                height: drawn * MapMetrics.lineHeightEm, alignment: dash.labelAlignment)))
        }
        let caption = convergence
        let drawn = max(TypeStyle.readableMinimum, caption.captionFontSize)
        let width = Self.captionWidth(captions.yourStop, size: caption.captionFontSize, trackingEm: caption.captionTrackingEm)
        boxes.append(TextBox(rect: Self.box(anchor: caption.captionAnchor, width: width,
                                            height: drawn * MapMetrics.lineHeightEm,
                                            alignment: caption.captionIsBelow ? .center : .leading)))
        return boxes
    }

    /// The marks: rails, stops, termini, pucks and the node.
    var markRects: [CGRect] {
        var rects: [CGRect] = []
        for rail in rails {
            for segment in rail.segments {
                var points = [segment.start, segment.end]
                if case .cubic(_, let c1, let c2, _) = segment { points += [c1, c2] }
                let xs = points.map(\.x), ys = points.map(\.y)
                rects.append(CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                    .insetBy(dx: -rail.width / 2, dy: -rail.width / 2))
            }
        }
        for stop in stops {
            rects.append(stop.kind == .capsule
                ? stop.capsuleRect.insetBy(dx: -stop.strokeWidth / 2, dy: -stop.strokeWidth / 2)
                : CGRect(x: stop.center.x, y: stop.center.y, width: 0, height: 0)
                    .insetBy(dx: -(stop.ringRadius + stop.strokeWidth / 2), dy: -(stop.ringRadius + stop.strokeWidth / 2)))
        }
        rects += termini.map(\.rect)
        for puck in pucks {
            let reach = puck.haloWidth + (puck.isSelected ? puck.ringWidth : 0)
            let grow: CGFloat = puck.isSelected ? 1.14 : 1
            rects.append(CGRect(x: puck.center.x, y: puck.center.y, width: 0, height: 0)
                .insetBy(dx: -(puck.size.width / 2 + reach) * grow, dy: -(puck.size.height / 2 + reach) * grow))
        }
        let node = convergence.nodeRadius + convergence.nodeStrokeWidth / 2
        rects.append(CGRect(x: convergence.nodeCenter.x, y: convergence.nodeCenter.y, width: 0, height: 0)
            .insetBy(dx: -node, dy: -node))
        return rects
    }

    func drawnBounds(captions: WidgetMapLayout.Captions) -> CGRect {
        (markRects + textBoxes(captions: captions).map(\.rect)).reduce(CGRect.null) { $0.union($1) }
    }

    /// Two pieces of text on top of each other, or a name under a terminus badge.
    func hasCollidingText(captions: WidgetMapLayout.Captions) -> Bool {
        let boxes = textBoxes(captions: captions).map { $0.rect.insetBy(dx: 0.5, dy: 0.5) }
        for (i, a) in boxes.enumerated() {
            if termini.contains(where: { $0.rect.intersects(a) }) { return true }
            for b in boxes[(i + 1)...] where a.intersects(b) { return true }
        }
        return false
    }

    /// Two stop marks less than half a ring's radius apart: they read as a chain, not as stops.
    var hasCrowdedStops: Bool {
        let gap = (stops.first { $0.kind != .capsule }?.ringRadius ?? 0) / 4
        let rects = stops.map { stop in
            stop.kind == .capsule
                ? stop.capsuleRect.insetBy(dx: -gap, dy: -gap)
                : CGRect(x: stop.center.x, y: stop.center.y, width: 0, height: 0)
                    .insetBy(dx: -(stop.ringRadius + stop.strokeWidth / 2 + gap), dy: -(stop.ringRadius + stop.strokeWidth / 2 + gap))
        }
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] where a.intersects(b) { return true }
        }
        return false
    }

    /// Centred across `width`, with the names at either edge cut short, a letter at a time, until
    /// it all fits between them. Where it is the rails or a caption that reach furthest, it is left
    /// as wide as it is, for the caller to try smaller.
    func fittingWidth(_ width: CGFloat, captions: WidgetMapLayout.Captions) -> MapScene {
        var scene = self
        for _ in 0..<60 {
            let bounds = scene.drawnBounds(captions: captions)
            guard bounds.width > width else { break }
            // The longer of the names that set either edge gives way.
            let outermost = scene.textBoxes(captions: captions)
                .filter { $0.rect.minX <= bounds.minX + 0.5 || $0.rect.maxX >= bounds.maxX - 0.5 }
                .compactMap(\.labelIndex)
                .filter { scene.labels[$0].text.count > 4 }
                .max { scene.labels[$0].text.count < scene.labels[$1].text.count }
            guard let index = outermost else { break }
            let text = scene.labels[index].text.replacingOccurrences(of: "…", with: "")
            scene.labels[index].text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) + "…"
        }
        let bounds = scene.drawnBounds(captions: captions)
        return scene.offsetBy(dx: (width - bounds.width) / 2 - bounds.minX, dy: 0)
    }
}
