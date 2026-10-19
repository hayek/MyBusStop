import Foundation
import CoreGraphics

/// Every geometric constant of the map, mined from the artboards at their reference size and
/// multiplied by `scale`. Offsets named `…FromNode` are measured backwards along the direction of
/// travel from the node, so extra canvas length lengthens the dashed runs and nothing else moves.
nonisolated struct MapMetrics: Hashable, Sendable {
    var preset: MapSizePreset
    var scale: CGFloat
    var lineCount: Int

    // Rails
    var railWidth: CGFloat
    var rowOffsets: [CGFloat]          // distance from the centre for others[0], others[1]
    var rowsAreSigned: Bool            // true when others sit on both sides of the trunk
    var parallelOffset: CGFloat

    // Terminus
    var terminusAlong: CGFloat         // extent along the direction of travel
    var terminusAcross: CGFloat
    var terminusCornerRadius: CGFloat
    var terminusCenterAlong: CGFloat
    var terminusIsBadge: Bool
    var terminusFontSize: CGFloat

    // Stops
    var firstStopAlong: CGFloat
    var stopPitch: CGFloat
    var ringRadius: CGFloat
    var ringStroke: CGFloat
    var capsuleWidth: CGFloat
    var capsuleCornerRadius: CGFloat
    var capsuleStroke: CGFloat
    var capsuleMargin: CGFloat

    // Dashes
    var dashOn: CGFloat
    var dashOff: CGFloat
    var dashFontSize: CGFloat
    var dashTrackingEm: CGFloat
    var dashLabelOffset: CGFloat
    var minimumDashLength: CGFloat

    // Labels
    var stopNameFontSize: CGFloat
    var stopNameTrackingEm: CGFloat
    var labelOffset: CGFloat           // across offset of a stop name from its rail
    /// Names to the left of a rail have only the screen edge to work with, so they sit closer in.
    var trailingLabelOffset: CGFloat
    /// true when the columns are far enough apart for every rail to carry its names on its own
    /// right; where they are not, a name would land on the next rail and has to go left instead.
    var namesSitRightOfEveryRail: Bool
    var labelRotation: Double
    /// How wide a stop name may run before it wraps. An angled name costs vertical rise, and a
    /// long one on the top row climbs out of the map; wrapping it halves the climb. Zero means
    /// it runs as far as it likes on one line.
    var labelMaxWidth: CGFloat
    var labelLineLimit: Int

    // Convergence
    var nodeInsetFromEnd: CGFloat
    var nodeRadius: CGFloat
    var nodeStroke: CGFloat
    var stubStartFromNode: CGFloat
    var stubEndFromNode: CGFloat
    var stubWidth: CGFloat
    var railsEndFromNode: CGFloat
    var lastTailFromNode: CGFloat
    var curveStartFromNode: CGFloat        // where an unjoined rail starts bending
    var curveC1FromNode: CGFloat
    var curveC2FromNode: CGFloat
    var joinedCurveStartFromNode: CGFloat  // where a parallel rail starts bending
    var joinedCurveC1FromNode: CGFloat
    var joinedCurveC2FromNode: CGFloat
    var junctionCurveLength: CGFloat       // how far before the junction the bend begins
    /// Where the faded stretch past the user's stop ends, short of the canvas's end. Landscape
    /// keeps room for the next stop's name to rise to the right.
    var onwardEndInset: CGFloat

    // Pucks
    /// A badge carrying a line number, so it keeps the same shape whichever way the map runs.
    var puckSize: CGSize
    var puckCornerRadius: CGFloat
    var puckFontSize: CGFloat
    var puckHalo: CGFloat
    var puckRing: CGFloat
    var selectedPuckScale: CGFloat

    // Captions
    var captionFontSize: CGFloat
    var captionTrackingEm: CGFloat
    var captionOffset: CGFloat

    /// Space Mono sets every glyph 0.6 em wide, so a name's width is known without measuring it.
    static let monoAdvanceEm: CGFloat = 0.6
    /// Space Mono's line, ascender to descender.
    static let lineHeightEm: CGFloat = 1.48
    /// The size no text in the app goes below (`TypeStyle.readableMinimum`, which reads it from here
    /// so the map engine builds without the design system).
    static let readableMinimum: CGFloat = 12

    /// The box `name` wraps in: the design's, widened just enough for its longest word. A name is
    /// drawn no smaller than `TypeStyle.readableMinimum`, so on a small board it can be larger than
    /// the box was sized for, and a word that does not fit is broken mid-word. Wrapping still falls
    /// between words, so the name climbs no higher than the design allows.
    func labelMaxWidth(for name: String) -> CGFloat {
        guard labelMaxWidth > 0 else { return 0 }
        let drawn = max(Self.readableMinimum, stopNameFontSize)
        // Tracking is set from the geometric size, not the floored one (StopLabelsLayer).
        let perGlyph = drawn * Self.monoAdvanceEm + stopNameFontSize * stopNameTrackingEm
        let longestWord = name.split(separator: " ").map(\.count).max() ?? 0
        return max(labelMaxWidth, (CGFloat(longestWord) * perGlyph).rounded(.up) + 1)
    }

    /// Outer edge of a stop ring, used to keep dashes clear of the marks they run between.
    var ringOuter: CGFloat { ringRadius + ringStroke / 2 }

    init(preset: MapSizePreset, scale: CGFloat, lineCount: Int) {
        self.preset = preset
        self.scale = scale
        self.lineCount = lineCount
        let s = scale
        let single = preset == .landscapeSingle
        let phoneWide = preset == .phone && lineCount <= 1

        switch preset {
        case .landscape, .landscapeSingle:
            railWidth = (single ? 14 : 12) * s
            rowOffsets = [120 * s, 120 * s]
            rowsAreSigned = true
            terminusAlong = 10 * s
            terminusAcross = (single ? 60 : 40) * s
            terminusCornerRadius = 5 * s
            terminusCenterAlong = 45 * s
            terminusIsBadge = false
            terminusFontSize = 0
            firstStopAlong = (single ? 150 : 110) * s
            stopPitch = 100 * s
            ringRadius = (single ? 17 : 13) * s
            ringStroke = (single ? 8 : 6) * s
            dashOn = (single ? 22 : 20) * s
            dashOff = (single ? 20 : 18) * s
            dashFontSize = (single ? 13 : 11) * s
            dashTrackingEm = single ? 0.14 : 0.12
            dashLabelOffset = (single ? 30 : 26) * s
            minimumDashLength = 60 * s
            stopNameFontSize = (single ? 14 : 12) * s
            stopNameTrackingEm = 0.03
            labelOffset = (single ? 24 : 20) * s
            trailingLabelOffset = (single ? 24 : 20) * s
            namesSitRightOfEveryRail = true
            labelRotation = -35
            labelMaxWidth = (single ? 130 : 110) * s
            labelLineLimit = 2
            nodeInsetFromEnd = 90 * s
            nodeRadius = 26 * s
            nodeStroke = 12 * s
            stubStartFromNode = 72 * s
            stubEndFromNode = 28 * s
            stubWidth = 16 * s
            railsEndFromNode = 70 * s
            lastTailFromNode = 280 * s
            curveStartFromNode = 170 * s
            curveC1FromNode = 124 * s
            curveC2FromNode = 116 * s
            joinedCurveStartFromNode = 134 * s
            joinedCurveC1FromNode = 100 * s
            joinedCurveC2FromNode = 94 * s
            junctionCurveLength = 80 * s
            onwardEndInset = 24 * s
            puckSize = single ? CGSize(width: 56 * s, height: 40 * s) : CGSize(width: 44 * s, height: 36 * s)
            puckCornerRadius = 10 * s
            puckFontSize = (single ? 22 : 20) * s
            puckHalo = (single ? 6 : 5) * s
            puckRing = 5 * s
            captionFontSize = 13 * s
            captionTrackingEm = 0.16
            captionOffset = 46 * s

        case .phone:
            railWidth = (phoneWide ? 14 : 12) * s
            rowOffsets = lineCount >= 3 ? [68 * s, 136 * s] : [85 * s, 85 * s]
            rowsAreSigned = false        // every non-trunk column sits left of the trunk
            terminusAlong = 26 * s
            terminusAcross = 30 * s
            terminusCornerRadius = 8 * s
            terminusCenterAlong = 21 * s
            terminusIsBadge = true
            terminusFontSize = 16 * s
            firstStopAlong = 72 * s
            stopPitch = (phoneWide ? 64 : 60) * s
            // The artboards' circles are border-box, so 24/22 is the outer diameter.
            ringStroke = (phoneWide ? 6 : 5) * s
            ringRadius = ((phoneWide ? 24 : 22) * s - ringStroke) / 2
            dashOn = (phoneWide ? 18 : 16) * s
            dashOff = (phoneWide ? 16 : 14) * s
            dashFontSize = (phoneWide ? 12 : 11) * s
            dashTrackingEm = 0.10
            dashLabelOffset = 32 * s
            minimumDashLength = 40 * s
            stopNameFontSize = (phoneWide ? 12 : 11) * s
            stopNameTrackingEm = 0.04
            labelOffset = 32 * s
            // 390 pt leaves about 78 pt for a name left of the second column; 22 buys back ten.
            trailingLabelOffset = 22 * s
            namesSitRightOfEveryRail = false
            labelRotation = 0
            labelMaxWidth = 0
            labelLineLimit = 1
            nodeInsetFromEnd = 22 * s
            nodeRadius = 17 * s
            nodeStroke = 9 * s
            stubStartFromNode = 40 * s
            stubEndFromNode = 20 * s
            stubWidth = 14 * s
            railsEndFromNode = 38 * s
            lastTailFromNode = 96 * s
            curveStartFromNode = 60 * s
            curveC1FromNode = 44 * s
            curveC2FromNode = 56 * s
            joinedCurveStartFromNode = 60 * s
            joinedCurveC1FromNode = 44 * s
            joinedCurveC2FromNode = 56 * s
            junctionCurveLength = 60 * s
            onwardEndInset = 4 * s
            puckSize = CGSize(width: 46 * s, height: 36 * s)
            puckCornerRadius = 11 * s
            puckFontSize = 20 * s
            puckHalo = 5 * s
            puckRing = 5 * s
            captionFontSize = 12 * s
            captionTrackingEm = 0.16
            captionOffset = 33 * s

        case .pad:
            railWidth = 14 * s
            rowOffsets = [250 * s, 250 * s]
            rowsAreSigned = true
            terminusAlong = 38 * s
            terminusAcross = 44 * s
            terminusCornerRadius = 11 * s
            terminusCenterAlong = 39 * s
            terminusIsBadge = true
            terminusFontSize = 22 * s
            firstStopAlong = 109 * s
            stopPitch = 86 * s
            ringStroke = 7 * s
            ringRadius = (30 * s - ringStroke) / 2
            dashOn = 20 * s
            dashOff = 18 * s
            dashFontSize = 12 * s
            dashTrackingEm = 0.10
            dashLabelOffset = 32 * s
            minimumDashLength = 60 * s
            stopNameFontSize = 12 * s
            stopNameTrackingEm = 0.04
            labelOffset = 32 * s
            trailingLabelOffset = 32 * s
            namesSitRightOfEveryRail = true
            labelRotation = 0
            labelMaxWidth = 0
            labelLineLimit = 1
            nodeInsetFromEnd = 44 * s
            nodeRadius = 28 * s
            nodeStroke = 12 * s
            stubStartFromNode = 54 * s
            stubEndFromNode = 26 * s
            stubWidth = 18 * s
            railsEndFromNode = 50 * s
            lastTailFromNode = 147 * s
            curveStartFromNode = 96 * s
            curveC1FromNode = 70 * s
            curveC2FromNode = 86 * s
            joinedCurveStartFromNode = 96 * s
            joinedCurveC1FromNode = 70 * s
            joinedCurveC2FromNode = 86 * s
            junctionCurveLength = 80 * s
            onwardEndInset = 8 * s
            puckSize = CGSize(width: 52 * s, height: 40 * s)
            puckCornerRadius = 12 * s
            puckFontSize = 22 * s
            puckHalo = 6 * s
            puckRing = 5 * s
            captionFontSize = 13 * s
            captionTrackingEm = 0.16
            captionOffset = 53 * s
        }

        capsuleWidth = 20 * s
        capsuleCornerRadius = 10 * s
        capsuleStroke = 4 * s
        capsuleMargin = 18 * s
        parallelOffset = 18 * s
        selectedPuckScale = 1.14

        // Angled names are parallel, so neighbours collide only when the gap between them is
        // thinner than the text. On a board small enough for the names to be held at the readable
        // floor, the scaled pitch leaves a gap made for smaller text; the stops, and the first stop
        // after the terminus, are kept far enough apart for the text as drawn. A full-size board
        // keeps the design's spacing.
        if labelRotation != 0, Self.readableMinimum > stopNameFontSize {
            // A quarter line more than the text itself, so neighbours do not touch.
            let depth = (CGFloat(labelLineLimit) + 0.25) * Self.readableMinimum * Self.lineHeightEm
            let pitch = (depth / sin(abs(labelRotation) * .pi / 180)).rounded(.up)
            stopPitch = max(stopPitch, pitch)
            firstStopAlong = max(firstStopAlong, terminusCenterAlong + pitch)
        }
    }

    /// The dashed run past the user's next stop: two dashes, enough to read as "and on".
    var onwardDashLength: CGFloat { 2 * dashOn + dashOff }

    /// Head stops drawn before the dashed run; the single-line board has room for two.
    var headCount: Int { preset == .landscapeSingle ? 2 : 1 }

    /// How many stop marks the tail may spend, shared between the bundle and the line's own route.
    var tailBudget: Int { preset == .landscape || preset == .landscapeSingle ? 5 : 4 }

    var selectedPuckSize: CGSize {
        preset == .landscapeSingle ? CGSize(width: 64 * scale, height: 48 * scale) : puckSize
    }
}
