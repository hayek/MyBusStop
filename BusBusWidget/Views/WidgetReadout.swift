import SwiftUI
import WidgetKit
// The views are also compiled into BusBusTests, which checks they fit every size.
#if !BUSBUS_WIDGET
@testable import BusBus
#endif

/// The minutes numeral and its unit, as `MinutesView` draws them, for one moment of a timeline.
///
/// `MinutesView` counts down with a `TimelineView`, which a widget cannot run: the timeline
/// provider draws one of these for every minute instead (`WidgetTimelineMath.entryDates`).
struct WidgetMinutes: View {
    @Environment(\.theme) private var theme
    @Environment(\.widgetIsMonochrome) private var monochrome

    var arrival: WidgetArrival
    var date: Date
    var colorIndex: Int
    var numberStyle: TypeStyle
    var unitStyle: TypeStyle
    var spacing: CGFloat = 6
    /// The THEN card keeps a grey unit in both themes, as it does on the board.
    var unitColor: Color?

    private var lineBox: CGFloat? { numberStyle.lineHeight.map { numberStyle.size * $0 } }

    var body: some View {
        let board = arrival.board
        let countdown = board.countdown(at: date)
        HStack(alignment: .lastTextBaseline, spacing: spacing) {
            if board.isImminent(at: date) {
                Text("NOW")
                    .busText(numberStyle, scale: 0.62)
                    .foregroundStyle(theme.primaryText)
            } else {
                Text(verbatim: countdown.figure)
                    .busText(numberStyle)
                    .foregroundStyle(theme.primaryText)
                    .contentTransition(.numericText(countsDown: true))
                    .monospacedDigit()
                Text(countdown.isHours ? "HR" : "MIN")
                    .busText(unitStyle)
                    .foregroundStyle(unitColor ?? (monochrome ? theme.secondaryText : theme.unitColor(colorIndex)))
                    // The line's colour in full colour, so the tint in the system's accented look.
                    .widgetAccentable(unitColor == nil)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .frame(height: lineBox)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(board.isImminent(at: date) ? String(appLocalized: "Arriving now") : countdown.spoken)
    }
}

/// The stop's name and code, with the live dot trailing — the board's header, cut down.
struct WidgetHeader: View {
    @Environment(\.theme) private var theme
    var entry: NextBusEntry
    var titleSize: CGFloat
    var showsCode: Bool
    /// Off on the watch in Always On, where a dot that cannot tick would claim too much.
    var showsLiveDot = true
    /// The watch's board gives a long stop name a second line; a widget keeps it to one.
    var titleLineLimit = 1

    var body: some View {
        if titleLineLimit > 1, isOneWord {
            // The watch: a one-word name the live label leaves too little room for gets the width
            // to itself, the label under it.
            ViewThatFits(in: .horizontal) {
                beside
                VStack(alignment: .leading, spacing: 4) {
                    title
                    liveDot
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            beside
        }
    }

    private var beside: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            title
            Spacer(minLength: 0)
            liveDot
                .layoutPriority(1)
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: entry.setup?.stop.name ?? "")
                .busText(TypeStyle(.archivoBlack, titleSize, tracking: -0.013))
                .foregroundStyle(theme.primaryText)
                // A name of one word is shrunk onto one line rather than broken in the middle of
                // it ("RÉPUBLIQU / E"), which is what a second line does to a word wider than the board.
                .lineLimit(isOneWord ? 1 : titleLineLimit)
                .minimumScaleFactor(0.7)
            if showsCode, let stop = entry.setup?.stop {
                Text(caption(for: stop))
                    .busText(TypeStyle(.spaceMonoBold, 12, tracking: 0.14))
                    .foregroundStyle(theme.headerCaption)
                    .widgetCaptionLine()
            }
        }
    }

    @ViewBuilder private var liveDot: some View {
        if showsLiveDot, entry.state == .board, entry.liveness != .expired {
            WidgetLiveDot(liveness: entry.liveness, showsLabel: true)
        }
    }

    private var isOneWord: Bool {
        (entry.setup?.stop.name ?? "").split(whereSeparator: \.isWhitespace).count == 1
    }

    private func caption(for stop: TransitStop) -> String {
        guard let city = stop.city, !city.isEmpty else { return String(appLocalized: "STOP \(stop.code)") }
        return String(appLocalized: "STOP \(stop.code) · \(city)")
    }
}

/// "ARRIVES 14:33 SCHEDULED" — the board's sub-line, as much of it as a widget has room for. It
/// gives up the stop count first, then the word ARRIVES, then SCHEDULED; the time always stays.
struct WidgetSubline: View {
    @Environment(\.theme) private var theme
    var arrival: WidgetArrival
    var size: CGFloat = 12
    var includesArrivesWord = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(stops: includesArrivesWord, arrivesWord: includesArrivesWord, scheduled: true)
            line(stops: false, arrivesWord: includesArrivesWord, scheduled: true)
            line(stops: false, arrivesWord: false, scheduled: true)
            line(stops: false, arrivesWord: false, scheduled: false)
        }
        .accessibilityElement(children: .combine)
    }

    /// Every fragment is set at one size, so they share a centre line as well as a baseline.
    private func line(stops: Bool, arrivesWord: Bool, scheduled: Bool) -> some View {
        HStack(spacing: 6) {
            if stops, let stopsAway = arrival.stopsAway {
                Text(String(appLocalized: "\(stopsAway) STOPS"))
                    .busText(TypeStyle(.archivoExtraBold, size, tracking: 0.02))
                    .foregroundStyle(theme.primaryText)
                Circle()
                    .fill(theme.separatorDot)
                    .frame(width: 4, height: 4)
                    .accessibilityHidden(true)
            }
            Text(timeText(arrivesWord: arrivesWord))
                .busText(TypeStyle(.spaceMonoBold, size, tracking: 0.02))
                .foregroundStyle(theme.secondaryText)
            if scheduled, !arrival.isRealtime {
                Text("SCHEDULED")
                    .busText(TypeStyle(.spaceMonoBold, size, tracking: 0.10))
                    .foregroundStyle(theme.dashCaption)
            }
        }
        .widgetCaptionLine(size)
    }

    private func timeText(arrivesWord: Bool) -> String {
        let time = WidgetFormat.time(arrival.expectedAt)
        return arrivesWord ? String(appLocalized: "ARRIVES \(time)") : time
    }
}

/// The next arrival: badge, kicker, numeral, sub-line — the readout's primary block at widget size.
/// Where it is the widget's main thing, its badge takes the board's ring.
struct WidgetPrimaryReadout: View {
    struct Metrics {
        var badge: CGFloat
        var numeral: CGFloat
        var minutes: CGFloat
        var unit: CGFloat
        var kicker: CGFloat
        var subline: CGFloat
        var gap: CGFloat
        var ringed = false

        static let medium = Metrics(badge: 40, numeral: 20, minutes: 50, unit: 16, kicker: 12, subline: 12, gap: 10)
        static let large = Metrics(badge: 44, numeral: 22, minutes: 58, unit: 17, kicker: 12, subline: 12, gap: 12)
        /// Under the large widget's map, beside the THEN column.
        static let largeMap = Metrics(badge: 50, numeral: 26, minutes: 66, unit: 18, kicker: 12, subline: 12,
                                      gap: 12, ringed: true)
        /// Next to or under the extra large sizes' map.
        static let mapHero = Metrics(badge: 64, numeral: 34, minutes: 88, unit: 23, kicker: 13, subline: 14,
                                     gap: 16, ringed: true)
        static let extraLarge = Metrics(badge: 72, numeral: 38, minutes: 100, unit: 25, kicker: 13, subline: 15,
                                        gap: 20, ringed: true)
        /// The watch app's board: the readout's own proportions on a 40–49 mm screen, with no
        /// kicker (a zero kicker leaves it out).
        static let watch = Metrics(badge: 40, numeral: 20, minutes: 56, unit: 16, kicker: 0, subline: 12, gap: 10)
    }

    @Environment(\.theme) private var theme
    var entry: NextBusEntry
    var arrival: WidgetArrival
    var metrics: Metrics

    var body: some View {
        HStack(alignment: .center, spacing: metrics.gap) {
            WidgetBadge(number: entry.line(for: arrival)?.shortName ?? arrival.lineID,
                        colorIndex: entry.colorIndex(for: arrival.lineID),
                        side: metrics.badge, numeralSize: metrics.numeral,
                        ring: metrics.ringed ? .for(side: metrics.badge) : nil)
            VStack(alignment: .leading, spacing: 2) {
                // Only where it fits whole: the THEN beside it already says which bus this is.
                if metrics.kicker > 0 {
                    ViewThatFits(in: .horizontal) {
                        Text(ReadoutKicker.nextArrival.text)
                            .busText(TypeStyle(.spaceMonoBold, metrics.kicker, tracking: 0.16))
                            .foregroundStyle(theme.captionText)
                            .widgetCaptionLine(metrics.kicker)
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
                WidgetMinutes(arrival: arrival, date: entry.date, colorIndex: entry.colorIndex(for: arrival.lineID),
                              numberStyle: TypeStyle(.archivoBlack, metrics.minutes, tracking: -0.04, lineHeight: 0.86),
                              unitStyle: TypeStyle(.archivoBlack, metrics.unit, tracking: 0.02),
                              spacing: metrics.minutes * 0.1)
                WidgetSubline(arrival: arrival, size: metrics.subline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The bus after the next one. Clearly secondary, as on the board: a card beside the readout, or
/// a single line where there is no room for one.
struct WidgetThenCard: View {
    enum Style { case card, row }

    @Environment(\.theme) private var theme
    var entry: NextBusEntry
    var arrival: WidgetArrival
    var style: Style
    var scale: CGFloat = 1

    var body: some View {
        switch style {
        case .card: card
        case .row: row
        }
    }

    /// Where the card is short, its sub-line goes rather than spilling out of it.
    private var card: some View {
        ViewThatFits(in: .vertical) {
            cardContent(showsSubline: true)
            cardContent(showsSubline: false)
        }
        .padding(12 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(WidgetCardBackground(radius: 16 * scale))
    }

    private func cardContent(showsSubline: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            label
            HStack(spacing: 8 * scale) {
                badge(side: 28 * scale, numeral: 14 * scale)
                minutes(size: 30 * scale, unit: 13 * scale)
            }
            if showsSubline {
                WidgetSubline(arrival: arrival, size: 12, includesArrivesWord: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Where the row is narrow (the watch, in a longer language) the time goes before THEN is cut.
    private var row: some View {
        ViewThatFits(in: .horizontal) {
            rowContent(showsTime: true)
            rowContent(showsTime: false)
        }
        .padding(.horizontal, 14 * scale)
        .frame(height: 52 * scale)
        .frame(maxWidth: .infinity)
        .background(WidgetCardBackground(radius: 16 * scale))
    }

    private func rowContent(showsTime: Bool) -> some View {
        HStack(spacing: 10 * scale) {
            label
            badge(side: 30 * scale, numeral: 15 * scale)
            minutes(size: 30 * scale, unit: 13 * scale)
            Spacer(minLength: 0)
            if showsTime {
                WidgetSubline(arrival: arrival, size: 12, includesArrivesWord: false)
            }
        }
    }

    private var label: some View {
        Text("THEN")
            .busText(TypeStyle(.spaceMonoBold, 12, tracking: 0.16))
            .foregroundStyle(theme.captionText)
            .widgetCaptionLine()
    }

    private func badge(side: CGFloat, numeral: CGFloat) -> some View {
        WidgetBadge(number: entry.line(for: arrival)?.shortName ?? arrival.lineID,
                    colorIndex: entry.colorIndex(for: arrival.lineID), side: side, numeralSize: numeral)
    }

    private func minutes(size: CGFloat, unit: CGFloat) -> some View {
        WidgetMinutes(arrival: arrival, date: entry.date, colorIndex: entry.colorIndex(for: arrival.lineID),
                      numberStyle: TypeStyle(.archivoBlack, size, tracking: -0.036, lineHeight: 0.9),
                      unitStyle: TypeStyle(.archivoBlack, unit), spacing: 4, unitColor: theme.secondaryText)
    }
}

/// One later arrival at the chosen stop, for the large sizes' list.
struct WidgetArrivalRow: View {
    @Environment(\.theme) private var theme
    var entry: NextBusEntry
    var arrival: WidgetArrival

    var body: some View {
        HStack(spacing: 12) {
            WidgetBadge(number: entry.line(for: arrival)?.shortName ?? arrival.lineID,
                        colorIndex: entry.colorIndex(for: arrival.lineID), side: 30, numeralSize: 15)
            WidgetMinutes(arrival: arrival, date: entry.date, colorIndex: entry.colorIndex(for: arrival.lineID),
                          numberStyle: TypeStyle(.archivoBlack, 22, tracking: -0.03, lineHeight: 0.95),
                          unitStyle: TypeStyle(.archivoBlack, 12), spacing: 4, unitColor: theme.secondaryText)
            Spacer(minLength: 0)
            WidgetSubline(arrival: arrival, size: 12, includesArrivesWord: false)
        }
        .frame(height: 36)
    }
}

/// The bus after the next one as a column — THEN over its badge and minutes — trailing the large
/// widget's readout under the map, where a card would take the readout's width.
struct WidgetThenStack: View {
    @Environment(\.theme) private var theme
    var entry: NextBusEntry
    var arrival: WidgetArrival

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("THEN")
                .busText(TypeStyle(.spaceMonoBold, 12, tracking: 0.16))
                .foregroundStyle(theme.captionText)
                .widgetCaptionLine()
            HStack(spacing: 7) {
                WidgetBadge(number: entry.line(for: arrival)?.shortName ?? arrival.lineID,
                            colorIndex: entry.colorIndex(for: arrival.lineID), side: 30, numeralSize: 15)
                WidgetMinutes(arrival: arrival, date: entry.date, colorIndex: entry.colorIndex(for: arrival.lineID),
                              numberStyle: TypeStyle(.archivoBlack, 28, tracking: -0.03, lineHeight: 0.9),
                              unitStyle: TypeStyle(.archivoBlack, 13), spacing: 4, unitColor: theme.secondaryText)
            }
            WidgetSubline(arrival: arrival, size: 12, includesArrivesWord: false)
        }
        .fixedSize()
    }
}
