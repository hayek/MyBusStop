import SwiftUI

/// The big number and its unit, counting down locally between refreshes so the board stays honest
/// second by second instead of jumping every polling interval.
struct MinutesView: View {
    @Environment(\.theme) private var theme

    var arrival: BoardArrival
    var colorIndex: Int
    var numberStyle: TypeStyle
    var unitStyle: TypeStyle
    var scale: CGFloat
    var spacing: CGFloat = 14
    /// Secondary numbers keep a grey unit in both themes; the primary one takes the line colour
    /// in dark mode. Passing nil uses the theme's rule.
    var unitColor: Color?

    private var lineBox: CGFloat? { numberStyle.lineHeight.map { numberStyle.size * scale * $0 } }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let countdown = arrival.countdown(at: context.now)
            HStack(alignment: .lastTextBaseline, spacing: spacing * scale) {
                if arrival.isImminent(at: context.now) {
                    Text("NOW")
                        .busText(numberStyle, scale: scale * 0.62)
                        .foregroundStyle(theme.primaryText)
                } else {
                    Text(verbatim: countdown.figure)
                        .busText(numberStyle, scale: scale)
                        .foregroundStyle(theme.primaryText)
                        .contentTransition(.numericText(countsDown: true))
                        .monospacedDigit()
                    Text(countdown.isHours ? "HR" : "MIN")
                        .busText(unitStyle, scale: scale)
                        .foregroundStyle(unitColor ?? theme.unitColor(colorIndex))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            // Held to the artboard's line box rather than the face's own, which is half as tall
            // again as the figures it draws. Applied to the row so the unit keeps its baseline.
            .frame(height: lineBox)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(arrival.isImminent(at: context.now)
                                ? String(appLocalized: "Arriving now")
                                : countdown.spoken)
        }
    }
}

/// The small dot the artboards use between fragments of the sub-line.
struct SeparatorDot: View {
    @Environment(\.theme) private var theme
    var scale: CGFloat

    var body: some View {
        Circle()
            .fill(theme.separatorDot)
            .frame(width: Spacing.separatorDot * scale, height: Spacing.separatorDot * scale)
            .accessibilityHidden(true)
    }
}

/// "1 STOP AWAY · ARRIVES 14:33" — every fragment is optional, because the shipping
/// feed cannot always supply it. A missing fact is left out, never invented.
struct ReadoutSubline: View {
    @Environment(\.theme) private var theme

    var arrival: BoardArrival
    var scale: CGFloat
    var stopsStyle: TypeStyle = TypeStyles.subStopsAway
    var timeStyle: TypeStyle = TypeStyles.subArrives
    var spacing: CGFloat = 14
    var includesStopsWord: Bool = true
    /// iPad brightens the arrival time; the wall board keeps it quieter than the stops.
    var timeColor: Color?
    /// The THEN card sets its whole trailing line in one weight rather than picking out the stops.
    var stopsColor: Color?
    /// The phone's THEN row has no width for one line, so the artboards break it into two.
    var isStacked: Bool = false
    /// The phone's THEN row sets the two lines against its trailing edge; the wall's readout,
    /// which reads down from its leading edge, sets them there.
    var stackAlignment: HorizontalAlignment = .trailing

    @ViewBuilder var body: some View {
        if isStacked { stacked } else { inline }
    }

    private var stacked: some View {
        VStack(alignment: stackAlignment, spacing: 4 * scale) {
            if let stopsAway = arrival.bus?.stopsAway {
                Text(stopsText(stopsAway))
                    .busText(stopsStyle, scale: scale)
                    .foregroundStyle(stopsColor ?? theme.primaryText)
            }
            Text(timeText)
                .busText(timeStyle, scale: scale)
                .foregroundStyle(timeColor ?? theme.secondaryText)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var inline: some View {
        HStack(spacing: spacing * scale) {
            if let stopsAway = arrival.bus?.stopsAway {
                Text(stopsText(stopsAway))
                    .busText(stopsStyle, scale: scale)
                    .foregroundStyle(stopsColor ?? theme.primaryText)
                SeparatorDot(scale: scale)
            }
            // The tag is set smaller than the time, so it sits on the time's baseline rather than
            // floating at the row's centre. The dot stays centred: it has no baseline to share.
            HStack(alignment: .firstTextBaseline, spacing: spacing * scale) {
                Text(timeText)
                    .busText(timeStyle, scale: scale)
                    .foregroundStyle(timeColor ?? theme.secondaryText)
                if !arrival.isRealtime {
                    Text("SCHEDULED")
                        .busText(TypeStyles.scheduledTag, scale: scale)
                        .foregroundStyle(theme.dashCaption)
                }
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func stopsText(_ count: Int) -> String {
        includesStopsWord ? String(appLocalized: "\(count) STOPS AWAY") : String(appLocalized: "\(count) STOPS")
    }

    private var timeText: String {
        let time = arrival.expectedAt.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute().locale(AppLanguage.locale))
        return includesStopsWord ? String(appLocalized: "ARRIVES \(time)") : time
    }
}

/// How late the bus is, when the feed gives both a timetable and a live prediction. Positive is
/// late. Under a minute there is nothing to report: the board omits the fragment rather than
/// claiming the bus is on time, which is a promise no prediction can keep.
nonisolated enum DelayPhrase {
    static func text(for delay: TimeInterval?) -> String? {
        guard let delay else { return nil }
        let minutes = Int((abs(delay) / 60).rounded())
        guard minutes >= 1 else { return nil }
        return delay > 0 ? String(appLocalized: "\(minutes) MIN LATE") : String(appLocalized: "\(minutes) MIN EARLY")
    }

    static func isLate(_ delay: TimeInterval?) -> Bool { (delay ?? 0) >= 60 }
}

/// "LEFT OLD MILL 1 MIN AGO" — the stop comes from the route, the elapsed time only from our own
/// observation, so it appears once we have actually watched the bus move on.
nonisolated enum LastStopPhrase {
    static func text(for bus: BoardBus, at now: Date) -> String? {
        guard let name = bus.lastStopName else { return nil }
        if bus.isAtTerminus { return String(appLocalized: LocalizedStringResource("AT \(name)", comment: "The bus is waiting at this stop")) }
        guard let passedAt = bus.lastStopPassedAt else {
            return String(appLocalized: LocalizedStringResource("LEFT \(name)", comment: "The last stop the bus passed"))
        }
        let minutes = Int((now.timeIntervalSince(passedAt) / 60).rounded(.down))
        guard minutes >= 1 else { return String(appLocalized: "LEFT \(name) JUST NOW") }
        return String(appLocalized: "LEFT \(name) \(minutes) MIN AGO")
    }
}
