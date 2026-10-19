import Foundation
import Testing
@testable import BusBus

/// Calls every shipping provider's real API. Kept out of the BusBus scheme so the unit tests stay
/// offline; run with the BusBusLiveAPI scheme (or scripts/live-api-tests.sh) before a release and
/// whenever a region looks broken. A failure here means that region should not be on sale.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct LiveAPITests {
    @Test("Stop search finds the fixture stop", arguments: LiveFixtures.runnable)
    func stopSearch(_ f: LiveFixture) async throws {
        _ = try await LiveProbe.stop(f)
    }

    @Test("Lines are listed at the stop", arguments: LiveFixtures.runnable)
    func linesAtStop(_ f: LiveFixture) async throws {
        _ = try await LiveProbe.lines(f)
    }

    @Test("A line's pattern is ordered and passes the stop", arguments: LiveFixtures.runnable)
    func routePattern(_ f: LiveFixture) async throws {
        _ = try await LiveProbe.pattern(f)
    }

    @Test("Live vehicles are on the route", arguments: LiveFixtures.runnable.filter { $0.provider.capabilities.contains(.vehiclePositions) })
    func vehicles(_ f: LiveFixture) async throws {
        _ = try await LiveProbe.vehicles(f)
    }

    @Test("Arrivals are upcoming and soonest-first", arguments: LiveFixtures.runnable.filter {
        !$0.provider.capabilities.isDisjoint(with: [.realtimeArrivals, .scheduledArrivals])
    })
    func arrivals(_ f: LiveFixture) async throws {
        _ = try await LiveProbe.arrivals(f)
    }

    /// Skipped, rather than failed, when a keyed provider has no key here, so the gap is visible.
    @Test("Keyed providers have their API keys",
          .enabled("an API key is missing; see scripts/api-keys.sh") { LiveFixtures.missingKeys.isEmpty })
    func keyedProvidersHaveKeys() {
        #expect(LiveFixtures.missingKeys.isEmpty)
    }

    @Test("A line's shape follows its stops", arguments: LiveFixtures.runnable.filter { $0.provider.capabilities.contains(.routeShape) })
    func routeShape(_ f: LiveFixture) async throws {
        _ = try await LiveProbe.shape(f)
    }

    @Test("Nearby stops are near", arguments: LiveFixtures.runnable.filter { $0.provider.capabilities.contains(.nearbyStops) })
    func nearby(_ f: LiveFixture) async throws {
        _ = try await LiveProbe.nearby(f)
    }
}

/// The supported-regions list and the live fixtures must not drift apart: every region's provider
/// is live-checked, and every checked provider is one the app actually offers.
struct SupportedRegionCoverageTests {
    @Test func everySupportedRegionHasALiveCheck() {
        let checked = Set(LiveFixtures.all.map(\.provider.id))
        for region in SupportedRegions.all {
            #expect(checked.contains(region.providerID), "\(region.id) (\(region.providerID)) has no LiveFixture")
        }
    }

    @Test func everyRegionProviderIsRegistered() {
        let registered = Set(TransitProviders.all.map(\.id))
        for region in SupportedRegions.all {
            #expect(registered.contains(region.providerID), "\(region.id) points at unregistered \(region.providerID)")
        }
    }

    @Test func everyFullRegionHasVehiclePositions() {
        for region in SupportedRegions.all where region.fit == .full {
            let provider = TransitProviders.provider(id: region.providerID)
            #expect(provider.capabilities.contains(.vehiclePositions), "\(region.id) is .full but \(provider.id) has no vehicles")
        }
    }
}
