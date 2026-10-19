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

@Suite(.serialized)
struct ToeiShapeTests {
    private static let asakusa = GeoPoint(lat: 35.7100, lon: 139.7980)

    /// A pattern reply, with its poles, along `road`; `region` is the path as Toei publishes it.
    private static func provider(pattern id: String, road: [GeoPoint], region: [GeoPoint]?) -> (ToeiBusProvider, TransitLine) {
        let poles = stops(along: road, every: 300)
        let order = poles.indices.map { #"{"odpt:index":\#($0 + 1),"odpt:busstopPole":"odpt.BusstopPole:Toei.Test.\#($0).1"}"# }
        let regionJSON = region.map { points in
            #","ug:region":{"type":"LineString","coordinates":[\#(points.map { "[\($0.lon),\($0.lat)]" }.joined(separator: ","))]}"#
        } ?? ""
        let patternJSON = #"""
            [{"owl:sameAs":"\#(id)","dc:title":"都99 テスト行","dc:date":"2026-09-03T03:08:13+09:00",
              "odpt:busroute":"odpt.Busroute:Toei.Test99","odpt:busstopPoleOrder":[\#(order.joined(separator: ","))]\#(regionJSON)}]
            """#
        let polesJSON = "[" + poles.enumerated().map {
            #"{"owl:sameAs":"odpt.BusstopPole:Toei.Test.\#($0.offset).1","dc:title":"テスト\#($0.offset)","geo:lat":\#($0.element.lat),"geo:long":\#($0.element.lon)}"#
        }.joined(separator: ",") + "]"
        var provider = ToeiBusProvider()
        provider.http = CannedReplies.client(["odpt:BusroutePattern": patternJSON, "odpt:BusstopPole": polesJSON])
        return (provider, TransitLine(id: id, shortName: "都99", headsign: nil))
    }

    /// `ug:region` comes in the very reply the pattern is read from: no request of its own, and
    /// the pattern's `dc:date` as the shape's version.
    @Test func theShapeComesWithThePattern() async throws {
        let road = street(from: Self.asakusa, meters: 2_400)
        let (provider, line) = Self.provider(pattern: "odpt.BusroutePattern:Toei.Test99.1.1", road: road, region: road)

        let (pattern, shape) = try await provider.routePatternWithShape(for: line)
        let asked = CannedReplies.requested.count

        let carried = try #require(shape)
        #expect(pattern.stops.count == 9)
        #expect(carried.branches == [road])
        #expect(carried.version == "2026-09-03T03:08:13+09:00")
        #expect(ShapeCheck.verdict(carried, stops: pattern.stops.map(\.stop.location), tolerance: provider.shapeTolerance).passes)
        // routeShape answers from the session's copy of the pattern.
        #expect(try await provider.routeShape(for: line, pattern: pattern) == carried)
        #expect(CannedReplies.requested.count == asked)
    }

    /// A few patterns are stored backwards (Tan96.1712.2): turned round to run the stops' way.
    @Test func aBackwardsPathIsTurnedRound() async throws {
        let road = street(from: Self.asakusa, meters: 2_400)
        let (provider, line) = Self.provider(pattern: "odpt.BusroutePattern:Toei.Test99.2.1", road: road, region: road.reversed())

        let (_, shape) = try await provider.routePatternWithShape(for: line)

        #expect(shape?.branches == [road])
    }

    /// Nine patterns have no `ug:region`: the pattern still reads with an empty shape, and
    /// `routeShape` answers `notFound` from the session's copy (which the cache keeps as turned
    /// down), asking nothing.
    @Test func aPatternWithoutAPathHasNoShape() async throws {
        let road = street(from: Self.asakusa, meters: 2_400)
        let (provider, line) = Self.provider(pattern: "odpt.BusroutePattern:Toei.Test99.3.1", road: road, region: nil)

        let (pattern, shape) = try await provider.routePatternWithShape(for: line)
        let asked = CannedReplies.requested.count

        #expect(pattern.stops.count == 9)
        #expect(shape?.isEmpty == true)
        await #expect {
            try await provider.routeShape(for: line, pattern: pattern)
        } throws: { error in
            if case TransitError.notFound = error { true } else { false }
        }
        #expect(CannedReplies.requested.count == asked)
    }
}
