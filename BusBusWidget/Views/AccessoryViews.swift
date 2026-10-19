import SwiftUI
import WidgetKit
// The views are also compiled into BusBusTests, which checks they fit every size.
#if !BUSBUS_WIDGET
@testable import BusBus
#endif

#if os(iOS) || os(watchOS)
/// Lock-screen circle: the line, the minutes, the unit — one bus, read in a glance. The
/// smallest watch's circle is shorter than the lock screen's: there the captions give up the
/// leading their face reserves, and the padding shrinks.
struct AccessoryCircularView: View {
    var entry: NextBusEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let arrival = entry.arrivals.first {
                ViewThatFits(in: .vertical) {
                    readout(arrival, compact: false)
                    readout(arrival, compact: true)
                }
            } else {
                Image(systemName: "bus.fill")
                    .font(.system(size: 22, weight: .bold))
                    .accessibilityLabel(entry.setup?.stop.name ?? String(appLocalized: "NO BUSES DUE"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func readout(_ arrival: WidgetArrival, compact: Bool) -> some View {
        let board = arrival.board
        return VStack(spacing: -1) {
            Text(verbatim: entry.line(for: arrival)?.shortName ?? arrival.lineID)
                .busText(TypeStyle(.spaceMonoBold, 12))
                .widgetAccentable()
                .captionLine(compact)
            if board.isImminent(at: entry.date) {
                Text("NOW")
                    .busText(TypeStyle(.archivoBlack, 16))
            } else {
                let countdown = board.countdown(at: entry.date)
                Text(verbatim: countdown.figure)
                    .busText(TypeStyle(.archivoBlack, countdown.isHours ? 18 : 24, tracking: -0.03))
                    .contentTransition(.numericText(countsDown: true))
                Text(countdown.isHours ? "HR" : "MIN")
                    .busText(TypeStyle(.spaceMonoBold, 12))
                    .captionLine(compact)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(compact ? 2 : 4)
    }
}

/// Lock-screen rectangle: the stop, the next bus with its time, and the one after. A watch's
/// rectangle is shorter: there the THEN line goes first, then the message's second line.
struct AccessoryRectangularView: View {
    var entry: NextBusEntry

    var body: some View {
        ViewThatFits(in: .vertical) {
            content(compact: false, showsThen: true)
            content(compact: true, showsThen: true)
            content(compact: true, showsThen: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `compact` sets the captions in the line box their capitals use (`widgetCaptionLine`).
    private func content(compact: Bool, showsThen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if !compact || entry.setup != nil {
                Text(verbatim: entry.setup?.stop.name ?? "")
                    .busText(TypeStyle(.spaceMonoBold, 12, tracking: 0.04))
                    .lineLimit(1)
                    .widgetAccentable()
                    .captionLine(compact)
            }
            if let arrival = entry.arrivals.first {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    WidgetBadge(number: entry.line(for: arrival)?.shortName ?? arrival.lineID,
                                colorIndex: entry.colorIndex(for: arrival.lineID), side: 20, numeralSize: 12)
                        .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 3 }
                    WidgetMinutes(arrival: arrival, date: entry.date, colorIndex: entry.colorIndex(for: arrival.lineID),
                                  numberStyle: TypeStyle(.archivoBlack, 22, tracking: -0.03, lineHeight: 1),
                                  unitStyle: TypeStyle(.archivoBlack, 12), spacing: 3)
                        .fixedSize()
                    Text(verbatim: WidgetFormat.time(arrival.expectedAt))
                        .busText(TypeStyle(.spaceMonoBold, 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if showsThen, let then = entry.arrivals.dropFirst().first {
                    HStack(spacing: 4) {
                        Text("THEN")
                        Text(verbatim: entry.line(for: then)?.shortName ?? then.lineID)
                        Text(verbatim: "·")
                        Text(verbatim: then.board.isImminent(at: entry.date) ? String(appLocalized: "NOW")
                                                                               : shortCountdown(then))
                    }
                    .busText(TypeStyle(.spaceMonoBold, 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .captionLine(compact)
                }
            } else if let message = WidgetMessage(entry) {
                Text(message.title)
                    .busText(TypeStyle(.archivoBlack, 16))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(detail(for: message))
                    .busText(TypeStyle(.spaceMonoBold, 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(showsThen ? 2 : 1)
                    .captionLine(compact && !showsThen)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(for message: WidgetMessage) -> LocalizedStringKey {
        #if os(watchOS)
        message.watchDetail(snapshotOnly: entry.setup.map(WidgetProviderGate.isSnapshotOnly) ?? false)
        #else
        message.detail
        #endif
    }

    private func shortCountdown(_ arrival: WidgetArrival) -> String {
        let countdown = arrival.board.countdown(at: entry.date)
        return "\(countdown.figure) " + String(appLocalized: countdown.isHours ? "HR" : "MIN")
    }
}

private extension View {
    /// `widgetCaptionLine` where room is short, the view as it is elsewhere.
    @ViewBuilder func captionLine(_ compact: Bool) -> some View {
        if compact { widgetCaptionLine() } else { self }
    }
}

/// Lock-screen line above the clock. One `Text`: the system sets it in its own face and size.
struct AccessoryInlineView: View {
    var entry: NextBusEntry

    var body: some View {
        if let arrival = entry.arrivals.first {
            let board = arrival.board
            let countdown = board.countdown(at: entry.date)
            let line = entry.line(for: arrival)?.shortName ?? arrival.lineID
            let wait = board.isImminent(at: entry.date)
                ? String(appLocalized: "NOW")
                : "\(countdown.figure) " + String(appLocalized: countdown.isHours ? "HR" : "MIN")
            Label {
                Text(verbatim: "\(line) · \(wait) · \(entry.setup?.stop.name ?? "")")
            } icon: {
                Image(systemName: "bus.fill")
            }
        } else if let message = WidgetMessage(entry) {
            Label {
                Text(message.title)
            } icon: {
                Image(systemName: "bus.fill")
            }
        }
    }
}
/// Watch corner: the line number in the corner, the countdown curved along the bezel as the
/// label; with nothing due, the bus glyph and the stop's name. The label is a watch-only modifier,
/// so the struct compiles on iOS (where the fit tests measure it) without one.
struct AccessoryCornerView: View {
    var entry: NextBusEntry

    var body: some View {
        content
            #if os(watchOS)
            .widgetLabel { Text(verbatim: label) }
            #endif
    }

    @ViewBuilder private var content: some View {
        if let arrival = entry.arrivals.first {
            Text(verbatim: entry.line(for: arrival)?.shortName ?? arrival.lineID)
                .busText(TypeStyle(.archivoBlack, 22, tracking: -0.02))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .widgetAccentable()
        } else {
            Image(systemName: "bus.fill").font(.system(size: 20, weight: .bold))
        }
    }

    /// "4 MIN", "NOW", "1:15 HR", or the stop's name when nothing is due.
    var label: String {
        guard let arrival = entry.arrivals.first else {
            return entry.setup?.stop.name ?? messageTitle
        }
        let board = arrival.board
        if board.isImminent(at: entry.date) { return String(appLocalized: "NOW") }
        let countdown = board.countdown(at: entry.date)
        return "\(countdown.figure) " + String(appLocalized: countdown.isHours ? "HR" : "MIN")
    }

    /// `WidgetMessage.title` as a string: its keys, which the label cannot take as a `LocalizedStringKey`.
    private var messageTitle: String {
        switch WidgetMessage(entry) {
        case .noHistory, .notConfigured: String(appLocalized: "CHOOSE YOUR STOP")
        case .expired: String(appLocalized: "NO LIVE DATA")
        case .noBusesDue, nil: String(appLocalized: "NO BUSES DUE")
        }
    }
}
#endif
