import SwiftUI
import WidgetKit
// The views are also compiled into BusBusTests, which checks they fit every size.
#if !BUSBUS_WIDGET
@testable import BusBus
#endif

extension Theme {
    /// The palette a widget draws in.
    ///
    /// In full colour it is the app's own, in the appearance chosen in the app's Settings — a
    /// widget follows the app, not just the home screen. Tinted and clear home screens and the lock
    /// screen render by luminance alone, so there it is white at a few strengths and the system
    /// supplies the colour.
    ///
    /// Without its container background — StandBy, which draws the widget straight on black — the
    /// chosen appearance is set aside for the dark one: cream-mode ink on black cannot be read.
    static func widget(renderingMode: WidgetRenderingMode, colorScheme: ColorScheme,
                       appearance: Appearance, showsBackground: Bool = true) -> Theme {
        guard renderingMode == .fullColor else { return .widgetMonochrome }
        return resolve(showsBackground ? appearance.colorScheme ?? colorScheme : .dark)
    }

    static let widgetMonochrome: Theme = {
        var theme = Theme.dark
        theme.background = .clear
        theme.readoutBand = .clear
        theme.card = .white.opacity(0.12)
        theme.cardOutline = .white.opacity(0.3)
        theme.primaryText = .white
        theme.secondaryText = .white.opacity(0.7)
        theme.captionText = .white.opacity(0.8)
        theme.stopName = .white.opacity(0.7)
        theme.headerCaption = .white.opacity(0.7)
        theme.dashCaption = .white.opacity(0.55)
        theme.separatorDot = .white.opacity(0.4)
        theme.liveDot = .white
        theme.stale = .white.opacity(0.4)
        theme.isMonochrome = true
        return theme
    }()
}

extension EnvironmentValues {
    /// Line colours are not available: badges are drawn as outlines and units in grey.
    @Entry var widgetIsMonochrome = false
    /// The system took the container background away: on an iPhone, StandBy, which shows the small
    /// widget straight on black and scaled up for the far side of a room. WidgetKit has no way to
    /// ask for the place itself (`WidgetLocation` only disfavours one), so this is the sign of it.
    @Entry var widgetIsBackgroundless = false
}

/// Everything a widget's views read from the environment, set once at the root.
struct WidgetEnvironment: ViewModifier {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    @Environment(\.locale) private var inheritedLocale
    @Environment(\.layoutDirection) private var inheritedDirection
    var appearance: Appearance
    /// For the screenshots, which render outside a host and cannot set the system's value.
    var showsBackgroundOverride: Bool?

    func body(content: Content) -> some View {
        let showsBackground = showsBackgroundOverride ?? self.showsBackground
        let theme = Theme.widget(renderingMode: renderingMode, colorScheme: colorScheme, appearance: appearance,
                                 showsBackground: showsBackground)
        content
            .environment(\.theme, theme)
            .environment(\.widgetIsMonochrome, renderingMode != .fullColor)
            .environment(\.widgetIsBackgroundless, !showsBackground)
            // The language chosen in the app, which the widget's own process knows nothing of.
            // Following the device, both are left as they are (`LanguageOverride`).
            .environment(\.locale, AppLanguage.override.map(Locale.init(identifier:)) ?? inheritedLocale)
            .environment(\.layoutDirection, AppLanguage.override.map(AppLanguage.layoutDirection(for:)) ?? inheritedDirection)
            .containerBackground(for: .widget) { theme.background }
    }
}

/// A line's badge. In full colour it is the app's own `LineBadgeView`; without colour it becomes
/// an outline the system can tint, since a white square would carry no number at all.
struct WidgetBadge: View {
    /// The board's ring round the next bus's badge: a gap, then a rule in the text colour. The
    /// board fills the gap to cut through its rails; a widget has none there, so it stays empty,
    /// which also keeps it out of the one-ink looks.
    struct Ring {
        var gap: CGFloat
        var width: CGFloat

        /// In proportion to the board's phone readout: a 76 pt badge, 5 pt apart, a 4 pt rule.
        static func `for`(side: CGFloat) -> Ring {
            Ring(gap: (side * 5 / 76).rounded(), width: max(2, (side * 4 / 76).rounded()))
        }
    }

    @Environment(\.theme) private var theme
    @Environment(\.widgetIsMonochrome) private var monochrome
    var number: String
    var colorIndex: Int
    var side: CGFloat
    var numeralSize: CGFloat
    /// Laid out round the badge, so the badge takes that much more room on every side.
    var ring: Ring?

    private var radius: CGFloat { Radius.badge(side) }

    var body: some View {
        if let ring {
            let outset = ring.gap + ring.width
            mark
                .padding(outset)
                .overlay {
                    RoundedRectangle(cornerRadius: radius + outset, style: .continuous)
                        .strokeBorder(theme.primaryText, lineWidth: ring.width)
                }
        } else {
            mark
        }
    }

    @ViewBuilder private var mark: some View {
        if monochrome {
            Text(verbatim: number)
                .busText(TypeStyles.badgeNumeral(numeralSize))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, side * 0.14)
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(theme.primaryText, lineWidth: Stroke.cardOutline))
                .widgetAccentable()
                .accessibilityHidden(true)
        } else {
            LineBadgeView(number: number, colorIndex: colorIndex, side: side, cornerRadius: radius,
                          numeralSize: numeralSize, ring: nil)
        }
    }
}

/// The app's `RowBackground`: light mode draws a rule round the card, dark mode fills it.
struct WidgetCardBackground: View {
    @Environment(\.theme) private var theme
    var radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if theme.isLight {
            shape.strokeBorder(theme.cardOutline, lineWidth: Stroke.cardOutline)
        } else {
            shape.fill(theme.card)
        }
    }
}

/// The board's live dot. Live is green; older numbers turn it grey and, where there is room, say
/// what time they are from rather than claiming to be current.
struct WidgetLiveDot: View {
    @Environment(\.theme) private var theme
    var liveness: WidgetLiveness
    var showsLabel: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(liveness == .live ? theme.liveDot : theme.stale)
                .frame(width: 8, height: 8)
            if showsLabel, let label {
                Text(label)
                    .busText(TypeStyles.liveLabelPad)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var label: String? {
        switch liveness {
        case .live: LiveState.live.label
        // A bare "14:20" beside a grey dot reads as a clock.
        case .stale(let asOf): String(appLocalized: "AS OF \(WidgetFormat.time(asOf))")
        case .expired: nil
        }
    }

    private var accessibilityLabel: String {
        switch liveness {
        case .live: String(appLocalized: "Live data")
        case .stale, .expired: String(appLocalized: "Data is stale")
        }
    }
}

nonisolated enum WidgetFormat {
    /// "14:33", as the board's sub-line writes an arrival.
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute().locale(AppLanguage.locale))
    }
}

extension View {
    /// A one-line Space Mono caption in a line box cut down to what its capitals use. The face's
    /// own box is nearly half as tall again as its size, and a widget has no room to spare for
    /// leading an all-caps line never fills. Nothing is clipped: the box only stops reserving it.
    func widgetCaptionLine(_ size: CGFloat = TypeStyle.readableMinimum) -> some View {
        lineLimit(1).frame(height: (size * 4 / 3).rounded())
    }
}
