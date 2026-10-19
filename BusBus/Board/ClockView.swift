import SwiftUI

/// The wall clock in the header. Ticks on the minute, in the rider's own locale and hour cycle.
struct ClockView: View {
    @Environment(\.theme) private var theme
    var style: TypeStyle
    var scale: CGFloat

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(context.now, format: .dateTime.hour(.twoDigits(amPM: .abbreviated)).minute())
                .busText(style, scale: scale)
                .foregroundStyle(theme.primaryText)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityLabel("Current time")
    }
}
