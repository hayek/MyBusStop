import Testing
import Foundation
@testable import BusBus

/// Answers each request with the canned body whose key its URL contains, and remembers the URLs.
private final class CannedReplies: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [String: String] = [:]
    nonisolated(unsafe) static var requested: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requested.append(url)
        let body = Self.bodies.first { url.absoluteString.contains($0.key) }?.value
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func client(_ bodies: [String: String]) -> HTTPClient {
        self.bodies = bodies
        requested = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedReplies.self]
        return HTTPClient(session: URLSession(configuration: configuration))
    }
}

/// A street running east from `start`, a vertex every ~50 m.
private func street(from start: GeoPoint, meters: Double, north: Double = 0) -> [GeoPoint] {
    let frame = ShapeCheck.LocalFrame(around: start)
    return stride(from: 0.0, through: meters, by: 50).map { frame.point(SIMD2($0, north)) }
}

/// Points beside a line, every `every` metres along it, `side` metres to its left (kerbside poles).
private func stops(along line: [GeoPoint], every: Double, side: Double = 15) -> [GeoPoint] {
    let projection = ShapeCheck.Projection(line)
    let total = projection.cumulative.last!
    return stride(from: 0.0, through: total, by: every).map { along in
        let index = min(projection.cumulative.lastIndex { $0 <= along }!, line.count - 2)
        let a = projection.xy[index], b = projection.xy[index + 1]
        let t = (along - projection.cumulative[index]) / max(projection.cumulative[index + 1] - projection.cumulative[index], 1e-9)
        let direction = (b - a) / max(((b - a) * (b - a)).sum().squareRoot(), 1e-9)
        return projection.frame.point(a + t * (b - a) + side * SIMD2(-direction.y, direction.x))
    }
}

private func pattern(_ points: [GeoPoint], line: TransitLine = TransitLine(id: "x", shortName: "x", headsign: nil)) -> RoutePattern {
    RoutePattern(line: line, stops: points.enumerated().map {
        PatternStop(stop: TransitStop(code: "\($0.offset)", name: "Stop \($0.offset)", city: nil, location: $0.element),
                    sequence: $0.offset + 1, distanceAlongRoute: nil)
    })
}

/// A CSDI query reply: one GeoJSON feature per drawn route direction, its pieces as given.
private func csdiReply(_ features: [(id: Int, seq: Int, pieces: [[GeoPoint]])], multi: Bool = true) -> String {
    let items = features.map { feature -> String in
        let pieces = feature.pieces.map { piece in "[" + piece.map { "[\($0.lon),\($0.lat)]" }.joined(separator: ",") + "]" }
        let geometry = multi
            ? #"{"type":"MultiLineString","coordinates":[\#(pieces.joined(separator: ","))]}"#
            : #"{"type":"LineString","coordinates":\#(pieces[0])}"#
        return #"{"type":"Feature","geometry":\#(geometry),"properties":{"ROUTE_ID":\#(feature.id),"ROUTE_SEQ":\#(feature.seq)}}"#
    }
    return #"{"type":"FeatureCollection","features":[\#(items.joined(separator: ","))]}"#
}

private let central = GeoPoint(lat: 22.2820, lon: 114.1580)

@Suite(.serialized)
struct HongKongShapeTests {
    /// The query asks for the one route number and company, in WGS84, thinned on the server, with
    /// no `IN (…)` (the portal's firewall blocks it); the stop-to-stop pieces are joined into one
    /// line without doubling the joints.
    @Test func kmbAsksForTheRouteNumberAndJoinsThePieces() async throws {
        let road = street(from: central, meters: 2_000)
        let pieces = [Array(road[0...10]), Array(road[10...25]), Array(road[25...])]
        var provider = KMBProvider()
        provider.http = CannedReplies.client(["MapServer/0/query": csdiReply([(1053, 1, pieces)])])
        let line = TransitLine(id: "T1A|O|1", shortName: "T1A", headsign: nil)

        let shape = try await provider.routeShape(for: line, pattern: pattern(stops(along: road, every: 250), line: line))

        #expect(shape.branches.count == 1)
        #expect(shape.branches[0].count <= road.count)
        #expect(shape.version == "1053.1")
        let url = try #require(CannedReplies.requested.first?.absoluteString.removingPercentEncoding)
        #expect(url.hasPrefix(HKRouteLines.busLayer + "/query?"))
        #expect(url.contains("where=ROUTE_NAMEE = 'T1A' AND COMPANY_CODE <> 'CTB' AND COMPANY_CODE <> 'NLB'"))
        #expect(url.contains("outSR=4326") && url.contains("f=geojson"))
        #expect(!url.contains(" IN "))
    }

    /// Both directions come back; TD's `ROUTE_SEQ` is not the direction, so the one the stops
    /// lie along in order wins, whatever its number.
    @Test func theVariantTheStopsFitIsPicked() throws {
        let road = street(from: central, meters: 2_000)
        let outbound = HKRouteLines.Feature(routeID: 8571, seq: 1, line: road)
        let inbound = HKRouteLines.Feature(routeID: 8571, seq: 2, line: road.reversed())
        let elsewhere = HKRouteLines.Feature(routeID: 9000, seq: 1, line: street(from: central, meters: 2_000, north: 400))
        // Stops on the far kerb, running west.
        let westbound = Array(stops(along: road, every: 250, side: -15).reversed())

        let shape = try #require(HKRouteLines.shape([outbound, elsewhere, inbound], stops: westbound))

        #expect(shape.version == "8571.2")
        #expect(shape.branches.first?.first.map { ShapeCheck.meters($0, road.last!) < 30 } == true)
    }

    /// A circular route is one loop at TD and two halves at Citybus: the loop is cut to the half.
    @Test func aLoopIsCutToTheHalfThePatternRuns() throws {
        let frame = ShapeCheck.LocalFrame(around: central)
        let corners: [SIMD2<Double>] = [[0, 0], [1_000, 0], [1_000, 600], [0, 600], [0, 0]]
        var loop: [GeoPoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let steps = Int((((b - a) * (b - a)).sum().squareRoot() / 50).rounded())
            loop += (0..<steps).map { frame.point(a + Double($0) / Double(steps) * (b - a)) }
        }
        loop.append(loop[0])
        let firstHalf = Array(loop[0...32])   // along the bottom and up the right side
        let feature = HKRouteLines.Feature(routeID: 1495, seq: 1, line: loop)

        let shape = try #require(HKRouteLines.shape([feature], stops: stops(along: firstHalf, every: 200)))

        let drawn = ShapeCheck.length(shape.branches[0])
        #expect(drawn < 0.6 * ShapeCheck.length(loop))
        #expect(drawn > 0.4 * ShapeCheck.length(loop))
    }

    /// MTR Bus K18 is one circular line at MTR and two directions at TD, out to Kwong Fuk and back:
    /// the two are run one after the other.
    @Test func aCircleDrawnAsTwoDirectionsIsJoined() throws {
        let frame = ShapeCheck.LocalFrame(around: central)
        let out = street(from: central, meters: 1_000)
        let back = [frame.point([1_000, 0])] + street(from: frame.point([0, 300]), meters: 1_000).reversed() + [central]
        let loop = out + back.dropFirst()
        let features = [HKRouteLines.Feature(routeID: 1428, seq: 1, line: back), HKRouteLines.Feature(routeID: 1428, seq: 2, line: out)]

        let shape = try #require(HKRouteLines.shape(features, stops: stops(along: loop, every: 250)))

        #expect(shape.version == "1428.2,1428.1")
        #expect(shape.branches.count == 1)
    }

    /// Citybus 1 outbound lists the stops of two TD variants (one via Chater Road, one via Des Voeux
    /// Road): neither passes alone, so both are drawn, as branches.
    @Test func aStopListMergingTwoVariantsGetsBothAsBranches() throws {
        let frame = ShapeCheck.LocalFrame(around: central)
        let start = street(from: central, meters: 800)
        let viaNorth = start + [frame.point([850, 100]), frame.point([1_000, 150]), frame.point([1_200, 150]),
                                frame.point([1_350, 100])] + street(from: frame.point([1_400, 0]), meters: 800)
        let viaSouth = start + [frame.point([850, -100]), frame.point([1_000, -150]), frame.point([1_200, -150]),
                                frame.point([1_350, -100])] + street(from: frame.point([1_400, 0]), meters: 800)
        let north = HKRouteLines.Feature(routeID: 1480, seq: 1, line: viaNorth)
        let south = HKRouteLines.Feature(routeID: 1000326, seq: 1, line: viaSouth)
        let shared = stops(along: start, every: 200)
        let after = stops(along: street(from: frame.point([1_400, 0]), meters: 800), every: 200)
        let merged = shared + [frame.point([1_100, 165]), frame.point([1_100, -165])] + after

        let shape = try #require(HKRouteLines.shape([north, south], stops: merged))

        #expect(shape.branches.count == 2)
        #expect(shape.version == "1480.1,1000326.1")
        #expect(ShapeCheck.verdict(shape, stops: merged).passes)
        #expect(HKRouteLines.shape([north], stops: merged) == nil)
    }

    /// A stop on no drawn variant (Citybus 11 inbound's Ice House Street stop) is let stand beside
    /// the line when the provider allows it, and only within reach.
    @Test func aStopOnNoVariantIsToleratedOnlyWhereAllowed() throws {
        let road = street(from: central, meters: 2_000)
        var listed = stops(along: road, every: 250)
        listed[4] = ShapeCheck.LocalFrame(around: listed[4]).point([0, 120])
        let feature = HKRouteLines.Feature(routeID: 1495, seq: 1, line: road)

        #expect(HKRouteLines.shape([feature], stops: listed) == nil)
        let tolerated = try #require(HKRouteLines.shape([feature], stops: listed, misses: 2))
        #expect(tolerated.version == "1495.1")
        #expect(ShapeCheck.verdict(tolerated, stops: listed, tolerance: CitybusProvider().shapeTolerance).passes)

        listed[4] = ShapeCheck.LocalFrame(around: listed[4]).point([0, 300])
        #expect(HKRouteLines.shape([feature], stops: listed, misses: 2) == nil)
    }

    /// Nothing drawn for the route, or nothing that fits: no shape, and the provider says
    /// `notFound`, which the cache keeps as turned down instead of asking CSDI on every opening.
    @Test func noFittingVariantIsNoShape() {
        let road = street(from: central, meters: 2_000)
        let away = HKRouteLines.Feature(routeID: 1, seq: 1, line: street(from: central, meters: 2_000, north: 500))
        #expect(HKRouteLines.shape([away], stops: stops(along: road, every: 250)) == nil)
        #expect(HKRouteLines.shape([], stops: stops(along: road, every: 250)) == nil)
    }

    /// Minibus ids are the GMB API's own: one direction is asked for by id, and comes as a LineString.
    @Test func gmbAsksForItsOwnRouteIdAndSequence() async throws {
        let road = street(from: central, meters: 1_500)
        var provider = GMBProvider()
        provider.http = CannedReplies.client(["MapServer/0/query": csdiReply([(2002285, 1, [road])], multi: false)])
        let line = TransitLine(id: "2002285|1", shortName: "12", headsign: nil)

        let shape = try await provider.routeShape(for: line, pattern: pattern(stops(along: road, every: 300), line: line))

        #expect(shape.version == "2002285.1")
        let url = try #require(CannedReplies.requested.first?.absoluteString.removingPercentEncoding)
        #expect(url.hasPrefix(HKRouteLines.minibusLayer + "/query?"))
        #expect(url.contains("where=ROUTE_ID = 2002285 AND ROUTE_SEQ = 1"))
    }

    /// TD drew only four MTR feeders; the rest have no line anywhere, and cost no request.
    @Test func mtrBusRoutesTDNeverDrewAreNotAsked() async throws {
        var provider = MTRBusProvider()
        provider.http = CannedReplies.client([:])
        let line = TransitLine(id: "K51:O", shortName: "K51", headsign: nil, providerRefs: ["routeName": "K51"])
        await #expect {
            try await provider.routeShape(for: line, pattern: pattern(stops(along: street(from: central, meters: 1_000), every: 250), line: line))
        } throws: { error in
            if case TransitError.unsupported = error { true } else { false }
        }
        #expect(CannedReplies.requested.isEmpty)
    }
}
