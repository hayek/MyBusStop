import SwiftUI

/// The way into in-app feedback, at the top of the stop picker beside the gear, drawn the way the
/// gear is (`SettingsGearButton`): a bare glyph, not a chip.
struct FeedbackBubbleButton: View {
    var size: CGFloat
    var weight: Font.Weight
    var color: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bubble.left")
                .font(.system(size: size, weight: weight))
                .foregroundStyle(color)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send Feedback")
    }
}
