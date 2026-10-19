import Foundation

/// When the watch app fetches for itself and when it asks WidgetKit to redraw the complications.
/// The widget's own rules, restated for a process that stays in front.
nonisolated enum WatchRefreshPolicy {
    /// Numbers newer than this are not worth a request (`NextBusTimelineProvider.refetchAfter`).
    static let refetchAfter: TimeInterval = 60
    /// Complications are redrawn at most this often while the app is in front (`WidgetBridge.reloadInterval`).
    static let reloadInterval: TimeInterval = 3 * 60

    static func shouldFetch(snapshot: WidgetSnapshot?, now: Date) -> Bool {
        guard let snapshot else { return true }
        return now.timeIntervalSince(snapshot.fetchedAt) >= refetchAfter
    }

    static func shouldReloadComplications(lastReload: Date?, now: Date) -> Bool {
        guard let lastReload else { return true }
        return now.timeIntervalSince(lastReload) >= reloadInterval
    }

    /// The provider's `refreshInterval` (20–30 s), or 30 s when the setup has no provider the watch may call.
    static func pollInterval(for provider: (any TransitProvider)?) -> Duration {
        guard let provider else { return .seconds(30) }
        return .seconds(min(max(provider.refreshInterval.components.seconds, 20), 30))
    }
}
