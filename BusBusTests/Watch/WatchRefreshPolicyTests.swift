import Testing
import Foundation
@testable import BusBus

/// When the watch app asks for numbers of its own, and when it redraws the complications.
struct WatchRefreshPolicyTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func snapshot(age: TimeInterval) -> WidgetSnapshot {
        WidgetSnapshot(setupID: "1|18", fetchedAt: now.addingTimeInterval(-age), arrivals: [])
    }

    @Test func fetchesOnlyWhenTheNumbersAreOld() {
        #expect(WatchRefreshPolicy.shouldFetch(snapshot: nil, now: now))
        #expect(!WatchRefreshPolicy.shouldFetch(snapshot: snapshot(age: 30), now: now))
        #expect(WatchRefreshPolicy.shouldFetch(snapshot: snapshot(age: 61), now: now))
    }

    @Test func reloadsComplicationsAtMostEveryThreeMinutes() {
        #expect(WatchRefreshPolicy.shouldReloadComplications(lastReload: nil, now: now))
        #expect(!WatchRefreshPolicy.shouldReloadComplications(lastReload: now.addingTimeInterval(-120), now: now))
        #expect(WatchRefreshPolicy.shouldReloadComplications(lastReload: now.addingTimeInterval(-180), now: now))
    }

    @Test func pollsInsideTheBoardsBand() {
        #expect(WatchRefreshPolicy.pollInterval(for: nil) == .seconds(30))
        #expect(WatchRefreshPolicy.pollInterval(for: StubProvider(suggested: .seconds(5))) == .seconds(20))
        #expect(WatchRefreshPolicy.pollInterval(for: StubProvider(suggested: .seconds(25))) == .seconds(25))
        #expect(WatchRefreshPolicy.pollInterval(for: StubProvider(suggested: .seconds(90))) == .seconds(30))
        // A provider overriding the band (a source that costs nothing to ask) is still held to it.
        #expect(WatchRefreshPolicy.pollInterval(for: StubProvider(suggested: .seconds(5), band: false)) == .seconds(20))
    }
}

private nonisolated struct StubProvider: TransitProvider {
    let id = "stub"
    let displayName = "Stub"
    let capabilities: ProviderCapabilities = [.realtimeArrivals]
    var suggested: Duration
    var band = true

    init(suggested: Duration, band: Bool = true) {
        self.suggested = suggested
        self.band = band
    }

    var suggestedRefreshInterval: Duration { suggested }
    var refreshInterval: Duration { band ? .seconds(min(max(suggested.components.seconds, 20), 30)) : suggested }

    func searchStops(query: String) async throws -> [TransitStop] { [] }
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] { [] }
    func routePattern(for line: TransitLine) async throws -> RoutePattern { throw TransitError.unsupported("pattern") }
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] { [] }
}
