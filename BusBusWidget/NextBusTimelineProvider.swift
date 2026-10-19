import SwiftUI
import WidgetKit

extension NextBusEntry: TimelineEntry {
    #if os(watchOS)
    /// Smart Stack: surface the stop as its next bus draws near (`NextBusEntry.relevanceScore`).
    var relevance: TimelineEntryRelevance? {
        relevanceScore.map { TimelineEntryRelevance(score: $0) }
    }
    #endif
}

/// Builds the widget's timeline from the shared history and the snapshots, fetching for itself
/// when the app has not refreshed the stop lately. The pictures themselves are `NextBusTimeline`'s.
nonisolated struct NextBusTimelineProvider: AppIntentTimelineProvider {
    /// Numbers newer than this are not worth a request.
    static let refetchAfter: TimeInterval = 60

    var history = SharedHistoryStore()
    var snapshots = WidgetSnapshotStore()
    var routes = WidgetRouteStore()
    var fetcher = WidgetArrivalsFetcher()

    func placeholder(in context: Context) -> NextBusEntry { .sample(at: .now) }

    #if os(watchOS)
    /// A watch complication is not edited in an intent editor: the watch face lists these instead,
    /// one per stop of the history, in the picker's order. Before the first sync there is still one,
    /// unconfigured, so the complication can go on a face now and follow the top of the history
    /// once it arrives (`HistoryLookup.resolve` with no id).
    func recommendations() -> [AppIntentRecommendation<SelectSavedSetupIntent>] {
        let saved = history.load()
        guard !saved.isEmpty else {
            return [AppIntentRecommendation(intent: SelectSavedSetupIntent(), description: String(appLocalized: "Next bus"))]
        }
        return HistoryLookup.sorted(saved).map { setup in
            let intent = SelectSavedSetupIntent()
            intent.setup = SavedSetupEntity(setup)
            return AppIntentRecommendation(intent: intent, description: setup.stop.name)
        }
    }
    #endif

    func snapshot(for configuration: SelectSavedSetupIntent, in context: Context) async -> NextBusEntry {
        let now = Date.now
        let saved = history.load()
        let snapshot = storedSnapshot(for: configuration, history: saved)
        // The gallery shows what the widget looks like, not an empty history or a stop with no
        // numbers yet.
        if context.isPreview {
            let usable = snapshot.map { WidgetTimelineMath.liveness(fetchedAt: $0.fetchedAt, now: now) != .expired } ?? false
            if !usable { return .sample(at: now) }
        }
        return entries(for: configuration, family: context.family, history: saved,
                       snapshot: snapshot, now: now).first ?? .sample(at: now)
    }

    func timeline(for configuration: SelectSavedSetupIntent, in context: Context) async -> Timeline<NextBusEntry> {
        let now = Date.now
        let saved = history.load()
        var snapshot = storedSnapshot(for: configuration, history: saved)
        if case .setup(let setup) = HistoryLookup.resolve(id: configuration.setup?.id, in: saved) {
            let isRecent = snapshot.map { now.timeIntervalSince($0.fetchedAt) < Self.refetchAfter } ?? false
            if !isRecent, fetcher.canFetch(setup), let fetched = try? await fetcher.fetch(setup, now: now) {
                snapshots.save(fetched)
                snapshot = fetched
            }
        }
        let entries = entries(for: configuration, family: context.family, history: saved,
                              snapshot: snapshot, now: now)
        let reload: Date
        if let snapshot {
            reload = WidgetTimelineMath.reloadDate(for: snapshot.upcoming(at: now), now: now)
        } else {
            // Nothing to count down: look again in a while, or when the app says the history changed.
            reload = now.addingTimeInterval(saved.isEmpty ? 60 * 60 : 15 * 60)
        }
        return Timeline(entries: entries, policy: .after(reload))
    }

    /// The last numbers saved for the entry the widget shows, if it shows one.
    private func storedSnapshot(for configuration: SelectSavedSetupIntent, history saved: [SavedSetup]) -> WidgetSnapshot? {
        guard case .setup(let setup) = HistoryLookup.resolve(id: configuration.setup?.id, in: saved) else { return nil }
        return snapshots.load(setupID: setup.id)
    }

    private func entries(for configuration: SelectSavedSetupIntent, family: WidgetFamily,
                         history saved: [SavedSetup], snapshot: WidgetSnapshot?, now: Date) -> [NextBusEntry] {
        let chosen: SavedSetup? = if case .setup(let setup) = HistoryLookup.resolve(id: configuration.setup?.id, in: saved) {
            setup
        } else {
            nil
        }
        #if os(watchOS)
        // No complication draws the map, and the watch's intent has no content to choose.
        let routes: WidgetRoutes? = nil
        let layout = WidgetLayout.for(family, content: .laterBuses, hasMap: false)
        #else
        let large = [.systemLarge, .systemExtraLarge, .systemExtraLargePortrait].contains(family)
        // Only the large sizes draw the map, and only they read its routes.
        let routes = large && configuration.largeContent == .map ? chosen.flatMap { self.routes.load(setupID: $0.id) } : nil
        let layout = WidgetLayout.for(family, content: configuration.largeContent,
                                      hasMap: chosen.map { WidgetMap.canDraw($0, routes: routes) } ?? false)
        #endif
        return NextBusTimeline.entries(history: saved, chosenID: configuration.setup?.id, snapshot: snapshot,
                                       routes: routes, layout: layout, palette: history.paletteAssignments(),
                                       appearance: history.appearance(), now: now)
    }
}
