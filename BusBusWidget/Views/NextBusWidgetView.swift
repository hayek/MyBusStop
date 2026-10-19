import SwiftUI
import WidgetKit
// The views are also compiled into BusBusTests, which checks they fit every size.
#if !BUSBUS_WIDGET
@testable import BusBus
#endif

/// The widget in each of its sizes. One design, the board's, arranged for the space each gives:
///
/// - small: the next bus alone — badge, numeral, the stop, and what follows it; in StandBy, the
///   badge and a numeral big enough for the far side of a room;
/// - medium: the readout's primary block and the THEN card side by side;
/// - large: the board's map over the readout, its badge ringed as on the board, THEN trailing; or,
///   as the rider chooses, the readout over the later arrivals at this stop;
/// - extra large: the map in one column, and in the other the readout, THEN and the later arrivals
///   there is room for; or the readout and the later arrivals side by side;
/// - extra large portrait, three smalls tall: the large widget's order with room to spare — the map
///   over the extra large readout and THEN; or that readout over a long list of later arrivals;
///
/// Only ever the one stop the widget is set to: the rest of the history is for choosing it.
/// - lock screen: the next bus in the system's own vibrant rendering.
struct NextBusWidgetView: View {
    @Environment(\.widgetFamily) private var hostFamily
    var entry: NextBusEntry
    /// The size to draw, where no widget host says: the widget screenshots render outside one,
    /// and `widgetFamily` cannot be set from outside.
    var family: WidgetFamily?
    /// Likewise whether the system shows the container background; false draws StandBy's.
    var showsBackground: Bool?

    var body: some View {
        content
            .modifier(WidgetEnvironment(appearance: entry.appearance, showsBackgroundOverride: showsBackground))
            .widgetURL(WidgetDeepLink.url(for: entry.setup))
    }

    @ViewBuilder private var content: some View {
        switch family ?? hostFamily {
        case .systemSmall: SmallWidgetView(entry: entry)
        case .systemMedium: MediumWidgetView(entry: entry)
        case .systemLarge: LargeWidgetView(entry: entry, arrangement: .stack)
        case .systemExtraLarge: LargeWidgetView(entry: entry, arrangement: .columns)
        case .systemExtraLargePortrait: LargeWidgetView(entry: entry, arrangement: .portrait)
        #if os(iOS)
        case .accessoryCircular: AccessoryCircularView(entry: entry)
        case .accessoryRectangular: AccessoryRectangularView(entry: entry)
        case .accessoryInline: AccessoryInlineView(entry: entry)
        #endif
        default: SmallWidgetView(entry: entry)
        }
    }
}

// MARK: Small

/// The next bus alone. On the smallest widgets the badge and numeral step down a size, and past
/// that the bus after it goes, before anything is cut off.
struct SmallWidgetView: View {
    @Environment(\.theme) private var theme
    @Environment(\.widgetIsBackgroundless) private var standBy
    var entry: NextBusEntry

    var body: some View {
        if standBy {
            StandByWidgetView(entry: entry)
        } else if let arrival = entry.arrivals.first {
            ViewThatFits(in: .vertical) {
                layout(arrival, badge: 34, minutes: 54, showsFootnote: true)
                layout(arrival, badge: 28, minutes: 46, showsFootnote: true)
                layout(arrival, badge: 28, minutes: 46, showsFootnote: false)
            }
        } else if let message = WidgetMessage(entry) {
            WidgetMessageView(entry: entry, message: message, titleSize: 18)
        }
    }

    private func layout(_ arrival: WidgetArrival, badge: CGFloat, minutes: CGFloat, showsFootnote: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                WidgetBadge(number: entry.line(for: arrival)?.shortName ?? arrival.lineID,
                            colorIndex: entry.colorIndex(for: arrival.lineID), side: badge, numeralSize: badge / 2)
                Spacer(minLength: 0)
                WidgetLiveDot(liveness: entry.liveness, showsLabel: false)
                    .padding(.top, 4)
            }
            Spacer(minLength: 4)
            WidgetMinutes(arrival: arrival, date: entry.date, colorIndex: entry.colorIndex(for: arrival.lineID),
                          numberStyle: TypeStyle(.archivoBlack, minutes, tracking: -0.04, lineHeight: 0.86),
                          unitStyle: TypeStyle(.archivoBlack, 16, tracking: 0.02), spacing: 5)
            Spacer(minLength: 4)
            Text(verbatim: entry.setup?.stop.name ?? "")
                .busText(TypeStyle(.spaceMonoBold, 12, tracking: 0.06))
                .foregroundStyle(theme.stopName)
                .minimumScaleFactor(0.7)
                .widgetCaptionLine()
            if showsFootnote {
                footnote(after: arrival)
            }
        }
    }

    /// "THEN 41 · 8 MIN" when another bus follows; otherwise when this one arrives.
    @ViewBuilder private func footnote(after arrival: WidgetArrival) -> some View {
        Group {
            if let then = entry.arrivals.dropFirst().first {
                HStack(spacing: 4) {
                    Text("THEN")
                    Text(verbatim: entry.line(for: then)?.shortName ?? then.lineID)
                    Text(verbatim: "·")
                    if then.board.isImminent(at: entry.date) {
                        Text("NOW")
                    } else {
                        let countdown = then.board.countdown(at: entry.date)
                        Text(verbatim: countdown.figure)
                        Text(countdown.isHours ? "HR" : "MIN")
                    }
                }
            } else {
                Text(String(appLocalized: "ARRIVES \(WidgetFormat.time(arrival.expectedAt))"))
            }
        }
        .busText(TypeStyle(.spaceMonoBold, 12, tracking: 0.04))
        .foregroundStyle(theme.dashCaption)
        .minimumScaleFactor(0.8)
        .widgetCaptionLine()
    }
}

// MARK: StandBy

/// The small widget on a nightstand: StandBy takes its background away and scales it up more than
/// twice, to be read from bed. The wall board's rule applies — one thing, big: the line's badge,
/// the minutes as large as they go, and the stop's name; the bus after it, the live label and
/// anything else from the history go.
/// At night the system draws it in red by luminance alone, which the monochrome theme is made for.
struct StandByWidgetView: View {
    @Environment(\.theme) private var theme
    var entry: NextBusEntry

    var body: some View {
        if let arrival = entry.arrivals.first {
            // As large as the height allows; a numeral too wide for it shrinks in place.
            ViewThatFits(in: .vertical) {
                layout(arrival, badge: 44, minutes: 96, showsStop: true)
                layout(arrival, badge: 40, minutes: 88, showsStop: true)
                layout(arrival, badge: 40, minutes: 76, showsStop: true)
                layout(arrival, badge: 34, minutes: 64, showsStop: true)
                layout(arrival, badge: 34, minutes: 64, showsStop: false)
            }
        } else if let message = WidgetMessage(entry) {
            WidgetMessageView(entry: entry, message: message, titleSize: 20, showsBadges: false)
        }
    }

    private func layout(_ arrival: WidgetArrival, badge: CGFloat, minutes: CGFloat, showsStop: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                WidgetBadge(number: entry.line(for: arrival)?.shortName ?? arrival.lineID,
                            colorIndex: entry.colorIndex(for: arrival.lineID), side: badge, numeralSize: badge / 2)
                Spacer(minLength: 0)
                WidgetLiveDot(liveness: entry.liveness, showsLabel: false)
            }
            Spacer(minLength: 2)
            WidgetMinutes(arrival: arrival, date: entry.date, colorIndex: entry.colorIndex(for: arrival.lineID),
                          numberStyle: TypeStyle(.archivoBlack, minutes, tracking: -0.04, lineHeight: 0.86),
                          unitStyle: TypeStyle(.archivoBlack, (minutes * 0.26).rounded(), tracking: 0.02),
                          spacing: 4)
            if showsStop {
                Spacer(minLength: 2)
                Text(verbatim: entry.setup?.stop.name ?? "")
                    .busText(TypeStyle(.spaceMonoBold, 13, tracking: 0.04))
                    .foregroundStyle(theme.stopName)
                    .minimumScaleFactor(0.7)
                    .widgetCaptionLine(13)
            }
        }
    }
}

// MARK: Medium

struct MediumWidgetView: View {
    var entry: NextBusEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(entry: entry, titleSize: 17, showsCode: false)
            if let arrival = entry.arrivals.first {
                HStack(spacing: 12) {
                    WidgetPrimaryReadout(entry: entry, arrival: arrival, metrics: .medium)
                    if let then = entry.arrivals.dropFirst().first {
                        WidgetThenCard(entry: entry, arrival: then, style: .card)
                            .frame(width: 124)
                    }
                }
                .frame(maxHeight: .infinity)
            } else if let message = WidgetMessage(entry) {
                WidgetMessageView(entry: entry, message: message, titleSize: 20)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

// MARK: Large and extra large

/// One stop, however large: the widget shows the stop it is set to and nothing else from the
/// history. Whatever the map or the list leaves goes to the next bus.
struct LargeWidgetView: View {
    enum Arrangement {
        /// Large: the map over the readout, or the readout over the later buses.
        case stack
        /// Extra large: the map beside the readout, or the readout beside the later buses.
        case columns
        /// Extra large portrait: stacked as the large one is, with the extra large's type.
        case portrait
    }

    @Environment(\.theme) private var theme
    var entry: NextBusEntry
    var arrangement: Arrangement

    private var columns: Bool { arrangement == .columns }
    /// The extra large sizes, either way up.
    private var roomy: Bool { arrangement != .stack }

    /// The map, when that is the content and there are routes to draw it from.
    private var map: WidgetMapFrame? { entry.content == .map ? entry.map : nil }

    /// The later buses listed, beyond the readout's two.
    private var laterRows: Int {
        switch (arrangement, map != nil) {
        case (.portrait, true), (.stack, true): 0
        case (.columns, true): WidgetLayout.extraLargeMapLaterRows
        case (.portrait, false): WidgetLayout.extraLargePortraitLaterRows
        case (.columns, false): WidgetLayout.extraLargeLaterRows
        case (.stack, false): WidgetLayout.largeLaterRows
        }
    }

    var body: some View {
        if let map {
            switch arrangement {
            case .stack: mapStack(map)
            case .columns: mapColumns(map)
            case .portrait: mapPortrait(map)
            }
        } else if columns {
            HStack(alignment: .top, spacing: 20) {
                readout(metrics: .extraLarge)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                later
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        } else {
            VStack(alignment: .leading, spacing: roomy ? 16 : 12) {
                readout(metrics: roomy ? .extraLarge : .large)
                // All the height the readout leaves, so the list is offered every row it can fit.
                later
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: Map

    /// The board's own order: the stop, the map, and the next bus under it with THEN trailing.
    private func mapStack(_ map: WidgetMapFrame) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetHeader(entry: entry, titleSize: 20, showsCode: false)
            WidgetMapView(frame: map)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let arrival = entry.arrivals.first {
                HStack(alignment: .center, spacing: 10) {
                    WidgetPrimaryReadout(entry: entry, arrival: arrival, metrics: .largeMap)
                        .layoutPriority(1)
                    if let then = entry.arrivals.dropFirst().first {
                        WidgetThenStack(entry: entry, arrival: then)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if let message = WidgetMessage(entry) {
                // The map's termini already name the lines.
                WidgetMessageView(entry: entry, message: message, titleSize: 18, showsBadges: false)
            }
        }
    }

    /// The map down one side, as tall as the widget; down the other the next bus as large as the
    /// readout goes, THEN, and the later buses there is room left for.
    private func mapColumns(_ map: WidgetMapFrame) -> some View {
        HStack(alignment: .top, spacing: 20) {
            WidgetMapView(frame: map)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 14) {
                WidgetHeader(entry: entry, titleSize: 22, showsCode: true)
                if let arrival = entry.arrivals.first {
                    WidgetPrimaryReadout(entry: entry, arrival: arrival, metrics: .mapHero)
                    if let then = entry.arrivals.dropFirst().first {
                        WidgetThenCard(entry: entry, arrival: then, style: .row)
                    }
                } else if let message = WidgetMessage(entry) {
                    WidgetMessageView(entry: entry, message: message, titleSize: 22, showsBadges: false)
                }
                later
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// The map over the next bus, as on the large widget, with the room for the stop's code, a
    /// readout the extra large's size and the THEN card under it.
    private func mapPortrait(_ map: WidgetMapFrame) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            WidgetHeader(entry: entry, titleSize: 22, showsCode: true)
            WidgetMapView(frame: map)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let arrival = entry.arrivals.first {
                VStack(alignment: .leading, spacing: 14) {
                    WidgetPrimaryReadout(entry: entry, arrival: arrival, metrics: .mapHero)
                    if let then = entry.arrivals.dropFirst().first {
                        WidgetThenCard(entry: entry, arrival: then, style: .row, scale: 1.1)
                    }
                }
                // Whole, whatever the map is left with: the map folds to any box.
                .fixedSize(horizontal: false, vertical: true)
            } else if let message = WidgetMessage(entry) {
                WidgetMessageView(entry: entry, message: message, titleSize: 22, showsBadges: false)
            }
        }
    }

    private func readout(metrics: WidgetPrimaryReadout.Metrics) -> some View {
        VStack(alignment: .leading, spacing: roomy ? 12 : 10) {
            WidgetHeader(entry: entry, titleSize: roomy ? 24 : 20, showsCode: true)
            if let arrival = entry.arrivals.first, roomy {
                WidgetPrimaryReadout(entry: entry, arrival: arrival, metrics: metrics)
                if let then = entry.arrivals.dropFirst().first {
                    WidgetThenCard(entry: entry, arrival: then, style: .row, scale: 1.15)
                }
            } else if let arrival = entry.arrivals.first {
                // The medium widget's readout row, a size up: stacking the THEN card under it
                // would leave less room for the later buses.
                readoutRow(arrival, metrics: metrics)
            } else if let message = WidgetMessage(entry) {
                WidgetMessageView(entry: entry, message: message, titleSize: roomy ? 28 : 22)
            }
            if columns { Spacer(minLength: 0) }
        }
    }

    /// The next bus with the THEN card beside it.
    private func readoutRow(_ arrival: WidgetArrival, metrics: WidgetPrimaryReadout.Metrics) -> some View {
        HStack(spacing: 14) {
            WidgetPrimaryReadout(entry: entry, arrival: arrival, metrics: metrics)
            if let then = entry.arrivals.dropFirst().first {
                WidgetThenCard(entry: entry, arrival: then, style: .card)
                    .frame(width: 124)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The arrivals at this stop after the two the readout shows: as many rows as the widget has
    /// room for, never a cut-off one.
    @ViewBuilder private var later: some View {
        let later = Array(entry.arrivals.dropFirst(WidgetLayout.readoutArrivals).prefix(laterRows))
        if !later.isEmpty {
            ViewThatFits(in: .vertical) {
                ForEach((1...later.count).reversed(), id: \.self) { count in
                    VStack(alignment: .leading, spacing: 4) {
                        sectionHeader("LATER")
                        ForEach(later.prefix(count), id: \.self) { arrival in
                            WidgetArrivalRow(entry: entry, arrival: arrival)
                        }
                    }
                }
                // Beside the map the readout shares the column, and on the smallest extra large
                // widgets leaves no room for a row: the list goes rather than spill out.
                Color.clear.frame(height: 0)
            }
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .busText(TypeStyle(.spaceMonoBold, 12, tracking: 0.22))
            .foregroundStyle(theme.stopName)
            .widgetCaptionLine()
    }
}
