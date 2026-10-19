import SwiftUI

/// The "beside" answer to tapping a bus: the next arrival keeps its place and shrinks, and the bus
/// you tapped opens here, outlined in its own colour. Nothing about crowding — no feed gives it.
struct TappedBusCardView: View {
    @Environment(\.theme) private var theme
    var detail: TappedBusDetail
    var scale: CGFloat
    var onDismiss: () -> Void
    /// The ⓘ in the header: the bus's line on a card of its own. Nil leaves it out (a wall display).
    var onAboutLine: (() -> Void)? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14 * scale) {
                header
                headline
                footnote(at: context.now)
            }
            .padding(.vertical, 18 * scale)
            .padding(.horizontal, 22 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.readoutCard * scale, style: .continuous)
                .fill(theme.outlinedCard))
            .overlay(RoundedRectangle(cornerRadius: Radius.readoutCard * scale, style: .continuous)
                .strokeBorder(theme.rail(detail.colorIndex), lineWidth: Stroke.tappedCardBorder * scale))
        }
        // There is no close button: a tap anywhere else on the board lets go of the bus, so a tap
        // on the card itself is kept here rather than falling through to that.
        .contentShape(Rectangle())
        .onTapGesture {}
        // Escape still lets go from a keyboard, which the close button used to carry. Apple TV's
        // Menu button does it there instead (TVBoardScreen), and a hidden button would take focus.
        #if !os(tvOS)
        .background {
            Button("", action: onDismiss)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        #endif
        .accessibilityElement(children: .contain)
        // The scrub gesture stands in for the tap elsewhere, which VoiceOver has no way to aim.
        .accessibilityAction(.escape, onDismiss)
    }

    private var header: some View {
        HStack(spacing: 14 * scale) {
            LineBadgeView(number: detail.line.shortName, colorIndex: detail.colorIndex,
                          side: 40 * scale, cornerRadius: 10 * scale, numeralSize: 22 * scale, ring: nil)
            Text("TAPPED BUS")
                .busText(TypeStyles.tappedKicker, scale: scale)
                .foregroundStyle(theme.lineText(detail.colorIndex))
                .lineLimit(1)
            Spacer(minLength: 0)
            delayBadge
            #if !os(tvOS)
            if let onAboutLine {
                LineInfoButton(lineNumber: detail.line.shortName, scale: scale, action: onAboutLine)
                    // The glyph to the card's inner edge; its target reaches into the padding.
                    .padding(.trailing, -12 * scale)
                    .padding(.vertical, -10 * scale)
            }
            #endif
        }
    }

    /// Lateness is a badge in the header rather than a clause at the end of the footnote, where the
    /// last stop's name pushed it off the card.
    @ViewBuilder private var delayBadge: some View {
        if let text = DelayPhrase.text(for: detail.arrival?.delay) {
            let tint = DelayPhrase.isLate(detail.arrival?.delay) ? theme.late : theme.secondaryText
            Text(text)
                .busText(TypeStyles.tappedDetail, scale: scale)
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10 * scale)
                .padding(.vertical, 5 * scale)
                .background(Capsule().fill(tint.opacity(0.14)))
                .overlay(Capsule().strokeBorder(tint, lineWidth: 1.5 * scale))
        }
    }

    @ViewBuilder private var headline: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12 * scale) {
            if let arrival = detail.arrival {
                MinutesView(arrival: arrival, colorIndex: detail.colorIndex,
                            numberStyle: TypeStyles.tappedMinutes, unitStyle: TypeStyles.tappedUnit,
                            scale: scale, spacing: 12,
                            unitColor: theme.isLight ? theme.secondaryText : theme.rail(detail.colorIndex))
                SeparatorDot(scale: scale)
            }
            Text("\(detail.bus.stopsAway) STOPS AWAY")
                .busText(TypeStyles.tappedStops, scale: scale)
                .foregroundStyle(theme.primaryText)
        }
    }

    @ViewBuilder private func footnote(at now: Date) -> some View {
        if let lastStop = LastStopPhrase.text(for: detail.bus, at: now) {
            Text(lastStop)
                .busText(TypeStyles.tappedDetail, scale: scale)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
    }
}

/// The X on the close button, drawn rather than borrowed from a symbol set.
struct CloseGlyph: View {
    @Environment(\.theme) private var theme
    var scale: CGFloat

    var body: some View {
        Path { path in
            let size = 14 * scale
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: size, y: size))
            path.move(to: CGPoint(x: size, y: 0))
            path.addLine(to: CGPoint(x: 0, y: size))
        }
        .stroke(theme.primaryText, style: StrokeStyle(lineWidth: Stroke.closeGlyph * scale, lineCap: .round))
        .frame(width: 14 * scale, height: 14 * scale)
        .accessibilityHidden(true)
    }
}
