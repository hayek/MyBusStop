import Foundation

/// Asks a saved setup's provider for its arrivals directly, for when the app has not refreshed
/// that stop lately. Only the one call a widget needs: no route, no vehicles.
nonisolated struct WidgetArrivalsFetcher: Sendable {
    /// A widget gets a few seconds of work, not a board's patience.
    var timeout: Duration = .seconds(10)
    /// The remote switches as the app last mirrored them.
    var history = SharedHistoryStore()

    /// Whether the widget may fetch for this setup at all.
    func canFetch(_ setup: SavedSetup) -> Bool { provider(for: setup) != nil }

    func provider(for setup: SavedSetup) -> (any TransitProvider)? {
        WidgetProviderGate.provider(for: setup, disabled: history.disabledProviders())
    }

    /// Every line's arrivals at the stop, soonest first. Lines that fail or run out of time are
    /// left out; with none at all it throws.
    func fetch(_ setup: SavedSetup, now: Date = .now) async throws -> WidgetSnapshot {
        guard let provider = provider(for: setup) else {
            throw TransitError.unsupported("widget fetch for \(setup.providerID ?? WidgetProviderGate.legacyProviderID)")
        }
        enum Outcome: Sendable { case line([WidgetArrival]?), timedOut }
        let stop = setup.stop, timeout = timeout
        var collected: [WidgetArrival] = []
        var answered = 0, succeeded = 0

        await withTaskGroup(of: Outcome.self) { group in
            for line in setup.lines {
                group.addTask {
                    let arrivals = try? await provider.arrivals(for: line, at: stop)
                    return .line(arrivals?.map {
                        WidgetArrival(lineID: line.id, expectedAt: $0.expectedAt, isRealtime: $0.isRealtime, stopsAway: nil)
                    })
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            for await outcome in group {
                guard case .line(let arrivals) = outcome else { break }
                answered += 1
                if let arrivals {
                    succeeded += 1
                    collected += arrivals
                }
                if answered == setup.lines.count { break }
            }
            group.cancelAll()
        }

        // A line that answered with no buses is an answer; one that failed or timed out is not.
        guard succeeded > 0 else { throw TransitError.badResponse("no line answered in time") }
        return WidgetSnapshot(setupID: setup.id, fetchedAt: now,
                              arrivals: collected.sorted { $0.expectedAt < $1.expectedAt })
    }
}
