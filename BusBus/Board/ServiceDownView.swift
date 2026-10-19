import SwiftUI

/// What the board shows in place of itself while its feed is down, the device is offline, or the
/// provider has been switched off remotely.
///
/// It is drawn in the board's own language — the same bands, faces and margins — so a wall display
/// that loses its feed still looks like the board, only saying something else. It never scrolls and
/// never needs a tap to go away: the board keeps polling behind it and takes the screen back on the
/// first good answer.
struct ServiceDownView: View {
    @Environment(\.theme) private var theme
    var layout: BoardLayout
    var status: ServiceStatus
    /// "Israel · bus.gov.il": whose data the board is waiting on.
    var serviceName: String
    var lastSuccessAt: Date?
    /// A line of news from the Firebase console, shown verbatim when there is one.
    var statusMessage: String = ""
    var onChangeStop: () -> Void
    var onSettings: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                topBar
                    .frame(height: layout.headerHeight)
                    .padding(.leading, layout.contentInsetLeading)
                    .padding(.trailing, layout.contentInsetTrailing)
                message
                    .padding(.leading, layout.contentInsetLeading)
                    .padding(.trailing, layout.contentInsetTrailing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                band(now: context.now)
            }
        }
        .analyticsScreen("service_down")
    }

    // MARK: Words

    private var headline: LocalizedStringKey {
        switch status {
        case .offline: "NO CONNECTION"
        case .disabled: "TEMPORARILY UNAVAILABLE"
        case .down, .healthy: "SERVICE DOWN"
        }
    }

    private var explanation: LocalizedStringKey {
        switch status {
        case .offline: "Your device is offline. The board will come back by itself once it reconnects."
        case .disabled: "Live data here is paused for now. The board will come back by itself."
        case .down, .healthy: "We're working on a fix. The board will come back by itself."
        }
    }

    private var accent: Color {
        switch status {
        case .down, .healthy: theme.late
        case .offline: theme.stale
        case .disabled: theme.secondaryText
        }
    }

    private func lastData(now: Date) -> String {
        guard let lastSuccessAt else { return String(appLocalized: "NO DATA RECEIVED YET") }
        let minutes = max(1, Int((now.timeIntervalSince(lastSuccessAt) / 60).rounded(.up)))
        if minutes < 60 { return String(appLocalized: "LAST DATA \(minutes) MIN AGO") }
        let sameDay = Calendar.current.isDate(lastSuccessAt, inSameDayAs: now)
        let time = lastSuccessAt.formatted(Date.FormatStyle(date: sameDay ? .omitted : .abbreviated, time: .shortened)
            .locale(AppLanguage.locale))
        return String(appLocalized: "LAST DATA AT \(time)")
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack(alignment: .center, spacing: Spacing.headerGap * layout.scale) {
            Text(verbatim: serviceName)
                .busText(layout.captionStyle, scale: layout.scale)
                .foregroundStyle(theme.headerCaption)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: (layout.mode == .phone ? Spacing.headerTrailingGapPhone
                                                                        : Spacing.headerTrailingGap) * layout.scale) {
                ClockView(style: layout.clockStyle, scale: layout.scale)
                SettingsGearButton(size: 20 * layout.scale, action: onSettings)
            }
        }
    }

    @ViewBuilder private var message: some View {
        if layout.isPortrait {
            VStack(alignment: .leading, spacing: 22 * layout.scale) {
                BrokenRailGlyph(accent: accent, scale: layout.scale)
                headlineText
                explanationText
                notice
            }
        } else {
            HStack(alignment: .center, spacing: 56 * layout.scale) {
                VStack(alignment: .leading, spacing: 24 * layout.scale) {
                    BrokenRailGlyph(accent: accent, scale: layout.scale)
                    headlineText
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 22 * layout.scale) {
                    explanationText
                    notice
                }
                .frame(width: layout.mapSize.width * 0.4, alignment: .leading)
            }
        }
    }

    private var headlineText: some View {
        Text(headline)
            .busText(headlineStyle, scale: layout.scale)
            .foregroundStyle(theme.primaryText)
            .lineLimit(3)
            .minimumScaleFactor(0.5)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private var explanationText: some View {
        Text(explanation)
            .busText(bodyStyle, scale: layout.scale)
            .foregroundStyle(theme.captionText)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var notice: some View {
        let trimmed = statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            HStack(alignment: .top, spacing: 12 * layout.scale) {
                RoundedRectangle(cornerRadius: 2 * layout.scale)
                    .fill(accent)
                    .frame(width: 4 * layout.scale)
                Text(verbatim: trimmed)
                    .busText(noticeStyle, scale: layout.scale)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(16 * layout.scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.row * layout.scale, style: .continuous)
                .fill(theme.card))
        }
    }

    /// The readout band's place: when the data stopped, that it is still being asked for, and the
    /// way to a different stop.
    private func band(now: Date) -> some View {
        let captions = VStack(alignment: .leading, spacing: 8 * layout.scale) {
            Text(lastData(now: now))
                .busText(kickerStyle, scale: layout.scale)
                .foregroundStyle(theme.captionText)
            HStack(spacing: 8 * layout.scale) {
                Circle().fill(theme.stale).frame(width: 8 * layout.scale, height: 8 * layout.scale)
                Text("CHECKING AGAIN AUTOMATICALLY")
                    .busText(layout.mode == .phone ? TypeStyles.countCaptionPhone : TypeStyles.countCaption,
                             scale: layout.scale)
                    .foregroundStyle(theme.dashCaption)
            }
        }
        let button = Button(action: onChangeStop) {
            Text("CHANGE STOP")
                .busText(layout.mode == .phone ? TypeStyles.primaryButtonPhone : TypeStyles.primaryButton,
                         scale: layout.scale)
                .foregroundStyle(theme.primaryButtonText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 32 * layout.scale)
                .frame(maxWidth: layout.mode == .phone ? .infinity : nil)
                .frame(height: (layout.mode == .phone ? Spacing.buttonHeightPhone : Spacing.buttonHeight) * layout.scale)
                .background(RoundedRectangle(cornerRadius: Radius.button * layout.scale, style: .continuous)
                    .fill(theme.primaryButtonFill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        return Group {
            if layout.mode == .phone {
                VStack(alignment: .leading, spacing: 18 * layout.scale) { captions; button }
            } else {
                HStack(alignment: .center, spacing: 24 * layout.scale) { captions; Spacer(minLength: 0); button }
            }
        }
        .padding(.leading, layout.contentInsetLeading)
        .padding(.trailing, layout.contentInsetTrailing)
        .padding(.vertical, (layout.mode == .phone ? 24 : 30) * layout.scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.readoutBand)
    }

    // MARK: Type

    private var headlineStyle: TypeStyle {
        switch layout.mode {
        case .landscape, .landscapeSingle: TypeStyle(.archivoBlack, 84, tracking: -0.03)
        case .pad: TypeStyle(.archivoBlack, 92, tracking: -0.03)
        case .phone: TypeStyle(.archivoBlack, 52, tracking: -0.03)
        }
    }

    private var bodyStyle: TypeStyle {
        switch layout.mode {
        case .landscape, .landscapeSingle: TypeStyle(.archivoBold, 24, uppercase: false, minimum: 15, relativeTo: .body)
        case .pad: TypeStyle(.archivoBold, 26, uppercase: false, minimum: 15, relativeTo: .body)
        case .phone: TypeStyle(.archivoBold, 19, uppercase: false, minimum: 15, relativeTo: .body)
        }
    }

    private var noticeStyle: TypeStyle {
        TypeStyle(.spaceMonoBold, layout.mode == .phone ? 14 : 16, uppercase: false, minimum: 13, relativeTo: .callout)
    }

    private var kickerStyle: TypeStyle {
        layout.mode == .pad ? TypeStyles.kickerPad : TypeStyles.kicker
    }
}

/// A line's rail with its stop knocked out: the board's own mark for "the route is there, the
/// data is not".
private struct BrokenRailGlyph: View {
    @Environment(\.theme) private var theme
    var accent: Color
    var scale: CGFloat

    var body: some View {
        let height = 10 * scale
        HStack(spacing: 10 * scale) {
            Capsule().fill(theme.cardOutline).frame(width: 64 * scale, height: height)
            Circle()
                .strokeBorder(accent, lineWidth: 5 * scale)
                .frame(width: 30 * scale, height: 30 * scale)
            Capsule().fill(theme.cardOutline).frame(width: 28 * scale, height: height)
        }
        .accessibilityHidden(true)
    }
}
