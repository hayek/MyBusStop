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

#Preview("Circular", as: .accessoryCircular) {
    WatchNextBusWidget()
} timeline: {
    NextBusEntry.sample(at: .now)
    NextBusEntry.stale
    NextBusEntry.empty
}

#Preview("Rectangular", as: .accessoryRectangular) {
    WatchNextBusWidget()
} timeline: {
    NextBusEntry.sample(at: .now)
    NextBusEntry.stale
    NextBusEntry.empty
}

#Preview("Inline", as: .accessoryInline) {
    WatchNextBusWidget()
} timeline: {
    NextBusEntry.sample(at: .now)
    NextBusEntry.empty
}

#Preview("Corner", as: .accessoryCorner) {
    WatchNextBusWidget()
} timeline: {
    NextBusEntry.sample(at: .now)
    NextBusEntry.stale
    NextBusEntry.empty
}
#endif
