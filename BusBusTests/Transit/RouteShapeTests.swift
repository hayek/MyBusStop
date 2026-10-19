import Testing
import Foundation
@testable import BusBus

struct PolylineTests {
    @Test func googlePolylineDecodesGooglesOwnExample() throws {
        let points = try Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        #expect(points == [GeoPoint(lat: 38.5, lon: -120.2), GeoPoint(lat: 40.7, lon: -120.95),
                           GeoPoint(lat: 43.252, lon: -126.453)])
    }

    @Test func googlePolylineRoundTripsAtEitherPrecision() throws {
        let points = [GeoPoint(lat: 32.766142, lon: 35.039336), GeoPoint(lat: 32.766206, lon: 35.039362),
                      GeoPoint(lat: -33.8688, lon: 151.2093)]
        for precision in [5, 6] {
            let decoded = try Polyline.decode(Polyline.encode(points, precision: precision), precision: precision)
            let tolerance = precision == 5 ? 1e-5 : 1e-6
            for (a, b) in zip(points, decoded) {
                #expect(abs(a.lat - b.lat) <= tolerance && abs(a.lon - b.lon) <= tolerance)
            }
        }
    }

    @Test func aTruncatedGooglePolylineThrows() {
        #expect(throws: Polyline.DecodingError.self) { try Polyline.decode("_p~iF~ps|U_") }
    }

    /// A value longer than any real coordinate is garbage from the network, not a crash.
    @Test func anOverlongGooglePolylineValueThrows() {
        #expect(throws: Polyline.DecodingError.self) { try Polyline.decode(String(repeating: "~", count: 40) + "?") }
    }

    @Test func flexiblePolylineDecodesHEREsOwnExample() throws {
        let points = try Polyline.decodeFlexible("BFoz5xJ67i1B1B7PzIhaxL7Y")
        #expect(points == [GeoPoint(lat: 50.10228, lon: 8.69821), GeoPoint(lat: 50.10201, lon: 8.69567),
                           GeoPoint(lat: 50.10063, lon: 8.6915), GeoPoint(lat: 50.09878, lon: 8.68752)])
    }

    /// The start of bus.gov.il's line 112 (route 13389): its header claims precision 15.
    @Test func flexiblePolylineReadsBusGovILsPrecision15() throws {
        let points = try Polyline.decodeFlexible("Bv8Bog2nyuvoxm6Bggooun5l4n-Bw__p2m3D4_hi3twBggi0mvkUggji0u7H")
        let expected = [GeoPoint(lat: 32.766142, lon: 35.039336), GeoPoint(lat: 32.766206, lon: 35.039362),
                        GeoPoint(lat: 32.766552, lon: 35.039497)]
        #expect(points.count == expected.count)
        for (a, b) in zip(points, expected) { #expect(abs(a.lat - b.lat) < 1e-9 && abs(a.lon - b.lon) < 1e-9) }
    }
}

struct RouteShapeTests {
    @Test func aShapeIsStoredAsPolylinesAndReadBack() throws {
        let shape = RouteShape(branches: [[GeoPoint(lat: 32.1, lon: 34.8), GeoPoint(lat: 32.2, lon: 34.9)]],
                               stopPositions: ["1": GeoPoint(lat: 32.1, lon: 34.8)], version: "v1")
        let data = try JSONEncoder().encode(shape)
        #expect(String(decoding: data, as: UTF8.self).contains("\"branches\":[\""))
        #expect(try JSONDecoder().decode(RouteShape.self, from: data) == shape)
    }

    @Test func singlePointBranchesAreDropped() {
        #expect(RouteShape(branches: [[GeoPoint(lat: 1, lon: 1)]]).isEmpty)
    }

    /// The offline shape files are named by this hash; docs/research/route-shapes/offline.md
    /// computes it as sha1(",".join(codes))[:16].
    @Test func theFingerprintMatchesTheOfflinePipelineAndIgnoresRepeatedStops() {
        let codes = ["41122", "41123", "41123", "41130"]
        let pattern = RoutePattern(line: TransitLine(id: "1", shortName: "1"), stops: codes.enumerated().map {
            PatternStop(stop: TransitStop(code: $1, name: $1, location: GeoPoint(lat: 0, lon: 0)), sequence: $0)
        })
        #expect(pattern.stopsFingerprint == "caf2626e4e64e05c")
    }
}

nonisolated struct ShapeCheckTests {
    /// A street running east from (32.0, 34.8), a point every ~10 m, turning north after 1 km.
    static let street: [GeoPoint] = {
        let east = (0...100).map { GeoPoint(lat: 32.0, lon: 34.8 + Double($0) * 0.0001059) }
        let north = (1...100).map { GeoPoint(lat: 32.0 + Double($0) * 0.0000898, lon: east.last!.lon) }
        return east + north
    }()
    static func stops(_ indices: [Int], offsetMeters: Double = 8) -> [GeoPoint] {
        indices.map { GeoPoint(lat: street[$0].lat + offsetMeters / 111_320, lon: street[$0].lon) }
    }

    @Test func stopsAlongTheLineInOrderPass() {
        let verdict = ShapeCheck.verdict(RouteShape(Self.street), stops: Self.stops([0, 30, 60, 100, 150, 200]))
        #expect(verdict.passes)
        #expect((verdict.worstOffset ?? .infinity) < 10)
    }

    @Test func stopsInTheOppositeOrderFail() {
        let verdict = ShapeCheck.verdict(RouteShape(Self.street), stops: Self.stops([200, 150, 100, 60, 30, 0]))
        #expect(!verdict.passes)
    }

    @Test func aStopFarFromTheLineFails() {
        var stops = Self.stops([0, 50, 100, 200])
        stops[1].lat += 100 / 111_320
        #expect(!ShapeCheck.verdict(RouteShape(Self.street), stops: stops).passes)
    }

    /// Terminals and bus stations stand off the road.
    @Test func anEndStopMayStandFurtherOff() {
        var stops = Self.stops([0, 50, 100, 200])
        stops[3].lat += 120 / 111_320
        #expect(ShapeCheck.verdict(RouteShape(Self.street), stops: stops).passes)
        #expect(!ShapeCheck.verdict(RouteShape(Self.street), stops: stops, tolerance: ShapeTolerance(stops: 50, ends: 50)).passes)
    }

    @Test func theStopsJoinedByStraightLinesAreRejected() {
        let stops = Self.stops([0, 50, 100, 150, 200], offsetMeters: 0)
        let verdict = ShapeCheck.verdict(RouteShape(stops), stops: stops)
        #expect(!verdict.passes)
        #expect(verdict.reason == "straight lines between stops")
    }

    /// Out along the street and back on it: a stop on the way back must take the second pass.
    @Test func aLineThatDrivesAStreetTwicePassesWithStopsOnBothPasses() {
        let outAndBack = Self.street + Self.street.reversed().dropFirst()
        let stops = Self.stops([20, 120, 190]) + Self.stops([120, 20])
        #expect(ShapeCheck.verdict(RouteShape(outAndBack), stops: stops).passes)
    }

    @Test func withSeveralBranchesEachStopNeedsOnlyOne() {
        let trunk = Array(Self.street[0...100]), branch = Array(Self.street[100...])
        let shape = RouteShape(branches: [trunk, [trunk.last!, GeoPoint(lat: 31.99, lon: trunk.last!.lon)]] + [branch])
        #expect(ShapeCheck.verdict(shape, stops: Self.stops([0, 50, 150, 200])).passes)
    }

    @Test func aBackwardsLineIsTurnedRound() {
        let stops = Self.stops([0, 100, 200])
        #expect(ShapeCheck.oriented(Self.street.reversed(), stops: stops).first == Self.street.first)
    }

    @Test func theShortestPassingPieceIsChosen() {
        let stops = Self.stops([0, 50, 100])
        let full = Self.street, part = Array(Self.street[0...110]), wrong = Array(Self.street[150...])
        #expect(ShapeCheck.bestPiece([full, wrong, part, part], stops: stops) == part)
        #expect(ShapeCheck.bestPiece([wrong], stops: stops) == nil)
    }

    @Test func piecesMeetingEndToEndAreChained() {
        let a = Array(Self.street[0...80]), b = Array(Self.street[80...160]), c = Array(Self.street[160...])
        let chains = ShapeCheck.chained([c, Array(b.reversed()), a])
        #expect(chains.count == 1)
        #expect(chains[0].count == Self.street.count)
        #expect(Set([chains[0].first!, chains[0].last!]) == Set([Self.street.first!, Self.street.last!]))
    }

    /// Out and back along one street, a variant that only runs back is cut from the return pass.
    @Test func aLoopIsTrimmedWhereTheStopsMeetItInOrder() {
        let outAndBack = Self.street + Self.street.reversed().dropFirst()
        let trimmed = ShapeCheck.trimmed(outAndBack, stops: Self.stops([150, 40], offsetMeters: 0))
        #expect(abs(ShapeCheck.length(trimmed) - ShapeCheck.length(Array(Self.street[40...150]))) < 5)
        #expect(ShapeCheck.meters(trimmed.first!, Self.street[150]) < 5)
    }

    @Test func noStopsMatchNothing() {
        #expect(ShapeCheck.orderedOffsets(Self.street, stops: []) == nil)
    }

    @Test func aRouteShapeIsTrimmedToTheVariantsEnds() {
        let trimmed = ShapeCheck.trimmed(Self.street, stops: Self.stops([40, 80, 120], offsetMeters: 0))
        #expect(abs(ShapeCheck.length(trimmed) - ShapeCheck.length(Array(Self.street[40...120]))) < 5)
    }

    @Test func simplifyingDropsPointsOnAStraightRun() {
        let simplified = ShapeCheck.simplified(Self.street)
        #expect(simplified.count == 3)
        #expect(simplified.first == Self.street.first && simplified.last == Self.street.last)
    }
}

/// A feed that counts its calls; its shape is the test street.
private actor CallCounter {
    var shapes = 0, patterns = 0
    func shape() { shapes += 1 }
    func pattern() { patterns += 1 }
}

private nonisolated struct ShapeFeed: TransitProvider {
    let id = "shape-feed"
    let displayName = "Shape feed"
    let capabilities: ProviderCapabilities = [.routePattern, .routeShape]
    let suggestedRefreshInterval: Duration = .seconds(30)
    var calls: CallCounter
    var stopIndices: [Int]
    var carriesShape = false
    var shapeOverride: [GeoPoint]? = nil
    /// The feed answers that it has no path for the line.
    var missing = false
    /// The feed's call fails like this instead.
    var failure: (any Error)? = nil

    var pattern: RoutePattern {
        RoutePattern(line: TransitLine(id: "7", shortName: "7"), stops: ShapeCheckTests.stops(stopIndices).enumerated().map {
            PatternStop(stop: TransitStop(code: "s\($0.offset)-\(stopIndices[$0.offset])", name: "", location: $0.element), sequence: $0.offset)
        })
    }

    func searchStops(query: String) async throws -> [TransitStop] { [] }
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] { [] }
    func routePattern(for line: TransitLine) async throws -> RoutePattern { await calls.pattern(); return pattern }
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] { [] }
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        await calls.shape()
        if missing { throw TransitError.notFound("shape of \(line.shortName)") }
        if let failure { throw failure }
        return RouteShape(shapeOverride ?? ShapeCheckTests.street)
    }
    func routePatternWithShape(for line: TransitLine) async throws -> (pattern: RoutePattern, shape: RouteShape?) {
        await calls.pattern()
        return (pattern, carriesShape ? RouteShape(ShapeCheckTests.street) : nil)
    }
}

/// A feed with no shapes at all: the protocol's default `routeShape`.
private nonisolated struct PlainFeed: TransitProvider {
    let id = "plain-feed"
    let displayName = "Plain feed"
    let capabilities: ProviderCapabilities = [.routePattern]
    let suggestedRefreshInterval: Duration = .seconds(30)
    func searchStops(query: String) async throws -> [TransitStop] { [] }
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] { [] }
    func routePattern(for line: TransitLine) async throws -> RoutePattern { throw TransitError.notFound("x") }
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] { [] }
}

@Suite(.serialized)
struct ShapeCacheTests {
    private func cache() -> TransitCache {
        TransitCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("shape-cache-\(UUID().uuidString)"))
    }

    @Test func aLinesShapeIsFetchedOnce() async throws {
        let cache = cache(), calls = CallCounter()
        let feed = ShapeFeed(calls: calls, stopIndices: [0, 100, 200])
        let first = try await cache.shape(for: feed.pattern, provider: feed)
        let second = try await cache.shape(for: feed.pattern, provider: feed)
        #expect(first.drawable != nil)
        #expect(second == first)
        #expect(await calls.shapes == 1)
    }

    @Test func aChangedStopListFetchesTheShapeAgain() async throws {
        let cache = cache(), calls = CallCounter()
        let before = ShapeFeed(calls: calls, stopIndices: [0, 100, 200])
        let after = ShapeFeed(calls: calls, stopIndices: [0, 120, 200])
        _ = try await cache.shape(for: before.pattern, provider: before)
        #expect(await cache.cachedShape(for: after.pattern, provider: after) == nil)
        _ = try await cache.shape(for: after.pattern, provider: after)
        #expect(await calls.shapes == 2)
    }

    /// A shape that fails its check is kept with the reason, so the feed is not asked again.
    @Test func aRejectedShapeIsKeptAndNotDrawn() async throws {
        let cache = cache(), calls = CallCounter()
        let feed = ShapeFeed(calls: calls, stopIndices: [0, 100, 200], shapeOverride: Array(ShapeCheckTests.street[150...]))
        let stored = try await cache.shape(for: feed.pattern, provider: feed)
        #expect(stored.drawable == nil)
        #expect(stored.verdict.reason != nil)
        _ = try await cache.shape(for: feed.pattern, provider: feed)
        #expect(await calls.shapes == 1)
    }

    @Test func aShapeInThePatternReplyCostsNoRequestOfItsOwn() async throws {
        let cache = cache(), calls = CallCounter()
        let feed = ShapeFeed(calls: calls, stopIndices: [0, 100, 200], carriesShape: true)
        let pattern = try await cache.pattern(for: feed.pattern.line, provider: feed)
        let stored = try await cache.shape(for: pattern, provider: feed)
        #expect(stored.drawable != nil)
        #expect(await calls.shapes == 0)
        #expect(await calls.patterns == 1)
    }

    @Test func theDrawnShapeIsThinned() async throws {
        let cache = cache(), calls = CallCounter()
        let feed = ShapeFeed(calls: calls, stopIndices: [0, 100, 200])
        let stored = try await cache.shape(for: feed.pattern, provider: feed)
        #expect(stored.shape.pointCount < ShapeCheckTests.street.count)
    }

    /// A line the feed has no path for is kept as a rejection like a bad shape, so opening its
    /// card again asks nothing until the week is out.
    @Test func aLineWithNoPathIsNotAskedForAgain() async throws {
        let cache = cache(), calls = CallCounter()
        let feed = ShapeFeed(calls: calls, stopIndices: [0, 100, 200], missing: true)
        let stored = try await cache.shape(for: feed.pattern, provider: feed)
        #expect(stored.drawable == nil)
        _ = try await cache.shape(for: feed.pattern, provider: feed)
        #expect(await calls.shapes == 1)
    }

    @Test func aRejectionIsAskedAgainAfterAWeek() {
        let feed = ShapeFeed(calls: CallCounter(), stopIndices: [0, 100, 200])
        let week = TransitCache.missingShapeLifetime
        let fresh = StoredShape(judging: RouteShape(branches: []), for: feed.pattern, tolerance: .platforms)
        let old = StoredShape(judging: RouteShape(branches: []), for: feed.pattern, tolerance: .platforms,
                              at: Date().addingTimeInterval(-week - 60))
        let oldButGood = StoredShape(judging: RouteShape(ShapeCheckTests.street), for: feed.pattern, tolerance: .platforms,
                                     at: Date().addingTimeInterval(-week - 60))
        #expect(!fresh.isStaleRejection)
        #expect(old.isStaleRejection)
        #expect(!oldButGood.isStaleRejection)
    }

    @Test func aFeedWithoutShapesSaysSoAndIsNotAsked() async {
        let cache = cache()
        let feed = PlainFeed()
        let pattern = RoutePattern(line: TransitLine(id: "x", shortName: "x"), stops: [])
        let error = await #expect(throws: TransitError.self) { _ = try await cache.shape(for: pattern, provider: feed) }
        guard case .unsupported = error else { Issue.record("expected unsupported, got \(String(describing: error))"); return }
    }

    /// An answer asking again would not change is kept like a rejection; one that may pass is not.
    @Test func lastingFailuresAreKeptAndPassingOnesAskedAgain() async throws {
        for (failure, lasting) in [(TransitError.badResponse("HTTP 404 for /x") as any Error, true),
                                   (TransitError.badResponse("not JSON"), true),
                                   (TransitError.badResponse("HTTP 503 for /x"), false),
                                   (TransitError.badResponse("HTTP 429 for /x"), false),
                                   (TransitError.tryLater("no departure tonight"), false),
                                   (URLError(.notConnectedToInternet), false)] {
            #expect(TransitCache.isLasting(failure) == lasting, "\(failure)")
            let cache = cache(), calls = CallCounter()
            let feed = ShapeFeed(calls: calls, stopIndices: [0, 100, 200], failure: failure)
            if lasting {
                #expect(try await cache.shape(for: feed.pattern, provider: feed).drawable == nil)
                _ = try await cache.shape(for: feed.pattern, provider: feed)
                #expect(await calls.shapes == 1, "\(failure)")
            } else {
                _ = try? await cache.shape(for: feed.pattern, provider: feed)
                _ = try? await cache.shape(for: feed.pattern, provider: feed)
                #expect(await calls.shapes == 2, "\(failure)")
            }
        }
    }
}
