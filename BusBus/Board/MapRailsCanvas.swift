import SwiftUI

/// Draws the rails, the marks and the node. Only the geometry lives here — every piece of text on
/// the map is a real `Text` in a layer above, so it stays selectable, scalable and legible to
/// VoiceOver.
struct MapRailsCanvas: View {
    @Environment(\.theme) private var theme
    var scene: MapScene

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            drawRails(in: &context)
            drawTermini(in: &context)
            drawRings(in: &context)
            drawCapsules(in: &context)
            drawConvergence(in: &context)
        }
        // Everything else on the map is a positioned view, which SwiftUI mirrors for a
        // right-to-left language; a canvas it leaves as drawn, so the rails are told to follow.
        .flipsForRightToLeftLayoutDirection(true)
        .accessibilityHidden(true)
    }

    private func opacity(_ dimmed: Bool) -> Double { dimmed ? 0.45 : 1 }

    private func fillWithGround(_ path: Path, in context: inout GraphicsContext) {
        context.fillWithGround(path, theme: theme)
    }

    private func drawRails(in context: inout GraphicsContext) {
        for rail in scene.rails {
            context.strokeRail(rail.segments, color: theme.rail(rail.colorIndex).opacity(opacity(rail.dimmed)),
                               width: rail.width)
        }
    }

    private func drawTermini(in context: inout GraphicsContext) {
        for terminus in scene.termini {
            guard case .bar = terminus.style else { continue }   // badges are real views
            context.fill(Path(roundedRect: terminus.rect, cornerRadius: terminus.cornerRadius, style: .continuous),
                         with: .color(theme.rail(terminus.colorIndex).opacity(opacity(terminus.dimmed))))
        }
    }

    private func drawRings(in context: inout GraphicsContext) {
        for mark in scene.stops {
            guard case .ring(let colorIndex) = mark.kind else { continue }
            let rect = CGRect(x: mark.center.x - mark.ringRadius, y: mark.center.y - mark.ringRadius,
                              width: mark.ringRadius * 2, height: mark.ringRadius * 2)
            let circle = Path(ellipseIn: rect)
            fillWithGround(circle, in: &context)
            context.stroke(circle, with: .color(theme.rail(colorIndex).opacity(opacity(mark.dimmed))),
                           style: StrokeStyle(lineWidth: mark.strokeWidth))
        }
    }

    /// One capsule spanning the whole bundle, never a dot per line: that is what tells you the wait
    /// is shared between the lines running together there.
    private func drawCapsules(in context: inout GraphicsContext) {
        for mark in scene.stops {
            guard mark.kind == .capsule else { continue }
            let path = Path(roundedRect: mark.capsuleRect, cornerRadius: mark.capsuleCornerRadius, style: .continuous)
            fillWithGround(path, in: &context)
            context.stroke(path, with: .color(theme.primaryText.opacity(opacity(mark.dimmed))),
                           style: StrokeStyle(lineWidth: mark.strokeWidth))
        }
    }

    private func drawConvergence(in context: inout GraphicsContext) {
        let convergence = scene.convergence
        var stub = Path()
        stub.move(to: convergence.stubFrom)
        stub.addLine(to: convergence.stubTo)
        context.stroke(stub, with: .color(theme.primaryText),
                       style: StrokeStyle(lineWidth: convergence.stubWidth, lineCap: .round))

        let rect = CGRect(x: convergence.nodeCenter.x - convergence.nodeRadius,
                          y: convergence.nodeCenter.y - convergence.nodeRadius,
                          width: convergence.nodeRadius * 2, height: convergence.nodeRadius * 2)
        let node = Path(ellipseIn: rect)
        fillWithGround(node, in: &context)
        context.stroke(node, with: .color(theme.primaryText),
                       style: StrokeStyle(lineWidth: convergence.nodeStrokeWidth))
    }
}

extension GraphicsContext {
    /// A rail's segments in one colour: the solid stretches as one path, so their joins are smooth,
    /// and each dashed run on its own.
    mutating func strokeRail(_ segments: [RailSegment], color: Color, width: CGFloat) {
        var solid = Path()
        var cursor: CGPoint?

        for segment in segments {
            switch segment {
            case .line(let from, let to):
                if cursor != from { solid.move(to: from) }
                solid.addLine(to: to)
                cursor = to
            case .cubic(let from, let c1, let c2, let to):
                if cursor != from { solid.move(to: from) }
                solid.addCurve(to: to, control1: c1, control2: c2)
                cursor = to
            case .dashed(let from, let to, let on, let off):
                var dashed = Path()
                dashed.move(to: from)
                dashed.addLine(to: to)
                stroke(dashed, with: .color(color),
                       style: StrokeStyle(lineWidth: width, lineCap: .butt, dash: [on, off]))
                cursor = nil
            }
        }
        stroke(solid, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    /// Fills a mark with the board's ground, so the rail under it stops at its edge. In one ink
    /// there is no ground to fill with: the rail is cut out instead.
    mutating func fillWithGround(_ path: Path, theme: Theme) {
        if theme.isMonochrome {
            var cut = self
            cut.blendMode = .destinationOut
            cut.fill(path, with: .color(.black))
        } else {
            fill(path, with: .color(theme.background))
        }
    }
}
