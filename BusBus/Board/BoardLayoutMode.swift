import SwiftUI

nonisolated enum BoardLayoutMode: Hashable, Sendable {
    case landscape        // the reference composition: rows of route running right into the node
    case landscapeSingle  // one line, drawn larger
    case phone            // portrait, narrow: the map rotates and runs down the screen
    case pad              // portrait, wide: three named columns
}

nonisolated extension BoardLayoutMode {
    /// The artboard each mode is drawn from.
    var reference: CGSize {
        switch self {
        case .landscape, .landscapeSingle: CGSize(width: 1280, height: 720)
        case .pad: CGSize(width: 834, height: 1194)
        case .phone: CGSize(width: 390, height: 844)
        }
    }

    var headerHeight: CGFloat {
        switch self {
        case .landscape, .landscapeSingle: 72
        case .pad: 88
        case .phone: 64
        }
    }

    var readoutHeight: CGFloat {
        switch self {
        case .landscape, .landscapeSingle: 268
        case .pad: 386
        case .phone: 310
        }
    }

    var designInset: CGFloat {
        switch self {
        case .landscape, .landscapeSingle: 40
        case .pad: 36
        case .phone: 20
        }
    }

    var preset: MapSizePreset {
        switch self {
        case .landscape: .landscape
        case .landscapeSingle: .landscapeSingle
        case .pad: .pad
        case .phone: .phone
        }
    }

    func scale(width: CGFloat, height: CGFloat) -> CGFloat {
        min(width / reference.width, height / reference.height)
    }
}

/// Resolves the whole board's proportions from the size the system hands the scene.
///
/// Geometry and size classes only — never a device model. Orientation changes, Split View, Stage
/// Manager, a resized Mac window and a phone folding or unfolding all arrive as a new size, and all
/// of them go through this one function.
nonisolated struct BoardLayout: Hashable, Sendable {
    /// `EdgeInsets` is not `Hashable`, and the layout is compared to decide whether to re-lay out.
    nonisolated struct SafeArea: Hashable, Sendable {
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
        var top: CGFloat = 0
        var bottom: CGFloat = 0

        init(leading: CGFloat = 0, trailing: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0) {
            self.leading = leading
            self.trailing = trailing
            self.top = top
            self.bottom = bottom
        }

        init(_ insets: EdgeInsets) {
            self.init(leading: insets.leading, trailing: insets.trailing,
                      top: insets.top, bottom: insets.bottom)
        }
    }

    var mode: BoardLayoutMode
    var scale: CGFloat
    var headerHeight: CGFloat
    var readoutHeight: CGFloat
    var mapSize: CGSize
    var sideInset: CGFloat
    /// What the system has already reserved at each edge — the sensor housing and the rounded
    /// corners in landscape, the home indicator at the foot.
    var safeArea: SafeArea
    var preset: MapSizePreset
    var axis: MapAxis
    /// False only on a narrow phone showing three lines, where the two you are not catching become
    /// unnamed distance spines: 390 pt cannot carry three named columns.
    var namesAllLines: Bool

    /// Below this the readout stops being readable and the board shows the map with a single line
    /// of text instead.
    var isCompact: Bool { scale < 0.5 }
    var isPortrait: Bool { axis == .vertical }

    static let minimumScale: CGFloat = 0.32
    /// A very large window should not produce a 200 pt numeral.
    static let maximumScale: CGFloat = 1.6

    /// The edge the sensor housing sits behind, when one does.
    var housingEdge: HorizontalEdge?
    /// What the board keeps clear on each edge: the design's margin, or the system's reservation
    /// where that is larger and the edge is actually obstructed.
    var insets: SafeArea = SafeArea()

    var contentInsetLeading: CGFloat { insets.leading }
    var contentInsetTrailing: CGFloat { insets.trailing }
    var contentInsetTop: CGFloat { insets.top }
    var contentInsetBottom: CGFloat { insets.bottom }
    /// The map keeps the same margin as everything else, so the node and the readout beneath it
    /// stand off the edge together.
    var mapInsetLeading: CGFloat { insets.leading }
    var mapInsetTrailing: CGFloat { insets.trailing }

    /// A wall display in landscape: the next arrival and the bus after it run the full height on
    /// the leading side, this wide, and the header and map stack in a column beside them. The
    /// readout is the job there, so it gets the room. Nil everywhere else.
    var wallReadoutWidth: CGFloat?
    /// What the wall readout's own type and marks are multiplied by: its column is drawn at
    /// `wallReadoutContent`, and grows until the column's width or the board's height runs out.
    var wallReadoutScale: CGFloat = 1
    var isWall: Bool { wallReadoutWidth != nil }
    /// The column beside the readout is narrower than the board, so its map folds more of each route into its
    /// "+N STOPS" runs, and keeps its stops a line of names apart: names never go below the readable
    /// minimum, so on a phone they would otherwise run into each other.
    var mapTailBudget: Int? { isWall ? 2 : nil }
    /// The column's width, not the board's height, sets how large its map is drawn: on an iPad the
    /// board's scale would leave a 470 pt column room for little more than its two ends.
    var mapScale: CGFloat { isWall ? min(scale, mapSize.width / Self.wallMapReferenceWidth) : scale }
    static let wallMapReferenceWidth: CGFloat = 640
    var mapHeadCount: Int? { isWall ? 0 : nil }
    var mapMinimumStopPitch: CGFloat? { isWall ? max(40 * scale, 36) : nil }

    /// The WallTallH artboard's 780 pt readout.
    /// The readout takes this share of a wall display's width; the map has the rest.
    static let wallReadoutShare: CGFloat = 1 / 3
    /// The readout's content at scale 1, inside its margins: a column 360 wide, 640 tall.
    static let wallReadoutContent = CGSize(width: 360, height: 640)
    static let wallReadoutMargin: CGFloat = 40
    static let wallColumnInset: CGFloat = 24

    static func resolve(size: CGSize, lineCount: Int,
                        horizontal: UserInterfaceSizeClass? = nil,
                        vertical: UserInterfaceSizeClass? = nil,
                        safeArea: SafeArea = SafeArea(),
                        housingEdge: HorizontalEdge? = nil,
                        wall: Bool = false) -> BoardLayout {
        let width = max(size.width, 1)
        let height = max(size.height, 1)

        // A wall phone in landscape is narrower than any Mac window, so height and the vertical
        // size class decide it there; 900 pt is the Mac/iPad break. `>=` so a window as wide as it
        // is tall still reads as landscape rather than falling to the portrait composition.
        let isLandscape = width >= height && (width >= 900 || height <= 500 || vertical == .compact)
        let mode: BoardLayoutMode = isLandscape
            ? (lineCount <= 1 ? .landscapeSingle : .landscape)
            : (width >= 600 ? .pad : .phone)

        // Vertically the board takes only what the system has reserved. The artboards run their
        // header and readout bands to the top and bottom edges, and those bands centre their own
        // contents, so a margin on top of that would shrink the composition for nothing.
        let contentHeight = max(1, height - safeArea.top - safeArea.bottom)
        let scale = clamp(mode.scale(width: width, height: contentHeight))
        let margin = mode.designInset * scale

        // Horizontally the design has a margin of its own. It and the system's reservation are two
        // answers to the same question, so the board takes the larger rather than stacking them —
        // and only the side the sensor housing is actually behind has to honour the reservation.
        // The other side is clear, and on a board read from across a room that width is worth having.
        func horizontal(_ edge: HorizontalEdge, reserved: CGFloat) -> CGFloat {
            guard housingEdge == nil || housingEdge == edge else { return margin }
            return max(margin, reserved)
        }
        let insets = SafeArea(leading: horizontal(.leading, reserved: safeArea.leading),
                              trailing: horizontal(.trailing, reserved: safeArea.trailing),
                              top: safeArea.top, bottom: safeArea.bottom)

        let header = mode.headerHeight * scale
        if wall && isLandscape {
            // The column beside the readout keeps the design's narrower inset on its leading side;
            // its trailing side is the board's own edge.
            let readoutWidth = (width * wallReadoutShare).rounded()
            // The leading margin keeps clear of a sensor housing; the readout scales to what is left.
            let readoutMargins = max(wallReadoutMargin * scale, insets.leading) + wallReadoutMargin * scale
            let readoutScale = min((readoutWidth - readoutMargins) / wallReadoutContent.width,
                                   (contentHeight - 2 * wallReadoutMargin * scale) / wallReadoutContent.height)
            var layout = BoardLayout(mode: mode, scale: scale,
                                     headerHeight: header, readoutHeight: contentHeight,
                                     mapSize: CGSize(width: max(1, width - readoutWidth - wallColumnInset * scale - insets.trailing),
                                                     height: max(0, contentHeight - header)),
                                     sideInset: margin,
                                     safeArea: safeArea,
                                     preset: mode.preset,
                                     axis: .horizontal,
                                     namesAllLines: true,
                                     housingEdge: housingEdge,
                                     insets: insets)
            layout.wallReadoutWidth = readoutWidth
            layout.wallReadoutScale = max(minimumScale, readoutScale)
            return layout
        }
        let readout = mode.readoutHeight * scale
        return BoardLayout(mode: mode, scale: scale,
                           headerHeight: header, readoutHeight: readout,
                           mapSize: CGSize(width: max(1, width - insets.leading - insets.trailing),
                                           height: max(0, contentHeight - header - readout)),
                           sideInset: margin,
                           safeArea: safeArea,
                           preset: mode.preset,
                           axis: isLandscape ? .horizontal : .vertical,
                           namesAllLines: mode != .phone || lineCount < 3,
                           housingEdge: housingEdge,
                           insets: insets)
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(maximumScale, max(minimumScale, value))
    }

    // MARK: Per-mode type and spacing choices

    var titleStyle: TypeStyle {
        if isWall { return TypeStyles.titleWall }
        switch mode {
        case .landscape, .landscapeSingle: return TypeStyles.titleLandscape
        case .pad: return TypeStyles.titlePad
        case .phone: return TypeStyles.titlePhone
        }
    }

    var clockStyle: TypeStyle {
        if isWall { return TypeStyles.clockWall }
        switch mode {
        case .landscape, .landscapeSingle: return TypeStyles.clock
        case .pad: return TypeStyles.clockPad
        case .phone: return TypeStyles.clockPhone
        }
    }

    var captionStyle: TypeStyle {
        mode == .pad ? TypeStyles.headerCaptionPad : TypeStyles.headerCaption
    }

    var liveLabelStyle: TypeStyle {
        mode == .pad ? TypeStyles.liveLabelPad : TypeStyles.liveLabel
    }

    /// The phone header has room for the dot but not the word.
    var showsLiveLabel: Bool { mode != .phone }
}
