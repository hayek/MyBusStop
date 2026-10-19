import SwiftUI

/// Where the board's stop name is, for the tip that points at it.
struct StopTitleAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The one tip, once, on the first board after the welcome story: the stop is saved, its name
/// changes its lines, and the back arrow before the name changes the stop. Drawn on the inverted
/// surface so it reads as a note laid on the board, not part of it — white on the dark board, ink
/// on the cream one — with its pointer at that arrow.
struct SetupTipView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    var stopName: String
    /// A phone in portrait: the tip spans the screen. Wider boards cap it.
    var compact: Bool
    var scale: CGFloat
    var onDismiss: () -> Void

    private static let radius: CGFloat = 18
    private static let arrowSide: CGFloat = 16
    /// The arrow's leading edge, from the card's.
    private static let arrowInset: CGFloat = 44
    /// A board on a wall has nobody to tap it away, so it goes by itself — except under VoiceOver,
    /// whose rider needs the time to find it and hear it out.
    static let autoHideAfter: Duration = .seconds(12)
    /// Long enough for the push onto the board to settle, so VoiceOver's own reading of the new
    /// screen does not talk over the announcement.
    private static let announceAfter: Duration = .milliseconds(800)

    private var title: String { String(appLocalized: "\(stopName) is saved.") }
    private var message: String { String(appLocalized: "Tap the stop name any time to change its lines, or the back arrow to change the stop.") }

    var body: some View {
        let ink = theme.primaryButtonText
        HStack(alignment: .top, spacing: 12) {
            checkDisc
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .busText(TypeStyles.tipTitle)
                    .foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .busText(TypeStyles.tipBody)
                    .foregroundStyle(ink.opacity(0.75))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button(action: onDismiss) {
                CloseMark(color: ink)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(theme.tipCloseFill))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, -6)
            .padding(.trailing, -6)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.top, 14)
        .padding(.bottom, 14)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .background {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .fill(theme.primaryButtonFill)
                .shadow(color: .black.opacity(0.5), radius: 16, y: 12)
        }
        // The arrow at the stop name. Leading, so it follows the name to the right in Hebrew and
        // Arabic.
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(theme.primaryButtonFill)
                .frame(width: Self.arrowSide, height: Self.arrowSide)
                .rotationEffect(.degrees(45))
                .offset(x: Self.arrowInset, y: -Self.arrowSide / 2)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: compact ? 366 * max(scale, 1) : 420, alignment: .leading)
        .task {
            try? await Task.sleep(for: Self.announceAfter)
            guard !Task.isCancelled else { return }
            AccessibilityNotification.Announcement("\(title) \(message)").post()
        }
        .task(id: voiceOver) {
            guard !voiceOver else { return }
            try? await Task.sleep(for: Self.autoHideAfter)
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }

    private var checkDisc: some View {
        Path { path in
            path.move(to: CGPoint(x: 1.5, y: 6))
            path.addLine(to: CGPoint(x: 5.5, y: 10))
            path.addLine(to: CGPoint(x: 13.5, y: 1.5))
        }
        .stroke(theme.primaryButtonFill, style: StrokeStyle(lineWidth: Stroke.check, lineCap: .round, lineJoin: .round))
        .frame(width: 15, height: 12)
        .scaleEffect(14 / 15)
        .frame(width: 28, height: 28)
        .background(Circle().fill(theme.primaryButtonText))
        // A tick reads the same way in every language; a shape would otherwise mirror.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}

/// The tip's ×, in the ink of the surface it sits on.
private struct CloseMark: View {
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
