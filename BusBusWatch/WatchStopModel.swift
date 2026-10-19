import Foundation
import Observation
import WidgetKit

/// One stop's board while it is on screen: the stored snapshot at once, then the watch's own
/// fetches on the provider's cadence, saved for the complications.
@MainActor @Observable final class WatchStopModel {
    enum Fetching: Hashable, Sendable { case idle, fetching, failed }

    typealias Fetch = (SavedSetup, Date) async throws -> WidgetSnapshot

    let setup: SavedSetup
    private(set) var snapshot: WidgetSnapshot?
    private(set) var fetching: Fetching = .idle
    /// Whether the watch may call this setup's provider at all (`WidgetProviderGate` via the fetcher);
    /// false for snapshot-only providers, whose numbers only ever come from the phone.
    let canFetch: Bool
    let provider: (any TransitProvider)?
    private let snapshots: WidgetSnapshotStore
    private let fetch: Fetch
    private let reloadComplications: () -> Void
    private let now: () -> Date
    private var lastComplicationReload: Date?
    private var task: Task<Void, Never>?

    init(setup: SavedSetup,
         snapshots: WidgetSnapshotStore = WidgetSnapshotStore(),
         fetcher: WidgetArrivalsFetcher = WidgetArrivalsFetcher(),
         fetch: Fetch? = nil,
         reloadComplications: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nextBus) },
         now: @escaping () -> Date = { .now }) {
        self.setup = setup
        self.snapshots = snapshots
        self.provider = fetcher.provider(for: setup)
        // A stubbed fetch (tests) always may; otherwise the gate decides.
        self.canFetch = fetch != nil || provider != nil
        self.fetch = fetch ?? { setup, date in try await fetcher.fetch(setup, now: date) }
        self.reloadComplications = reloadComplications
        self.now = now
        snapshot = snapshots.load(setupID: setup.id)
    }

    /// The picture at `date`: the timeline's first entry from the stored numbers, which gives
    /// liveness, the "ran out" rule and the arrivals list for free — built alone, as it is every second.
    func entry(at date: Date, palette: [String: Int], appearance: Appearance) -> NextBusEntry {
        let layout = WidgetLayout(arrivalsShown: WidgetLayout.readoutArrivals + WidgetLayout.largeLaterRows)
        return NextBusTimeline.entry(history: [setup], chosenID: setup.id, snapshot: snapshot, layout: layout,
                                     palette: palette, appearance: appearance, now: date)
    }

    /// What the board says under "NO LIVE DATA".
    enum ExpiredDetail: Hashable, Sendable {
        /// The watch is asking, or about to (the loop fetches old numbers on its next pass).
        case connecting
        /// It asked and could not get an answer.
        case cantReachFeed
        /// Only the iPhone can ask for this stop.
        case openOnIPhone
    }

    static func expiredDetail(canFetch: Bool, fetching: Fetching) -> ExpiredDetail {
        guard canFetch else { return .openOnIPhone }
        return fetching == .failed ? .cantReachFeed : .connecting
    }

    var expiredDetail: ExpiredDetail { Self.expiredDetail(canFetch: canFetch, fetching: fetching) }

    /// Fetches now if the stored numbers are old (`WatchRefreshPolicy.shouldFetch`), then every
    /// `WatchRefreshPolicy.pollInterval` until `stop()`. Starting again restarts the loop.
    func start() {
        task?.cancel()
        task = Task { [weak self] in
            await self?.catchUp()
            while !Task.isCancelled {
                try? await Task.sleep(for: WatchRefreshPolicy.pollInterval(for: self?.provider))
                guard !Task.isCancelled, let self else { return }
                self.readStore()
                await self.refresh()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// The first pass on appearing: whatever landed in the store meanwhile (a sync, a complication's
    /// fetch), then a request only when those numbers are old.
    func catchUp() async {
        readStore()
        guard WatchRefreshPolicy.shouldFetch(snapshot: snapshot, now: now()) else { return }
        await refresh()
    }

    /// One fetch. Failure keeps the last good numbers and sets `fetching = .failed`.
    func refresh() async {
        guard canFetch, fetching != .fetching else { return }
        fetching = .fetching
        let date = now()
        do {
            let fetched = try await fetch(setup, date)
            snapshot = fetched
            snapshots.save(fetched)
            fetching = .idle
            if WatchRefreshPolicy.shouldReloadComplications(lastReload: lastComplicationReload, now: date) {
                lastComplicationReload = date
                reloadComplications()
            }
        } catch {
            fetching = .failed
        }
    }

    /// Takes the stored snapshot when it is newer than the one on screen: the phone's, synced, is
    /// the only source for a setup the watch may not fetch.
    private func readStore() {
        guard let stored = snapshots.load(setupID: setup.id) else { return }
        if snapshot.map({ stored.fetchedAt > $0.fetchedAt }) ?? true { snapshot = stored }
    }
}

/// The boards' models, one per stop on the navigation path: made the first time its board is
/// drawn and kept while the stop stays on the path, however often the destination is rebuilt.
@MainActor final class WatchBoardModels {
    private var models: [String: WatchStopModel] = [:]
    private let make: @MainActor (SavedSetup) -> WatchStopModel

    /// `make`: how a model is built; the real stores and fetcher unless a test says otherwise.
    init(make: (@MainActor (SavedSetup) -> WatchStopModel)? = nil) {
        self.make = make ?? { WatchStopModel(setup: $0) }
    }

    func model(for setup: SavedSetup) -> WatchStopModel {
        if let model = models[setup.id] { return model }
        let model = make(setup)
        models[setup.id] = model
        return model
    }

    /// Lets go of the boards no longer on the path.
    func keep(only ids: [String]) {
        models = models.filter { ids.contains($0.key) }
    }
}
