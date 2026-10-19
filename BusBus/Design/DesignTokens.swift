import SwiftUI

/// Every colour of the board, in both themes. Views never write a hex value.
nonisolated struct Theme: Hashable, Sendable {
    var isLight: Bool
    var background: Color
    var readoutBand: Color
    var card: Color
    var cardOutline: Color
    var outlinedCard: Color
    var chipUnselected: Color
    var searchBorder: Color
    var clearButtonBorder: Color
    var closeButton: Color
    var primaryText: Color
    var secondaryText: Color
    /// The readout's supporting text — kickers, the sub-line's destination, the THEN card. Brighter
    /// than `secondaryText` because these are read at a glance from a distance, not studied.
    var captionText: Color
    var stopName: Color
    var headerCaption: Color
    var dashCaption: Color
    var separatorDot: Color
    var liveDot: Color
    var numeralOnColor: Color
    var primaryButtonFill: Color
    var primaryButtonText: Color
    var late: Color
    var stale: Color
    /// A widget the system draws in one ink (tinted, clear, the Mac desktop, the lock screen). Line
    /// colours are gone there, so lines are drawn in `primaryText`, a badge becomes an outline,
    /// and what the board fills with its ground is cut out of whatever lies beneath instead.
    var isMonochrome = false

    /// One ground behind the whole board: the readout band matches it, so header, map and numbers
    /// read as a single surface.
    static let dark = Theme(
        isLight: false,
        background: Color(hex: 0x08080B),
        readoutBand: Color(hex: 0x08080B),
        card: Color(hex: 0x15151B),
        cardOutline: Color(hex: 0x24242E),
        outlinedCard: Color(hex: 0x101018),
        chipUnselected: Color(hex: 0x101016),
        searchBorder: Color(hex: 0x24242E),
        clearButtonBorder: Color(hex: 0x2A2A34),
        closeButton: Color(hex: 0x1E1E26),
        primaryText: Color(hex: 0xFFFFFF),
        secondaryText: Color(hex: 0xA0A0AE),
        captionText: Color(hex: 0xC4C4CE),
        stopName: Color(hex: 0x8C8C9A),
        headerCaption: Color(hex: 0x8C8C9A),
        dashCaption: Color(hex: 0x5E5E6C),
        separatorDot: Color(hex: 0x4A4A56),
        liveDot: Color(hex: 0x3DDC84),
        numeralOnColor: Color(hex: 0x08080B),
        primaryButtonFill: Color(hex: 0xFFFFFF),
        primaryButtonText: Color(hex: 0x08080B),
        late: Color(hex: 0xFF3B3F),
        stale: Color(hex: 0x5E5E6C))

    /// One continuous cream ground: no white panels anywhere, and the readout band disappears.
    static let light = Theme(
        isLight: true,
        background: Color(hex: 0xF4F2EC),
        readoutBand: Color(hex: 0xF4F2EC),
        card: Color(hex: 0xF4F2EC),
        cardOutline: Color(hex: 0xDBD7CD),
        outlinedCard: Color(hex: 0xF4F2EC),
        chipUnselected: Color(hex: 0xF4F2EC),
        searchBorder: Color(hex: 0xDBD7CD),
        clearButtonBorder: Color(hex: 0xDBD7CD),
        closeButton: Color(hex: 0xE6E2D8),
        primaryText: Color(hex: 0x14140F),
        secondaryText: Color(hex: 0x55555F),
        captionText: Color(hex: 0x45454E),
        stopName: Color(hex: 0x55555F),
        headerCaption: Color(hex: 0x6B6862),
        dashCaption: Color(hex: 0x8A8790),
        separatorDot: Color(hex: 0xB6B2A8),
        liveDot: Color(hex: 0x1A7F4B),
        numeralOnColor: Color(hex: 0x14140F),
        primaryButtonFill: Color(hex: 0x14140F),
        primaryButtonText: Color(hex: 0xF4F2EC),
        late: Color(hex: 0xD32029),
        stale: Color(hex: 0x8A8790))

    static func resolve(_ scheme: ColorScheme) -> Theme { scheme == .light ? .light : .dark }

    func rail(_ index: Int) -> Color { isMonochrome ? primaryText : LinePalette.rail(index, isLight: isLight) }
    func lineText(_ index: Int) -> Color { isMonochrome ? primaryText : LinePalette.labelText(index, isLight: isLight) }
    /// The number written on a badge or puck of this line's colour.
    func numeral(on index: Int) -> Color {
        isMonochrome ? primaryText : LinePalette.numeral(on: index, isLight: isLight)
    }

    /// In light mode the unit beside the big numeral goes grey — the line colour cannot carry text
    /// on cream. In dark mode it is the line's own colour.
    func unitColor(_ index: Int) -> Color { isLight ? secondaryText : rail(index) }
}

nonisolated enum Radius {
    static let readoutCard: CGFloat = 24
    static let searchField: CGFloat = 20
    static let row: CGFloat = 20
    static let button: CGFloat = 18
    static let badgeLarge: CGFloat = 18
    static let phoneRow: CGFloat = 18
    static let chip: CGFloat = 16
    static let phoneButton: CGFloat = 16
    static let badgeMedium: CGFloat = 14
    static let padPuck: CGFloat = 12
    static let badgeSmall: CGFloat = 12
    static let puck: CGFloat = 10
    static let badgeTiny: CGFloat = 10
    static let terminusBadge: CGFloat = 8
    static let terminusBar: CGFloat = 5

    /// The artboards size a badge's corner at a little under a quarter of its side.
    static func badge(_ side: CGFloat) -> CGFloat { (side * 0.23).rounded() }
}

nonisolated enum Stroke {
    static let chipBorder: CGFloat = 3
    static let tappedCardBorder: CGFloat = 3
    static let searchBorder: CGFloat = 2
    static let cardOutline: CGFloat = 2
    static let closeGlyph: CGFloat = 2.4
    static let chevron: CGFloat = 2.8
    static let check: CGFloat = 2.6
    static let focusRing: CGFloat = 3
}

nonisolated enum Spacing {
    static let sideInsetLandscape: CGFloat = 40
    static let sideInsetPad: CGFloat = 36
    static let sideInsetPhone: CGFloat = 20

    static let headerGap: CGFloat = 16
    static let headerTrailingGap: CGFloat = 22
    static let headerTrailingGapPhone: CGFloat = 10

    static let readoutTop: CGFloat = 26
    static let readoutBottom: CGFloat = 30
    static let readoutGap: CGFloat = 28
    static let readoutGapBeside: CGFloat = 24
    static let primaryBadgeGap: CGFloat = 32
    static let primaryBadgeGapBeside: CGFloat = 24
    static let primaryBadgeGapPad: CGFloat = 28
    static let primaryBadgeGapPhone: CGFloat = 18
    static let readoutColumnGap: CGFloat = 8
    static let readoutColumnGapPad: CGFloat = 14
    static let readoutColumnGapPhone: CGFloat = 12

    static let thenCardWidth: CGFloat = 380
    static let tappedCardWidth: CGFloat = 540

    static let setupGridGap: CGFloat = 24
    static let setupGridGapPhone: CGFloat = 12
    static let nearbyRowGap: CGFloat = 14
    static let nearbyRowGapPhone: CGFloat = 10
    static let nearbyRowHeight: CGFloat = 96
    static let nearbyRowHeightPhone: CGFloat = 84
    static let recentColumnWidth: CGFloat = 360
    static let searchHeight: CGFloat = 76
    static let searchHeightPhone: CGFloat = 60
    static let chipHeight: CGFloat = 168
    static let chipHeightPhone: CGFloat = 104
    static let buttonHeight: CGFloat = 64
    static let buttonHeightPhone: CGFloat = 58

    /// The dot that separates fragments of the readout sub-line.
    static let separatorDot: CGFloat = 5
}

extension View {
    /// Resolves the palette from the device's appearance and hands it down.
    ///
    /// Applied at each screen's root rather than once at the top: a screen that depends on an
    /// ancestor to inject its colours renders dark wherever it is used on its own, and does so
    /// silently. It is idempotent, so nesting two of them is harmless.
    func busTheme() -> some View { modifier(BusThemeModifier()) }
}

private struct BusThemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.environment(\.theme, Theme.resolve(colorScheme))
    }
}

extension EnvironmentValues {
    @Entry var theme: Theme = .dark
    /// The board's current layout scale, so nested views can size type without re-deriving it.
    @Entry var boardScale: CGFloat = 1
}
