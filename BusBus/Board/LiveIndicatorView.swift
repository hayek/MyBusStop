import SwiftUI

/// Says plainly whether what you are looking at is current. After 90 seconds without a successful
/// fetch it stops claiming to be live rather than quietly showing old numbers.
struct LiveIndicatorView: View {
    @Environment(\.theme) private var theme

    var state: LiveState
    var secondsSinceUpdate: TimeInterval?
    var style: TypeStyle
    var scale: CGFloat
    var showsLabel: Bool

    var body: some View {
        HStack(spacing: 10 * scale) {
            Circle()
                .fill(state == .live ? theme.liveDot : theme.stale)
                .frame(width: dotSize, height: dotSize)
            if showsLabel {
                Text(state.label)
                    .busText(style, scale: scale)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var dotSize: CGFloat { (showsLabel ? 10 : 8) * scale }

    private var label: String {
        switch state {
        case .live: return String(appLocalized: "Live data")
        case .connecting: return String(appLocalized: "Connecting")
        case .stale:
            guard let secondsSinceUpdate else { return String(appLocalized: "Data is stale") }
            // Rounded up: at 91 seconds the data is over a minute old, not one minute old.
            let minutes = max(1, Int((secondsSinceUpdate / 60).rounded(.up)))
            return String(appLocalized: "Data is stale, last updated \(minutes) minutes ago")
        }
    }
}
