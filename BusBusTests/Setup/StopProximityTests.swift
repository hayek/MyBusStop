import Testing
import Foundation
@testable import BusBus

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func line(_ id: String) -> TransitLine {
    TransitLine(id: id, shortName: id, headsign: nil, agency: nil, origin: nil, destination: nil,
                isAccessible: nil, brandColorIndex: nil)
}

/// A point `meters` north of `point`.
private func north(of point: GeoPoint, _ meters: Double) -> GeoPoint {
    GeoPoint(lat: point.lat + meters / 111_195, lon: point.lon)
}

/// Two stops across the street from each other, 30 m apart, and a feed that can be made to fail.
private nonisolated final class FacingStopsProvider: TransitProvider, @unchecked Sendable {
    let id = "facing"
    let displayName = "Facing"
    let capabilities: ProviderCapabilities = [.nearbyStops, .linesAtStop]
    let suggestedRefreshInterval: Duration = .seconds(20)
    static let origin = GeoPoint(lat: 42.35, lon: -71.07)
    let stops = [TransitStop(code: "A", name: "A", city: nil, location: origin),
                 TransitStop(code: "B", name: "B", city: nil, location: north(of: origin, 30))]
    var fails = false

    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        if fails { throw TransitError.unsupported("down") }
        return stops.map { NearbyStop(stop: $0, distanceMeters: point.distance(to: $0.location), lines: [line("1")]) }
    }

    func searchStops(query: String) async throws -> [TransitStop] { stops }
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] { [line("1")] }
    func routePattern(for line: TransitLine) async throws -> RoutePattern { throw TransitError.unsupported("") }
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] { [] }
}

struct StopProximityTests {
    private let here = GeoPoint(lat: 32.0853, lon: 34.7818)

    private func nearby(_ code: String, metersNorth: Double) -> NearbyStop {
        NearbyStop(stop: TransitStop(code: code, name: code, city: nil, location: north(of: here, metersNorth)),
                   distanceMeters: 0, lines: [])
    }

    @Test func theClosestStopWithinReachIsTheOneTheRiderIsAt() {
        let stops = [nearby("far", metersNorth: 120), nearby("near", metersNorth: 12), nearby("next", metersNorth: 30)]
        #expect(StopProximity.stop(at: here, among: stops)?.stop.code == "near")
    }

    @Test func aStopOutOfReachIsNotOffered() {
        #expect(StopProximity.stop(at: here, among: [nearby("far", metersNorth: 60)]) == nil)
    }

    @Test func onlyAMuchSurerFixIsSharper() {
        #expect(StopProximity.isSharper(30, than: 45))
        #expect(!StopProximity.isSharper(40, than: 45))
        #expect(StopProximity.isSharper(30, than: nil))
        #expect(!StopProximity.isSharper(nil, than: 45))
    }

    @Test func theMostRecentBoardAtTheStopIsTheRiders() {
        let stop = TransitStop(code: "7", name: "SEVEN", city: nil, location: here)
        let other = TransitStop(code: "8", name: "EIGHT", city: nil, location: here)
        let history = [
            SavedSetup(stop: stop, lines: [line("1")], lastUsedAt: start, providerID: "bus.gov.il"),
            SavedSetup(stop: stop, lines: [line("2"), line("3")], lastUsedAt: start.addingTimeInterval(60),
                       providerID: "bus.gov.il"),
            SavedSetup(stop: other, lines: [line("4")], lastUsedAt: start.addingTimeInterval(120),
                       providerID: "bus.gov.il"),
        ]
        let saved = StopProximity.savedSetup(at: stop, providerID: "bus.gov.il", in: history)
        #expect(saved?.lineIDs == ["2", "3"])
    }

    @Test func aBoardFromAnotherProvidersStopOfTheSameCodeIsNotIt() {
        let stop = TransitStop(code: "7", name: "SEVEN", city: nil, location: here)
        let history = [SavedSetup(stop: stop, lines: [line("1")], lastUsedAt: start, providerID: "mbta")]
        #expect(StopProximity.savedSetup(at: stop, providerID: "bus.gov.il", in: history) == nil)
        // Saved before providers were recorded: taken to be the stop's own.
        let legacy = [SavedSetup(stop: stop, lines: [line("1")], lastUsedAt: start)]
        #expect(StopProximity.savedSetup(at: stop, providerID: "bus.gov.il", in: legacy) != nil)
    }
}

@Suite(.appLanguage("en"))
@MainActor
struct StopProximityWatcherTests {
    private func makeWatcher() -> (StopProximityWatcher, SettingsStore) {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "proximity-\(UUID().uuidString)")!)
        settings.providerOverride = MockTransitProvider()
        let cache = TransitCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("proximity-\(UUID().uuidString)"))
        return (StopProximityWatcher(settings: settings, cache: cache), settings)
    }

    private func makeWatcher(_ provider: FacingStopsProvider) -> StopProximityWatcher {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "proximity-\(UUID().uuidString)")!)
        settings.providerOverride = provider
        // A cold cache of its own each time, so a failure is never answered from an earlier list.
        let cache = TransitCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("proximity-\(UUID().uuidString)"))
        return StopProximityWatcher(settings: settings, cache: cache)
    }

    private func someStop(_ settings: SettingsStore) async -> TransitStop {
        try! await settings.provider.searchStops(query: MapFixtures.user).first!
    }

    @Test func aStopNeverSetUpOffersEveryLineThroughIt() async throws {
        let (watcher, settings) = makeWatcher()
        let stop = await someStop(settings)
        await watcher.look(at: stop.location)
        let alert = try #require(watcher.alert)
        #expect(alert.stop.code == stop.code)
        #expect(alert.saved == nil)
        let all = try await settings.provider.lines(atStop: stop)
        #expect(Set(alert.lines.map(\.id)) == Set(all.map(\.id)))
    }

    @Test func aStopSetUpBeforeOffersOnlyTheLinesChosenThere() async throws {
        let (watcher, settings) = makeWatcher()
        let stop = await someStop(settings)
        let chosen = Array(try await settings.provider.lines(atStop: stop).prefix(1))
        settings.savedSetups = [SavedSetup(stop: stop, lines: chosen, providerID: "mock")]
        await watcher.look(at: stop.location)
        let alert = try #require(watcher.alert)
        #expect(alert.saved != nil)
        #expect(alert.lines.map(\.id) == chosen.map(\.id))
    }

    @Test func theStopOnTheBoardIsNotOffered() async throws {
        let (watcher, settings) = makeWatcher()
        let stop = await someStop(settings)
        settings.configuration = BoardConfiguration(providerID: "mock", stop: stop,
                                                    lines: try await settings.provider.lines(atStop: stop))
        await watcher.look(at: stop.location)
        #expect(watcher.alert == nil)
    }

    @Test func aDismissedStopComesBackOnlyAfterTheRiderLeavesIt() async throws {
        let (watcher, settings) = makeWatcher()
        let stop = await someStop(settings)
        await watcher.look(at: stop.location)
        watcher.dismiss()
        // Pacing about at the stop.
        await watcher.look(at: north(of: stop.location, 25))
        await watcher.look(at: stop.location)
        #expect(watcher.alert == nil)
        // Away, and back.
        await watcher.look(at: north(of: stop.location, 2_000))
        await watcher.look(at: stop.location)
        #expect(watcher.alert?.stop.code == stop.code)
    }

    /// The fix wandering between two facing stops offers each once, not each again by turns.
    @Test func facingStopsAreNotOfferedByTurns() async {
        let provider = FacingStopsProvider()
        let watcher = makeWatcher(provider)
        let atA = north(of: FacingStopsProvider.origin, -5), atB = north(of: FacingStopsProvider.origin, 35)
        await watcher.look(at: atA)
        #expect(watcher.alert?.stop.code == "A")
        watcher.dismiss()
        await watcher.look(at: atB)
        #expect(watcher.alert?.stop.code == "B")
        watcher.dismiss()
        await watcher.look(at: atA)
        await watcher.look(at: atB)
        #expect(watcher.alert == nil)
    }

    /// The first fix put the rider just out of the stop's reach; a surer one from a few metres
    /// away puts them in it, and is looked at although they have barely moved.
    @Test func aSharperFixFromTheSameSpotIsLookedAt() async {
        let watcher = makeWatcher(FacingStopsProvider())
        await watcher.look(at: north(of: FacingStopsProvider.origin, -45), uncertainty: 48)
        #expect(watcher.alert == nil)
        // No surer: still nothing new.
        await watcher.look(at: north(of: FacingStopsProvider.origin, -30), uncertainty: 45)
        #expect(watcher.alert == nil)
        await watcher.look(at: north(of: FacingStopsProvider.origin, -30), uncertainty: 12)
        #expect(watcher.alert?.stop.code == "A")
    }

    /// A pull to refresh looks again without a move, but a stop put away stays put away.
    @Test func aForcedLookNeedsNoMoveButKeepsADismissal() async {
        let watcher = makeWatcher(FacingStopsProvider())
        await watcher.look(at: north(of: FacingStopsProvider.origin, -45))
        await watcher.look(at: north(of: FacingStopsProvider.origin, -30))
        #expect(watcher.alert == nil)
        await watcher.look(at: north(of: FacingStopsProvider.origin, -30), force: true)
        #expect(watcher.alert?.stop.code == "A")
        watcher.dismiss()
        await watcher.look(at: north(of: FacingStopsProvider.origin, -30), force: true)
        #expect(watcher.alert == nil)
    }

    /// A feed that fails while the rider stands still is asked again on the next fix.
    @Test func aFailedLookIsTriedAgainFromTheSameSpot() async {
        let provider = FacingStopsProvider()
        provider.fails = true
        let watcher = makeWatcher(provider)
        await watcher.look(at: FacingStopsProvider.origin)
        #expect(watcher.alert == nil)
        provider.fails = false
        await watcher.look(at: north(of: FacingStopsProvider.origin, 2))
        #expect(watcher.alert?.stop.code == "A")
    }
}

@MainActor
struct ProviderAtPointTests {
    private let boston = GeoPoint(lat: 42.3298, lon: -71.0839)
    private let haifa = GeoPoint(lat: 32.8166, lon: 34.9895)

    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "at-point-\(UUID().uuidString)")!)
    }

    @Test func itNamesTheProviderWithoutSwitchingSetup() {
        let store = makeStore()
        store.providerID = "mbta"
        #expect(store.providerID(at: haifa) == "bus.gov.il")
        #expect(store.providerID == "mbta")
    }

    /// A provider chosen in Settings is the only one offered, and only where it covers.
    @Test func manualModeOffersOnlyTheChosenProvider() {
        let store = makeStore()
        store.providerIsAutomatic = false
        store.providerID = "mbta"
        #expect(store.providerID(at: boston) == "mbta")
        #expect(store.providerID(at: haifa) == nil)
    }
}
