import Foundation
import CoreGraphics

/// Keeps the angled names of a landscape map inside it.
///
/// A name rises up and to the right of its stop, so the top row's names need room above the row.
/// The design leaves that room at its own sizes, but a name is never drawn below
/// `TypeStyle.readableMinimum`: on a small board (a phone on its side) the names are larger than
/// the map was laid out for, and the top row's climb further than the design allows, into the
/// header. The scene is then moved down by that extra climb, as far as the room under it allows,
/// giving up the "TAP A BUS" hint when that is what it takes. A full-size board is unchanged.
nonisolated extension MapScene {
    func keepingNamesInside(height: CGFloat) -> MapScene {
        guard axis == .horizontal else { return self }
        // Only what the floor adds: at its own sizes the design lets the top row's names reach
        // into the space the header leaves, and a full-size board is left exactly as drawn.
        let names = labels + [onward?.label].compactMap { $0 }
        let designed = max(0, -(names.map { $0.topEdge(atReadableFloor: false) }.min() ?? 0))
        let drawn = max(0, -(names.map { $0.topEdge(atReadableFloor: true) }.min() ?? 0))
        let overflow = drawn - designed
        guard overflow > 0.5 else { return self }
        let lowest = lowestEdge
        let shift = min(overflow, max(0, floorOfRoom(height: height) - lowest))
        if shift < overflow, hintAnchor != nil {
            // Not enough room above the "TAP A BUS" hint. The hint is only there until the first
            // tap, and the names are what the map is read by, so they take its room.
            var withoutHint = self
            withoutHint.hintAnchor = nil
            let fuller = min(overflow, max(0, height - lowest))
            if fuller > shift { return withoutHint.shiftedDown(by: fuller) }
        }
        return shift > 0 ? shiftedDown(by: shift) : self
    }

    /// Where the room under the map ends: the "TAP A BUS" hint where there is one, else the edge.
    private func floorOfRoom(height: CGFloat) -> CGFloat {
        guard let hintAnchor else { return height }
        return hintAnchor.y - max(MapMetrics.readableMinimum, 11 * scale) * MapMetrics.lineHeightEm / 2
    }

    /// The lowest thing drawn: a rail, a puck, a "+N STOPS" caption or the YOUR STOP caption.
    private var lowestEdge: CGFloat {
        var edges: [CGFloat] = []
        for rail in rails {
            for segment in rail.segments { edges += [segment.start.y, segment.end.y].map { $0 + rail.width / 2 } }
        }
        for segment in onward?.segments ?? [] {
            edges += [segment.start.y, segment.end.y].map { $0 + (onward?.width ?? 0) / 2 }
        }
        edges += pucks.map { $0.center.y + $0.size.height / 2 + $0.haloWidth }
        edges += dashes.filter(\.showLabel).map {
            $0.labelCenter.y + max(MapMetrics.readableMinimum, $0.fontSize) * MapMetrics.lineHeightEm / 2
        }
        edges.append(convergence.captionAnchor.y
                     + max(MapMetrics.readableMinimum, convergence.captionFontSize) * MapMetrics.lineHeightEm)
        return edges.max() ?? 0
    }

    private func shiftedDown(by dy: CGFloat) -> MapScene {
        var scene = offsetBy(dx: 0, dy: dy)
        // The hint stays put: it belongs to the bottom of the map, not to the rails.
        scene.hintAnchor = hintAnchor
        return scene
    }

    /// Everything drawn, moved as one: a widget sets the map where its names have room.
    func offsetBy(dx: CGFloat, dy: CGFloat) -> MapScene {
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        func move(_ segment: RailSegment) -> RailSegment {
            switch segment {
            case .line(let f, let t): .line(from: move(f), to: move(t))
            case .dashed(let f, let t, let on, let off): .dashed(from: move(f), to: move(t), on: on, off: off)
            case .cubic(let f, let c1, let c2, let t): .cubic(from: move(f), c1: move(c1), c2: move(c2), to: move(t))
            }
        }
        var scene = self
        scene.rails = rails.map { rail in
            var r = rail
            r.segments = rail.segments.map(move)
            return r
        }
        scene.termini = termini.map { var t = $0; t.rect = t.rect.offsetBy(dx: dx, dy: dy); return t }
        scene.dashes = dashes.map { dash in
            var d = dash
            d.from = move(d.from)
            d.to = move(d.to)
            d.labelCenter = move(d.labelCenter)
            return d
        }
        scene.stops = stops.map { var s = $0; s.center = move(s.center); s.capsuleRect = s.capsuleRect.offsetBy(dx: dx, dy: dy); return s }
        scene.labels = labels.map { var l = $0; l.anchor = move(l.anchor); return l }
        scene.pucks = pucks.map { var p = $0; p.center = move(p.center); return p }
        scene.convergence.stubFrom = move(convergence.stubFrom)
        scene.convergence.stubTo = move(convergence.stubTo)
        scene.convergence.nodeCenter = move(convergence.nodeCenter)
        scene.convergence.captionAnchor = move(convergence.captionAnchor)
        scene.hintAnchor = hintAnchor.map(move)
        scene.onward = onward.map { mark in
            var m = mark
            m.segments = mark.segments.map(move)
            m.stop?.center = move(mark.stop?.center ?? .zero)
            m.terminus?.rect = mark.terminus?.rect.offsetBy(dx: dx, dy: dy) ?? .zero
            m.label.anchor = move(mark.label.anchor)
            m.fadeFrom = move(mark.fadeFrom)
            m.fadeTo = move(mark.fadeTo)
            return m
        }
        return scene
    }
}

nonisolated extension StopLabel {
    /// How high the name reaches: at the size it is drawn, held at the readable floor, or at the
    /// size the layout gave it. Only angled names climb; a portrait name sits in its column.
    func topEdge(atReadableFloor: Bool) -> CGFloat {
        guard rotationDegrees != 0 else { return anchor.y }
        let drawn = atReadableFloor ? max(MapMetrics.readableMinimum, fontSize) : fontSize
        // Space Mono is monospaced; tracking is set from the geometric size (StopLabelsLayer).
        let glyph = drawn * MapMetrics.monoAdvanceEm + fontSize * trackingEm
        let lines = wrappedLines(glyphWidth: glyph)
        let width = CGFloat(lines.map(\.count).max() ?? 0) * glyph
        let height = CGFloat(lines.count) * drawn * MapMetrics.lineHeightEm
        // The text box is anchored at its bottom-leading corner and turned about it, so its top
        // corner is the far end of the top line.
        let angle = abs(rotationDegrees) * .pi / 180
        return anchor.y - (width * sin(angle) + height * cos(angle))
    }

    /// How far along the rail an angled name reaches past its anchor, at the size it is drawn.
    /// A portrait name runs across the rail, so it reaches no further along it.
    var alongReach: CGFloat {
        guard rotationDegrees != 0 else { return 0 }
        let drawn = max(MapMetrics.readableMinimum, fontSize)
        let glyph = drawn * MapMetrics.monoAdvanceEm + fontSize * trackingEm
        let lines = wrappedLines(glyphWidth: glyph)
        let width = CGFloat(lines.map(\.count).max() ?? 0) * glyph
        let height = CGFloat(lines.count) * drawn * MapMetrics.lineHeightEm
        // The far end of the top line, turned about the bottom-leading corner.
        let angle = abs(rotationDegrees) * .pi / 180
        return width * cos(angle) + height * sin(angle)
    }

    /// The name broken between words the way `Text` breaks it inside `maxWidth`, up to `lineLimit`.
    private func wrappedLines(glyphWidth: CGFloat) -> [String] {
        guard maxWidth > 0 else { return [text] }
        let capacity = max(1, Int(maxWidth / glyphWidth))
        var lines: [String] = []
        for word in text.split(separator: " ").map(String.init) {
            if let last = lines.last, last.count + 1 + word.count <= capacity {
                lines[lines.count - 1] = last + " " + word
            } else {
                lines.append(word)
            }
        }
        return Array(lines.prefix(max(1, lineLimit)))
    }
}
