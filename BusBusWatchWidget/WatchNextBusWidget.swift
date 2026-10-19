import SwiftUI
import WidgetKit

/// The next bus at a stop from the phone's history, as a complication or in the Smart Stack.
struct WatchNextBusWidget: Widget {
    static let kind = WidgetKind.nextBus

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectSavedSetupIntent.self,
                               provider: NextBusTimelineProvider()) { entry in
            WatchWidgetView(entry: entry)
        }
        .configurationDisplayName("Next bus")
        .description("The next arrivals at one of My stops.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
