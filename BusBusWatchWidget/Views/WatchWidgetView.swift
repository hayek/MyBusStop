import SwiftUI
import WidgetKit

/// One complication family at a time, in the app's language and appearance, opening the watch
/// app on its stop when tapped.
struct WatchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: NextBusEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: AccessoryCircularView(entry: entry)
            case .accessoryRectangular: AccessoryRectangularView(entry: entry)
            case .accessoryInline: AccessoryInlineView(entry: entry)
            case .accessoryCorner: AccessoryCornerView(entry: entry)
            @unknown default: AccessoryRectangularView(entry: entry)
            }
        }
        // Accessory families ignore the container background's colour, as on the iPhone's lock screen.
        .modifier(WidgetEnvironment(appearance: entry.appearance))
        .widgetURL(WidgetDeepLink.url(for: entry.setup))
    }
}
