import Testing
import Foundation
@testable import BusBus

/// Nearby stops are looked up around where the rider stands, so the cache keeps them in memory
/// only: the welcome story promises that location is never stored.
struct TransitCachePrivacyTests {

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("privacy-cache-\(UUID().uuidString)")
    }

    private static func files(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    @Test func nearbyStopsNeverReachTheDisk() async throws {
        let directory = Self.temporaryDirectory()
        let cache = TransitCache(directory: directory)
        let mock = MockTransitProvider()
        let here = GeoPoint(lat: 32.900, lon: 34.950)
        let found = try await cache.nearby(around: here, radiusMeters: 500, providerID: mock.datasetID) {
            try await mock.stopsNearby(here, radiusMeters: 500)
        }
        #expect(!Self.files(in: directory).contains { $0.hasPrefix("nearby") })

        // Still answered from memory the second time.
        let again = try await cache.nearby(around: here, radiusMeters: 500, providerID: mock.datasetID) {
            throw TransitError.badResponse("should not be asked")
        }
        #expect(again.map(\.id) == found.map(\.id))
    }

    @Test func routesAreStillKeptOnDisk() async throws {
        let directory = Self.temporaryDirectory()
        let cache = TransitCache(directory: directory)
        let mock = MockTransitProvider()
        let stop = try #require(await mock.searchStops(query: MapFixtures.user).first)
        let line = try #require(await mock.lines(atStop: stop).first)
        _ = try await cache.pattern(for: line, providerID: mock.datasetID) { try await mock.routePattern(for: line) }
        #expect(Self.files(in: directory).contains { $0.hasPrefix("pattern") })
    }

    @Test func purgingRemovesOnlyStoredNearbyLists() async throws {
        let directory = Self.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("nearby_mock_32.900%2C34.950_500.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("pattern_mock_41.json"))

        await TransitCache(directory: directory).purgeStoredNearby()
        #expect(Self.files(in: directory) == ["pattern_mock_41.json"])
    }
}
