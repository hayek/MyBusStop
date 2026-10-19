import SwiftUI
import WidgetKit
// The views are also compiled into BusBusTests, which checks they fit every size.
#if !BUSBUS_WIDGET
@testable import BusBus
#endif

/// The message in a system-size widget. Where a stop is known its lines stay on screen, so the
/// rider can still tell which stop the widget is watching.
struct WidgetMessageView: View {
    @Environment(\.theme) private var theme
    var entry: NextBusEntry
    var message: WidgetMessage
    var titleSize: CGFloat
    var badgeSide: CGFloat = 26
    /// Off where the lines are already on screen, as the map's termini.
    var showsBadges = true

    /// Where there is no room, the lines' badges go first; the words stay.
    var body: some View {
        ViewThatFits(in: .vertical) {
            if entry.setup != nil, showsBadges { content(showsBadges: true) }
            content(showsBadges: false)
        }
    }

    private func content(showsBadges: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsBadges, let setup = entry.setup {
                HStack(spacing: 6) {
                    ForEach(setup.lines.prefix(3), id: \.id) { line in
                        WidgetBadge(number: line.shortName, colorIndex: entry.colorIndex(for: line.id),
                                    side: badgeSide, numeralSize: badgeSide / 2)
                    }
                }
                .padding(.bottom, 2)
            }
            Text(message.title)
                .busText(TypeStyle(.archivoBlack, titleSize, tracking: -0.01))
                .foregroundStyle(theme.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(message.detail)
                .busText(TypeStyle(.spaceMonoBold, 12, tracking: 0.06))
                .foregroundStyle(theme.dashCaption)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
