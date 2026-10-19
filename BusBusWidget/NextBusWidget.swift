import SwiftUI
import WidgetKit

/// The next buses at a stop from the rider's history — the history picker's entries, one per
/// widget, chosen by editing the widget.
struct NextBusWidget: Widget {
    static let kind = WidgetKind.nextBus

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectSavedSetupIntent.self,
                               provider: NextBusTimelineProvider()) { entry in
            NextBusWidgetView(entry: entry)
        }
        .configurationDisplayName("Next bus")
        .description("The next arrivals at one of My stops.")
        .supportedFamilies(Self.families)
    }

    static var families: [WidgetFamily] {
        // Extra large is the iPad's and the Mac's alone; the portrait one is new in 27 and comes to
        // the iPhone too. StandBy shows the small one, without its background (`WidgetEnvironment`).
        var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
                                        .systemExtraLargePortrait]
        #if os(iOS)
        families += [.accessoryCircular, .accessoryRectangular, .accessoryInline]
        #endif
        return families
    }
}
