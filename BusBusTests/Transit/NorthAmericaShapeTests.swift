import Testing
import Foundation
@testable import BusBus

/// Answers every request with one canned JSON body and remembers what was asked.
private final class CannedShapeResponse: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var urls: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.urls.append(request.url!)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func http(answering json: String) -> HTTPClient {
        body = Data(json.utf8)
        urls = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedShapeResponse.self]
        return HTTPClient(session: URLSession(configuration: configuration))
    }

    static func query(_ name: String) -> String? {
        urls.last.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
    }
}

/// A street running north from (47.60, -122.33), a point every ~11 m, and a spur east off its middle
/// (point 50).
private nonisolated enum Street {
    static func north(_ from: Int, _ to: Int) -> [GeoPoint] {
        stride(from: from, through: to, by: from <= to ? 1 : -1).map { GeoPoint(lat: 47.60 + Double($0) * 0.0001, lon: -122.33) }
    }
    static func east(_ to: Int) -> [GeoPoint] {
        (0...to).map { GeoPoint(lat: 47.605, lon: -122.33 + Double($0) * 0.00015) }
    }
    /// A stop 8 m beside a point of the street.
    static func stop(_ point: GeoPoint) -> GeoPoint { GeoPoint(lat: point.lat, lon: point.lon + 8 / 75_000) }
    static func encoded(_ points: [GeoPoint]) -> String { Polyline.encode(points, precision: 5) }
}

@Suite(.serialized)
struct NorthAmericaShapeTests {
    // MARK: MBTA

    private static func mbtaPattern(shape: Bool) -> String {
        let points = Street.north(0, 100)
        let stops = [5, 50, 95].map { Street.stop(points[$0]) }
        let stopResources = stops.enumerated().map { index, stop in
            #"{"id":"s\#(index)","type":"stop","attributes":{"name":"Stop \#(index)","latitude":\#(stop.lat),"longitude":\#(stop.lon)}}"#
        }
        let shapeLink = shape ? #","shape":{"data":{"id":"010154","type":"shape"}}"# : ""
        let shapeResource = shape
            ? #",{"id":"010154","type":"shape","attributes":{"polyline":"\#(Street.encoded(points).replacingOccurrences(of: "\\", with: "\\\\"))"}}"#
            : ""
        return #"""
            {"data":{"id":"1-_-0","type":"route_pattern","attributes":{"direction_id":0},
              "relationships":{"representative_trip":{"data":{"id":"t1","type":"trip"}}}},
             "included":[{"id":"t1","type":"trip","attributes":{"headsign":"Harvard"},
               "relationships":{"stops":{"data":[{"id":"s0","type":"stop"},{"id":"s1","type":"stop"},{"id":"s2","type":"stop"}]}\#(shapeLink)}}\#(shapeResource),
               \#(stopResources.joined(separator: ","))]}
            """#
    }

    private static let mbtaLine = TransitLine(id: "1-_-0", shortName: "1", providerRefs: ["route": "1", "direction": "0"])

    /// The shape rides on the pattern's own call: one request, the trip's shape id as its version.
    @Test func mbtaCarriesTheShapeInThePatternReply() async throws {
        var provider = MBTAProvider()
        provider.http = CannedShapeResponse.http(answering: Self.mbtaPattern(shape: true))
        let (pattern, shape) = try await provider.routePatternWithShape(for: Self.mbtaLine)
        #expect(CannedShapeResponse.urls.count == 1)
        #expect(CannedShapeResponse.query("include") == "representative_trip.stops,representative_trip.shape")
        #expect(CannedShapeResponse.query("fields[shape]") == "polyline")
        #expect(pattern.stops.map(\.stop.code) == ["s0", "s1", "s2"])
        let found = try #require(shape)
        #expect(found.branches.count == 1 && found.pointCount == 101)
        #expect(found.version == "010154")
        #expect(StoredShape(judging: found, for: pattern, tolerance: provider.shapeTolerance).verdict.passes)
    }

    /// A plain pattern call, made outside the cache (the bus tracker), does not pay for the geometry.
    @Test func mbtaPlainPatternLeavesTheShapeOut() async throws {
        var provider = MBTAProvider()
        provider.http = CannedShapeResponse.http(answering: Self.mbtaPattern(shape: false))
        let pattern = try await provider.routePattern(for: Self.mbtaLine)
        #expect(pattern.stops.count == 3)
        #expect(CannedShapeResponse.query("include") == "representative_trip.stops")
        #expect(CannedShapeResponse.query("fields[shape]") == nil)
        await #expect(throws: TransitError.self) {
            try await provider.routeShape(for: Self.mbtaLine, pattern: pattern)
        }
    }

    // MARK: OneBusAway and MTA Bus Time

    /// Direction 0 runs north in two pieces sent out of order; direction 1 runs south and forks at
    /// the middle, straight on or east, its stop group holding both variants' stops.
    private static func stopsForRoute(route: String, stopPrefix: String) -> String {
        let northbound = [Street.north(50, 100), Street.north(0, 50)]
        let trunk = Street.north(100, 50), straight = Street.north(50, 0), spur = Street.east(60)
        let stops: [(String, GeoPoint)] = [
            ("n1", Street.stop(Street.north(0, 100)[10])), ("n2", Street.stop(Street.north(0, 100)[40])),
            ("n3", Street.stop(Street.north(0, 100)[70])), ("n4", Street.stop(Street.north(0, 100)[95])),
            ("s1", Street.stop(trunk[5])), ("s2", Street.stop(trunk[30])),
            ("s3", Street.stop(straight[30])), ("s4", Street.stop(straight[48])),
            ("e1", Street.stop(spur[30])), ("e2", Street.stop(spur[58])),
        ]
        func pieces(_ lines: [[GeoPoint]]) -> String {
            lines.map { #"{"points":"\#(Street.encoded($0).replacingOccurrences(of: "\\", with: "\\\\"))","length":\#($0.count),"levels":""}"# }
                .joined(separator: ",")
        }
        func ids(_ names: [String]) -> String { names.map { #""\#(stopPrefix)\#($0)""# }.joined(separator: ",") }
        let references = stops.map { name, point in
            #"{"id":"\#(stopPrefix)\#(name)","code":"\#(name)","name":"Stop \#(name)","lat":\#(point.lat),"lon":\#(point.lon)}"#
        }
        return #"""
            {"code":200,"text":"OK","data":{
              "entry":{"routeId":"\#(route)","polylines":[\#(pieces([Street.east(60)]))],
                "stopGroupings":[{"type":"direction","stopGroups":[
                  {"id":"0","name":{"name":"North"},"stopIds":[\#(ids(["n1", "n2", "n3", "n4"]))],"polylines":[\#(pieces(northbound))]},
                  {"id":"1","name":{"name":"South"},"stopIds":[\#(ids(["s1", "s2", "s3", "s4", "e1", "e2"]))],
                   "polylines":[\#(pieces([trunk, straight, spur]))]}]}]},
              "references":{"agencies":[{"id":"1","name":"Metro"}],"routes":[{"id":"\#(route)","shortName":"T","agencyId":"1"}],
                "stops":[\#(references.joined(separator: ","))]}}}
            """#
    }

    private static func obaProvider(answering json: String) -> OneBusAwayProvider {
        var provider = OneBusAwayProvider(.pugetSound)
        provider.endpoint = .proxy("https://proxy.test/pugetsound")
        provider.http = CannedShapeResponse.http(answering: json)
        return provider
    }

    /// Each test asks for a route of its own: the routes stay in a process-wide session cache.
    private static func uniqueRoute(_ prefix: String) -> String { "\(prefix)\(UUID().uuidString)" }

    /// Setup and the nearby screen load every route at a stop through the plain call, so it leaves
    /// the polylines out; the shape is a call of its own, asked for only when a line is opened.
    @Test func obaPiecesMeetingEndToEndBecomeOneLine() async throws {
        let route = Self.uniqueRoute("1_shapes-north-")
        let provider = Self.obaProvider(answering: Self.stopsForRoute(route: route, stopPrefix: "1_"))
        let line = TransitLine(id: "\(route)|0", shortName: "T", providerRefs: ["route": route, "direction": "0"])
        let (pattern, piggybacked) = try await provider.routePatternWithShape(for: line)
        #expect(piggybacked == nil)
        #expect(CannedShapeResponse.query("includePolylines") == "false")
        let shape = try await provider.routeShape(for: line, pattern: pattern)
        #expect(CannedShapeResponse.urls.count == 2)
        #expect(CannedShapeResponse.query("includePolylines") == "true")
        #expect(shape.branches.count == 1)
        #expect(shape.branches[0].first == Street.north(0, 0)[0])
        #expect(shape.branches[0].count == 101)
        #expect(StoredShape(judging: shape, for: pattern, tolerance: provider.shapeTolerance).verdict.passes)
    }

    /// No one trip calls at both the straight-on and the spur stops, so a single line could not
    /// pass; as branches, every stop of the merged stop group lies on one of them.
    @Test func obaAForkedDirectionKeepsEachVariantAsABranch() async throws {
        let route = Self.uniqueRoute("1_shapes-fork-")
        let provider = Self.obaProvider(answering: Self.stopsForRoute(route: route, stopPrefix: "1_"))
        let line = TransitLine(id: "\(route)|1", shortName: "T", providerRefs: ["route": route, "direction": "1"])
        let pattern = try await provider.routePattern(for: line)
        let shape = try await provider.routeShape(for: line, pattern: pattern)
        #expect(shape.branches.count == 2)
        #expect(pattern.stops.count == 6)
        #expect(StoredShape(judging: shape, for: pattern, tolerance: provider.shapeTolerance).verdict.passes)
        // The other direction's card reuses the shaped reply: no third request.
        let other = TransitLine(id: "\(route)|0", shortName: "T", providerRefs: ["route": route, "direction": "0"])
        _ = try await provider.routeShape(for: other, pattern: try await provider.routePattern(for: other))
        #expect(CannedShapeResponse.urls.count == 2)
    }

    @Test func mtaReadsTheSamePiecesFromItsStopsForRoute() async throws {
        let route = Self.uniqueRoute("MTA NYCT_SHAPES-")
        var provider = MTABusTimeProvider()
        provider.endpoint = .proxy("https://proxy.test/mta")
        provider.http = CannedShapeResponse.http(answering: Self.stopsForRoute(route: route, stopPrefix: "MTA_"))
        let line = TransitLine(id: "\(route)|1", shortName: "T", providerRefs: ["route": route, "direction": "1"])
        let (pattern, piggybacked) = try await provider.routePatternWithShape(for: line)
        #expect(piggybacked == nil)
        #expect(CannedShapeResponse.query("includePolylines") == "false")
        #expect(pattern.stops.first?.stop.code == "s1")
        let shape = try await provider.routeShape(for: line, pattern: pattern)
        #expect(CannedShapeResponse.urls.count == 2)
        #expect(CannedShapeResponse.query("includePolylines") == "true")
        #expect(shape.branches.count == 2)
        #expect(StoredShape(judging: shape, for: pattern, tolerance: provider.shapeTolerance).verdict.passes)
    }

    @Test func aDirectionWithoutPolylinesHasNoShape() {
        #expect(OneBusAwayProvider.shape(pieces: []) == nil)
        #expect(OneBusAwayProvider.shape(pieces: ["not a polyline ~"]) == nil)
    }

    // MARK: TTC (Umo NextBus)

    /// Variant `29_0_A` has two stretches, listed out of order and each tagged for several variants;
    /// `29_0_A_X` extends its tag, so its own stretch must not be taken for A's. The last stop's tag
    /// has a "_" in it, and single elements come as objects, as the XML translation sends them.
    private static let ttcConfig: String = {
        func points(_ line: [GeoPoint]) -> String {
            line.map { #"{"lat":"\#($0.lat)","lon":"\#($0.lon)"}"# }.joined(separator: ",")
        }
        let first = Street.north(0, 50), second = Street.north(50, 100), other = Street.east(60)
        return #"""
            {"route":{"tag":"29","title":"29-Dufferin",
              "stop":[{"tag":"100","title":"First","lat":"\#(first[0].lat)","lon":"\#(first[0].lon)","stopId":"1"},
                      {"tag":"200","title":"Middle","lat":"\#(first[50].lat)","lon":"\#(first[50].lon)","stopId":"2"},
                      {"tag":"300_ar","title":"Last","lat":"\#(second[50].lat)","lon":"\#(second[50].lon)"}],
              "direction":[{"tag":"29_0_A","title":"North - 29 Dufferin towards Last","name":"North","useForUI":"true",
                            "stop":[{"tag":"100"},{"tag":"200"},{"tag":"300_ar"}]},
                           {"tag":"29_0_A_X","title":"North - 29 Dufferin towards Elsewhere","name":"North","useForUI":"false",
                            "stop":[{"tag":"100"},{"tag":"200"}]}],
              "path":[{"tag":[{"id":"29_0_A_X_2_100_200"}],"point":[\#(points(other))]},
                      {"tag":[{"id":"29_1_B_4_200_300_ar"},{"id":"29_0_A_4_200_300_ar"}],"point":[\#(points(second))]},
                      {"tag":{"id":"29_0_A_2_100_200"},"point":[\#(points(first))]}]}}
            """#
    }()

    @Test func ttcJoinsTheVariantsStretchesInSequence() async throws {
        var provider = UmoNextBusProvider()
        provider.http = CannedShapeResponse.http(answering: Self.ttcConfig)
        let line = TransitLine(id: "29|29_0_A", shortName: "29", providerRefs: ["route": "29", "direction": "29_0_A", "way": "North"])
        let pattern = RoutePattern(line: line, stops: [0, 50, 100].enumerated().map { index, at in
            PatternStop(stop: TransitStop(code: "\(index)", name: "\(index)", location: Street.north(0, 100)[at]), sequence: index + 1)
        })
        let shape = try await provider.routeShape(for: line, pattern: pattern)
        #expect(CannedShapeResponse.query("command") == "routeConfig")
        #expect(CannedShapeResponse.query("terse") == nil)
        #expect(shape.branches.count == 1)
        // The shared timepoint is kept once.
        #expect(shape.branches[0] == Street.north(0, 100))
        #expect(StoredShape(judging: shape, for: pattern, tolerance: provider.shapeTolerance).verdict.passes)

        // The other variant's card is drawn from the same reply, with no request.
        var other = line
        other.id = "29|29_0_A_X"
        other.providerRefs["direction"] = "29_0_A_X"
        #expect(try await provider.routeShape(for: other, pattern: pattern).branches == [Street.east(60)])
        #expect(CannedShapeResponse.urls.count == 1)
    }
}
