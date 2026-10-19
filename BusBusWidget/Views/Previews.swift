import SwiftUI
import WidgetKit

#if DEBUG
private extension NextBusEntry {
    static var stale: NextBusEntry {
        var entry = sample(at: .now)
        entry.liveness = .stale(asOf: .now.addingTimeInterval(-14 * 60))
        return entry
    }

    static var empty: NextBusEntry {
        NextBusEntry(date: .now, state: .noHistory, setup: nil, arrivals: [], liveness: .expired)
    }
}

#Preview("Small", as: .systemSmall) {
    NextBusWidget()
} timeline: {
    NextBusEntry.sample(at: .now)
    NextBusEntry.stale
    NextBusEntry.empty
}

#Preview("Medium", as: .systemMedium) {
    NextBusWidget()
} timeline: {
    NextBusEntry.sample(at: .now)
    NextBusEntry.empty
}

#Preview("Large", as: .systemLarge) {
    NextBusWidget()
} timeline: {
    NextBusEntry.sample(at: .now)
}

#Preview("Extra large", as: .systemExtraLarge) {
    NextBusWidget()
} timeline: {
    NextBusEntry.sample(at: .now)
}

#Preview("Extra large portrait", as: .systemExtraLargePortrait) {
    NextBusWidget()
} timeline: {
    NextBusEntry.sample(at: .now)
}

#if os(iOS)
#Preview("Lock screen", as: .accessoryRectangular) {
    NextBusWidget()
} timeline: {
    NextBusEntry.sample(at: .now)
}
#endif
#endif
