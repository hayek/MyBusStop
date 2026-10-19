import SwiftUI

/// The bus after the one you are catching. Navigation-app style: clearly secondary, still readable
/// from across a room.
struct ThenCardView: View {
    enum Style { case card, phoneRow, padBar, wallBar }

    @Environment(\.theme) private var theme
    var secondary: ReadoutSecondary
    var scale: CGFloat
    var style: Style

    var body: some View {
        switch style {
        case .card: card
        case .phoneRow: phoneRow
        case .padBar: padBar
        case .wallBar: wallBar
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            label
            HStack(spacing: 18 * scale) {
                badge(side: 56, radius: 14, numeral: 30)
                MinutesView(arrival: secondary.arrival, colorIndex: secondary.colorIndex,
                            numberStyle: TypeStyles.minutesSecondary, unitStyle: TypeStyles.unitSecondary,
                            scale: scale, spacing: 8, unitColor: theme.secondaryText)
            }
            ReadoutSubline(arrival: secondary.arrival, scale: scale,
                           stopsStyle: TypeStyles.thenSub, timeStyle: TypeStyles.thenSub,
                           spacing: 8, includesStopsWord: false,
                           timeColor: theme.captionText, stopsColor: theme.captionText)
        }
        .padding(.vertical, 20 * scale)
        .padding(.horizontal, 24 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(background(radius: Radius.readoutCard * scale))
    }

    private var phoneRow: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            label
            HStack(spacing: 16 * scale) {
                badge(side: 48, radius: 12, numeral: 24)
                MinutesView(arrival: secondary.arrival, colorIndex: secondary.colorIndex,
                            numberStyle: TypeStyles.minutesSecondaryPhone, unitStyle: TypeStyles.unitSecondaryPhone,
                            scale: scale, spacing: 8, unitColor: theme.secondaryText)
                Spacer(minLength: 0)
                ReadoutSubline(arrival: secondary.arrival, scale: scale,
                               stopsStyle: TypeStyles.thenSubPhone, timeStyle: TypeStyles.thenSubPhone,
                               spacing: 6, includesStopsWord: false,
                               timeColor: theme.captionText, stopsColor: theme.captionText,
                               isStacked: true)
            }
        }
    }

    private var padBar: some View {
        HStack(spacing: 22 * scale) {
            label
            badge(side: 60, radius: 15, numeral: 30)
            MinutesView(arrival: secondary.arrival, colorIndex: secondary.colorIndex,
                        numberStyle: TypeStyles.minutesSecondaryPad, unitStyle: TypeStyles.unitSecondary,
                        scale: scale, spacing: 8, unitColor: theme.secondaryText)
            Spacer(minLength: 0)
            ReadoutSubline(arrival: secondary.arrival, scale: scale,
                           stopsStyle: TypeStyles.thenSub, timeStyle: TypeStyles.thenSub,
                           spacing: 8, includesStopsWord: false,
                           timeColor: theme.captionText, stopsColor: theme.captionText)
        }
        .padding(.horizontal, 26 * scale)
        .frame(height: 108 * scale)
        .frame(maxWidth: .infinity)
        .background(background(radius: Radius.readoutCard * scale))
    }

    /// Under the wall display's next arrival, in a column a third of the board wide: laid out as
    /// the phone's row, the stops and the time stacked beside the minutes, on the card's ground.
    private var wallBar: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            label
            HStack(spacing: 16 * scale) {
                badge(side: 52, radius: 13, numeral: 27)
                MinutesView(arrival: secondary.arrival, colorIndex: secondary.colorIndex,
                            numberStyle: TypeStyles.minutesSecondaryPad, unitStyle: TypeStyles.unitSecondary,
                            scale: scale, spacing: 8, unitColor: theme.secondaryText)
                Spacer(minLength: 0)
                ReadoutSubline(arrival: secondary.arrival, scale: scale,
                               stopsStyle: TypeStyles.thenLabel, timeStyle: TypeStyles.thenLabel,
                               spacing: 6, includesStopsWord: false,
                               timeColor: theme.captionText, stopsColor: theme.captionText,
                               isStacked: true)
            }
        }
        .padding(.vertical, 18 * scale)
        .padding(.horizontal, 22 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(radius: 22 * scale))
    }

    private var label: some View {
        Text("THEN")
            .busText(style == .phoneRow ? TypeStyles.thenLabelPhone : TypeStyles.thenLabel, scale: scale)
            .foregroundStyle(style == .phoneRow ? theme.secondaryText : theme.captionText)
    }

    private func badge(side: CGFloat, radius: CGFloat, numeral: CGFloat) -> some View {
        LineBadgeView(number: secondary.line.shortName, colorIndex: secondary.colorIndex,
                      side: side * scale, cornerRadius: radius * scale,
                      numeralSize: numeral * scale, ring: nil)
    }

    @ViewBuilder private func background(radius: CGFloat) -> some View {
        if theme.isLight {
            // Light mode is one continuous cream ground: the card becomes a rule, not a panel.
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(theme.cardOutline, lineWidth: Stroke.cardOutline * scale)
        } else {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(theme.card)
        }
    }
}
