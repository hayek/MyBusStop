import Foundation
import CoreGraphics

// The value-typed scene graph MapLayoutEngine produces. Views draw exactly what is here
// and compute nothing geometric of their own.

nonisolated enum RailSegment: Hashable, Sendable {
    case line(from: CGPoint, to: CGPoint)
    case cubic(from: CGPoint, c1: CGPoint, c2: CGPoint, to: CGPoint)
    case dashed(from: CGPoint, to: CGPoint, on: CGFloat, off: CGFloat)

    var start: CGPoint {
        switch self {
        case .line(let from, _), .dashed(let from, _, _, _): from
        case .cubic(let from, _, _, _): from
        }
    }

    var end: CGPoint {
        switch self {
        case .line(_, let to), .dashed(_, let to, _, _): to
        case .cubic(_, _, _, let to): to
        }
    }
}

nonisolated struct RailNode: Identifiable, Hashable, Sendable {
    var id: String { lineID }
    var lineID: String
    var colorIndex: Int
    var width: CGFloat
    var segments: [RailSegment]   // in along order: terminus → convergence end
    var isTrunk: Bool
    var dimmed: Bool
}

nonisolated enum StopMarkKind: Hashable, Sendable {
    case ring(colorIndex: Int)   // served by one drawn line
    case capsule                 // the interchange mark: ≥2 drawn lines share this stop
}

nonisolated struct StopMark: Identifiable, Hashable, Sendable {
    var id: String
    var stopCode: String
    var kind: StopMarkKind
    var center: CGPoint
    var ringRadius: CGFloat          // ring only, centre-line radius
    var strokeWidth: CGFloat
    var capsuleRect: CGRect          // capsule only; the stroke is centred on this rect
    var capsuleCornerRadius: CGFloat
    var lineIDs: [String]
    var dimmed: Bool
}

nonisolated enum TerminusStyle: Hashable, Sendable {
    case bar                         // landscape: rounded bar in the line colour
    case badge(number: String)       // portrait: rounded square carrying the line number
}

nonisolated struct TerminusMark: Identifiable, Hashable, Sendable {
    var id: String { lineID }
    var lineID: String
    var colorIndex: Int
    var rect: CGRect
    var cornerRadius: CGFloat
    var style: TerminusStyle
    var fontSize: CGFloat            // badge only
    var dimmed: Bool
}

nonisolated struct DashRun: Identifiable, Hashable, Sendable {
    var id: String
    var lineID: String
    var from: CGPoint
    var to: CGPoint
    var swallowedCount: Int
    var fontSize: CGFloat
    var trackingEm: CGFloat
    var labelCenter: CGPoint
    /// Landscape centres the caption under its dash; portrait aligns it in the name column, where
    /// centring it would put half the words on top of the rail.
    var labelAlignment: LabelAlignment
    /// False on the non-trunk rails of a shared bundle dash — the stops are the same, so the
    /// "+N STOPS" caption is written once.
    var showLabel: Bool
    var dimmed: Bool
}

nonisolated enum StopLabelRole: Hashable, Sendable {
    case terminus(colorIndex: Int)
    case stop
    case junction        // primary text: a stop where a line joins the trunk
    case passed          // primary text: the last stop the tapped bus went through
}

nonisolated enum LabelAlignment: Hashable, Sendable { case leading, trailing, center }

nonisolated struct StopLabel: Identifiable, Hashable, Sendable {
    var id: String
    var lineID: String
    var stopCode: String
    var text: String                 // already uppercased
    /// Landscape: the bottom-left corner of the (unrotated) text box, which is also the rotation anchor.
    /// Portrait: the vertical centre of the text's leading (or trailing) edge.
    var anchor: CGPoint
    var rotationDegrees: Double      // −35 in landscape, 0 in portrait
    var alignment: LabelAlignment
    var role: StopLabelRole
    var fontSize: CGFloat
    var trackingEm: CGFloat
    /// Zero when the name runs as far as it likes on one line.
    var maxWidth: CGFloat
    var lineLimit: Int
    var dimmed: Bool
}

nonisolated struct PuckMark: Identifiable, Hashable, Sendable {
    var id: String
    var vehicleID: String
    var lineID: String
    var lineNumber: String
    var colorIndex: Int
    var center: CGPoint
    var size: CGSize
    var cornerRadius: CGFloat
    var fontSize: CGFloat
    var haloWidth: CGFloat
    var ringWidth: CGFloat
    var isSelected: Bool
    var dimmed: Bool
}

nonisolated struct ConvergenceMark: Hashable, Sendable {
    var stubFrom: CGPoint
    var stubTo: CGPoint
    var stubWidth: CGFloat
    var nodeCenter: CGPoint
    var nodeRadius: CGFloat          // centre-line radius
    var nodeStrokeWidth: CGFloat
    var captionAnchor: CGPoint
    var captionAlignment: LabelAlignment
    var captionIsBelow: Bool         // true in landscape: the caption sits under the node
    var captionFontSize: CGFloat
    var captionTrackingEm: CGFloat
}

/// The trunk past the user's stop: its next stop and, where the route goes on past that, a short
/// dashed run. Where the next stop is the last, it is drawn as a terminus instead. The whole of it
/// fades out from the node to `fadeTo`.
nonisolated struct OnwardMark: Hashable, Sendable {
    var lineID: String
    var colorIndex: Int
    var width: CGFloat
    var segments: [RailSegment]      // node → next stop solid, then the dashed run if any
    var stop: StopMark?              // a ring, when more stops follow
    var terminus: TerminusMark?      // when the next stop is the end of the line
    var label: StopLabel
    var fadeFrom: CGPoint            // the node's centre
    var fadeTo: CGPoint              // where it has faded away: the end of the room made for it
}

nonisolated struct MapScene: Hashable, Sendable {
    var axis: MapAxis
    var preset: MapSizePreset
    var scale: CGFloat
    var trunkLineID: String
    var rails: [RailNode]            // draw order: non-trunk first, trunk last
    var termini: [TerminusMark]
    var dashes: [DashRun]
    var stops: [StopMark]            // rings first, then capsules
    var labels: [StopLabel]
    var pucks: [PuckMark]            // selected puck last
    var convergence: ConvergenceMark
    var hintAnchor: CGPoint?         // "TAP A BUS TO INSPECT IT" — landscape only
    /// Per line: the along-coordinate of every stop index, including stops swallowed by a dash
    /// and the user's stop (which sits at the node). Pucks and the tests read this.
    var stopAlong: [String: [CGFloat]]
    /// Nil when the user's stop is the trunk's last, or nothing past it is known.
    var onward: OnwardMark? = nil

    /// The rail of a line, for hit-testing and for placing pucks.
    func rail(_ lineID: String) -> RailNode? { rails.first { $0.lineID == lineID } }
}
