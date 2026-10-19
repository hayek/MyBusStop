import SwiftUI

/// A stop on the map: the app's own mark rather than the system balloon, set larger and ringed
/// when it is the one picked out.
///
/// A search result carries its place in the list instead of the bus, so the rider can match the
/// pin to its row at a glance.
struct StopPin: View {
    @Environment(\.theme) private var theme
    var name: String
    /// The result's number in the list beside the map; nil draws the bus.
    var number: Int? = nil
    var isFocused: Bool
    /// A soft glow under the pin, for the stop the confirm step is asking about: it stays the
    /// thing to look at with every other pin faded round it.
    var showsHalo = false
    var scale: CGFloat
    var action: () -> Void

    var body: some View {
        let side = (isFocused ? 32 : 24) * scale
        let mark = RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
        Button(action: action) {
            glyph(side: side)
                .foregroundStyle(theme.primaryButtonText)
                .frame(width: side, height: side)
                .background(mark.fill(theme.primaryButtonFill))
                .overlay(mark.strokeBorder(theme.background, lineWidth: 2 * scale))
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: side * 0.3 + 5 * scale, style: .continuous)
                            .strokeBorder(theme.primaryButtonFill, lineWidth: Stroke.focusRing * scale)
                            .padding(-5 * scale)
                    }
                }
                .shadow(color: .black.opacity(0.2), radius: 3 * scale, y: 1 * scale)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Laid out rather than drawn as a background: the map clips a pin to its frame, and the
        // glow reaches past the button. It takes no taps, so the button's target stays its own.
        .background {
            if showsHalo {
                Circle()
                    .fill(RadialGradient(colors: [theme.primaryButtonFill.opacity(0.5), theme.primaryButtonFill.opacity(0)],
                                         center: .center, startRadius: side * 0.4, endRadius: side * 1.6))
                    .frame(width: side * 3.2, height: side * 3.2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(width: showsHalo ? side * 3.2 : nil, height: showsHalo ? side * 3.2 : nil)
        .animation(.snappy(duration: 0.2), value: isFocused)
        .animation(.easeOut(duration: 0.3), value: showsHalo)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    @ViewBuilder private func glyph(side: CGFloat) -> some View {
        if let number {
            Text(number, format: .number)
                .busText(TypeStyles.badgeNumeral(side * 0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, side * 0.1)
        } else {
            Image(systemName: "bus.fill")
                .font(.system(size: side * 0.5, weight: .bold))
        }
    }

    /// The number is said as well as drawn, so a VoiceOver rider can find the same stop in the list.
    private var accessibilityLabel: String {
        guard let number else { return name }
        return "\(String(appLocalized: "Stop \(number)")), \(name)"
    }
}
