import Foundation
import CoreGraphics

/// A rail in engine space, where `x` is the along-coordinate (the direction of travel) and `y` is
/// the across-coordinate. The engine works entirely in this space and converts to the view's
/// coordinates once, at the end.
nonisolated struct RailPath: Hashable, Sendable {
    var segments: [RailSegment]

    /// Where the rail sits, across, at a given point along it.
    ///
    /// Straight and dashed segments interpolate linearly. A cubic is evaluated at
    /// `u = (along - from.x) / (to.x - from.x)`, which is exact at both ends and stays within about
    /// two points in the middle for the curve shapes used here — the control points never fold back
    /// on the along axis, so `u` tracks the real parameter closely.
    func across(atAlong along: CGFloat) -> CGFloat {
        guard let first = segments.first, let last = segments.last else { return 0 }
        if along <= first.start.x { return first.start.y }
        if along >= last.end.x { return last.end.y }

        for segment in segments {
            let a = segment.start, b = segment.end
            guard along >= a.x, along <= b.x else { continue }
            let span = b.x - a.x
            let u = span > 0 ? (along - a.x) / span : 0
            switch segment {
            case .line, .dashed:
                return a.y + (b.y - a.y) * u
            case .cubic(_, let c1, let c2, _):
                let v = 1 - u
                return v * v * v * a.y + 3 * v * v * u * c1.y + 3 * v * u * u * c2.y + u * u * u * b.y
            }
        }
        // Between two segments (a gap should not happen): fall back to the nearest endpoint.
        return segments.last(where: { $0.end.x <= along })?.end.y ?? first.start.y
    }

    func point(atAlong along: CGFloat) -> CGPoint {
        CGPoint(x: along, y: across(atAlong: along))
    }
}

/// Converts engine space (x = along, y = across) into the view's coordinates.
nonisolated enum MapAxisTransform {
    static func point(_ p: CGPoint, _ axis: MapAxis) -> CGPoint {
        axis == .horizontal ? p : CGPoint(x: p.y, y: p.x)
    }

    static func rect(_ r: CGRect, _ axis: MapAxis) -> CGRect {
        axis == .horizontal ? r : CGRect(x: r.origin.y, y: r.origin.x, width: r.height, height: r.width)
    }

    static func segment(_ s: RailSegment, _ axis: MapAxis) -> RailSegment {
        guard axis == .vertical else { return s }
        switch s {
        case .line(let f, let t): return .line(from: point(f, axis), to: point(t, axis))
        case .dashed(let f, let t, let on, let off): return .dashed(from: point(f, axis), to: point(t, axis), on: on, off: off)
        case .cubic(let f, let c1, let c2, let t):
            return .cubic(from: point(f, axis), c1: point(c1, axis), c2: point(c2, axis), to: point(t, axis))
        }
    }
}
