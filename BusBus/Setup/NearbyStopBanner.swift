import SwiftUI

#if !os(tvOS)
/// The stop the rider is standing at, dropped in from the top like a notification: its name, and
/// the lines they watch there — or, at a stop they have never set up, every line through it. A tap
/// opens that board, or the line picker first when there is no board yet.
///
/// Drawn on the inverted surface, as the first board's tip is, so it reads as laid on the screen
/// rather than part of it.
struct NearbyStopBanner: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    var alert: StopNearbyAlert
    var colorIndex: (TransitLine) -> Int
    var onOpen: () -> Void
    var onDismiss: () -> Void
    /// How far the rider's finger has carried it: up freely, down only a little, as a
    /// notification does.
    @State private var drag: CGFloat = 0

    /// Badges before the rest are counted: the banner has to stay one glance.
    private static let shownLines = 3
    /// Gone by itself, as a notification goes — except under VoiceOver, whose rider needs the time
    /// to find it.
    static let autoHideAfter: Duration = .seconds(12)

    private var kicker: String { String(appLocalized: "STOP NEAR YOU") }
    private var hint: String {
        alert.saved == nil ? String(appLocalized: "TAP TO CHOOSE YOUR LINES") : String(appLocalized: "TAP FOR YOUR BOARD")
    }

    var body: some View {
        let ink = theme.primaryButtonText
        HStack(alignment: .center, spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kicker)
                            .busText(TypeStyles.hint)
                            .foregroundStyle(ink.opacity(0.6))
                        Text(alert.stop.name)
                            .busText(TypeStyles.tipTitle)
                            .foregroundStyle(ink)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        Text(hint)
                            .busText(TypeStyles.hint)
                            .foregroundStyle(ink.opacity(0.75))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    badges
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(Text(hint))
            .accessibilityAddTraits(.isButton)

            Button(action: onDismiss) {
                BannerCloseMark(color: ink)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(theme.tipCloseFill))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, -6)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.vertical, 14)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.primaryButtonFill)
                .shadow(color: .black.opacity(0.5), radius: 16, y: 12)
        }
        .frame(maxWidth: 480)
        .offset(y: drag)
        // Flicked back up the way it came. Above the buttons' own taps, or a swipe that starts on
        // the stop never reaches it; a tap still opens, since a drag needs the finger to travel.
        .highPriorityGesture(DragGesture(minimumDistance: 12)
            .onChanged { value in
                let height = value.translation.height
                drag = height < 0 ? height : height / (1 + height / 40)
            }
            .onEnded { value in
                if value.translation.height < -30 || value.predictedEndTranslation.height < -80 {
                    onDismiss()
                } else {
                    withAnimation(.spring(duration: 0.3)) { drag = 0 }
                }
            })
        .onChange(of: alert.id) { drag = 0 }
        .task(id: alert.id) {
            AccessibilityNotification.Announcement("\(kicker), \(alert.stop.name)").post()
        }
        .task(id: "\(alert.id)-\(voiceOver)") {
            guard !voiceOver else { return }
            try? await Task.sleep(for: Self.autoHideAfter)
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }

    @ViewBuilder private var badges: some View {
        let shown = alert.lines.prefix(Self.shownLines)
        let hidden = alert.lines.count - shown.count
        HStack(spacing: 6) {
            ForEach(shown, id: \.id) { line in
                LineBadgeView(number: line.shortName, colorIndex: colorIndex(line),
                              side: 30, cornerRadius: 8, numeralSize: 15, ring: nil)
            }
            if hidden > 0 {
                Text("+\(hidden)")
                    .busText(TypeStyles.overflowCountPhone)
                    .foregroundStyle(theme.primaryButtonText.opacity(0.75))
                    .fixedSize()
            }
        }
        .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        let names = alert.lines.map(\.shortName).joined(separator: ", ")
        let stop = names.isEmpty ? alert.stop.name : String(appLocalized: "\(alert.stop.name), lines \(names)")
        return "\(kicker), \(stop)"
    }
}

/// The banner's ×, in the ink of the surface it sits on.
private struct BannerCloseMark: View {
    var color: Color

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 1, y: 1))
            path.addLine(to: CGPoint(x: 13, y: 13))
            path.move(to: CGPoint(x: 13, y: 1))
            path.addLine(to: CGPoint(x: 1, y: 13))
        }
        .stroke(color, style: StrokeStyle(lineWidth: Stroke.closeGlyph, lineCap: .round))
        .frame(width: 14, height: 14)
        .scaleEffect(12 / 14)
        .accessibilityHidden(true)
    }
}
#endif
