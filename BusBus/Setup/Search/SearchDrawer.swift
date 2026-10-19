import SwiftUI

/// The search drawer's three heights on a screen of a given size, measured from the screen's
/// bottom edge.
nonisolated struct DrawerHeights: Hashable, Sendable {
    var small: CGFloat
    var medium: CGFloat
    var large: CGFloat

    /// `areaHeight` is the map's, from under the search header to the bottom edge. Small is about
    /// the header strip alone, for looking at the map; medium a little under half the screen;
    /// large stops short of the header so a band of map still says where the list is.
    init(areaHeight: CGFloat, screenHeight: CGFloat) {
        large = max(0, areaHeight - Self.mapPeek)
        medium = min(screenHeight * 0.45, large)
        small = min(Self.smallHeight, medium)
    }

    static let smallHeight: CGFloat = 120
    /// How much map stays above the drawer at its tallest.
    static let mapPeek: CGFloat = 150

    func height(_ drawer: DrawerHeight) -> CGFloat {
        switch drawer {
        case .small: small
        case .medium: medium
        case .large: large
        }
    }

    /// Where a drag lets go: the height nearest to where its momentum would have carried it, so a
    /// flick goes on to the next height and a nudge settles back.
    func nearest(to height: CGFloat) -> DrawerHeight {
        [DrawerHeight.small, .medium, .large].min { abs(self.height($0) - height) < abs(self.height($1) - height) } ?? .medium
    }
}

#if !os(tvOS)
/// The search screen's list, over the map's lower part with a grabber (portrait), or beside it as
/// a panel (wide windows). The same header and content either way; only the drawer has heights.
///
/// The grabber and header strip always drag it. The list scrolls only at the tallest height, and
/// below that a drag on the list moves the drawer instead, as in Maps: a rider swipes up on the
/// rows to see more of them. At the tallest height the list's drag is its scroll again. The drawer
/// never takes a drag from the map.
struct SearchDrawer<Header: View, Content: View>: View {
    enum Style: Equatable {
        case drawer(DrawerHeights)
        case panel
    }

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    var style: Style
    @Binding var height: DrawerHeight
    var scale: CGFloat
    /// The list's place, kept by the screen so BACK from the confirm step can scroll it back.
    @Binding var scrollPosition: ScrollPosition
    /// Whether the list is at its top, above its first row: put back as the top, not as that row.
    var onScrolledToTop: (Bool) -> Void = { _ in }
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    /// The finger's travel while dragging, down positive. Let go, it springs back as the height
    /// it settled on animates in, so the two move as one.
    @GestureState(resetTransaction: Transaction(animation: .snappy(duration: 0.3)))
    private var dragTravel: CGFloat = 0

    var body: some View {
        switch style {
        case .drawer(let heights): drawer(heights)
        case .panel: panel
        }
    }

    /// The drawer's height right now, the drag included, never past its smallest or largest.
    static func shownHeight(_ heights: DrawerHeights, at height: DrawerHeight, travel: CGFloat) -> CGFloat {
        min(max(heights.height(height) - travel, heights.small), heights.large)
    }

    private func drawer(_ heights: DrawerHeights) -> some View {
        // VoiceOver moves through the rows one by one, and needs the list to follow it at any height.
        let listScrolls = height == .large || voiceOverEnabled
        return VStack(spacing: 0) {
            strip
                .gesture(drag(heights))
            list
                .scrollDisabled(!listScrolls)
                // Only while the list is not scrolling, so the two never compete for a drag; the
                // rows' taps and the chips' sideways scroll still go to them.
                .gesture(drag(heights), including: listScrolls ? .subviews : .all)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.shownHeight(heights, at: height, travel: dragTravel), alignment: .top)
        .searchDrawerGround(isPanel: false, scale: scale)
        .animation(.snappy(duration: 0.3), value: height)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Spacing.sideInsetPhone * scale)
                .padding(.top, 6 * scale)
            list
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .searchDrawerGround(isPanel: true, scale: scale)
    }

    private var list: some View {
        ScrollView {
            content
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y <= -geometry.contentInsets.top + 1
        } action: { _, isAtTop in
            onScrolledToTop(isAtTop)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.immediately)
    }

    /// The grabber and the header under it: the part of the drawer that is always on screen, and
    /// the part that drags it at every height.
    private var strip: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(theme.stopName.opacity(0.5))
                .frame(width: 36 * scale, height: 5 * scale)
                .padding(.top, 8 * scale)
                .padding(.bottom, 4 * scale)
                .accessibilityHidden(true)
            header
                .padding(.horizontal, Spacing.sideInsetPhone * scale)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func drag(_ heights: DrawerHeights) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($dragTravel) { value, travel, _ in travel = value.translation.height }
            .onEnded { value in
                let landing = heights.height(height) - value.predictedEndTranslation.height
                height = heights.nearest(to: landing)
            }
    }
}

/// The drawer's ground, shared with the confirm panel that takes its place: rounded at the top
/// and lifted off the map, or as a panel, flat with a rule along its edge with the map.
private struct SearchDrawerGround: ViewModifier {
    @Environment(\.theme) private var theme
    var isPanel: Bool
    var scale: CGFloat

    func body(content: Content) -> some View {
        if isPanel {
            content
                .background(theme.background)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(theme.cardOutline).frame(width: Stroke.cardOutline / 2)
                }
        } else {
            let radius = Radius.readoutCard * scale
            let shape = UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius, style: .continuous)
            content
                .clipShape(shape)
                .background {
                    shape.fill(theme.background)
                        .shadow(color: .black.opacity(0.18), radius: 12 * scale, y: -2 * scale)
                }
        }
    }
}

extension View {
    func searchDrawerGround(isPanel: Bool, scale: CGFloat) -> some View {
        modifier(SearchDrawerGround(isPanel: isPanel, scale: scale))
    }
}
#endif
