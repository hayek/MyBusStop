import Testing
import Foundation
@testable import BusBus

/// Answers each request with the canned body whose key the URL contains (first match by key length,
/// longest first), and remembers what was asked.
private final class CannedReplies: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [String: String] = [:]
    nonisolated(unsafe) static var asked: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.asked.append(url)
        let text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        let key = Self.bodies.keys.sorted { $0.count > $1.count }.first { text.contains($0) }
        let response = HTTPURLResponse(url: url, statusCode: key == nil ? 404 : 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((key.flatMap { Self.bodies[$0] } ?? "").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session(_ bodies: [String: String]) -> URLSession {
        self.bodies = bodies
        asked = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedReplies.self]
        return URLSession(configuration: configuration)
    }

    static func http(_ bodies: [String: String]) -> HTTPClient { HTTPClient(session: session(bodies)) }
}

private func stop(_ code: String, _ lat: Double, _ lon: Double) -> TransitStop {
    TransitStop(code: code, name: code, city: nil, location: GeoPoint(lat: lat, lon: lon))
}

private func pattern(_ line: TransitLine, _ stops: [TransitStop]) -> RoutePattern {
    RoutePattern(line: line, stops: stops.enumerated().map { PatternStop(stop: $1, sequence: $0 + 1) })
}

@Suite(.serialized)
struct CentralEastEuropeShapeTests {
    // MARK: Entur

    /// A street running east in Bergen, a point every ~55 m (precision-5 polyline).
    private static let bergenStreet = "o|qoJ_an_@?gE?gE?gE?gE?gE?gE?gE?gE?gE?gE"

    private static func enturQuay(_ id: String, lon: Double, place: String, parent: String?) -> String {
        let parentJSON = parent.map { #","parent":{"id":"\#($0)","name":"Big interchange","latitude":60.392,"longitude":\#(lon)}"# } ?? ""
        return #"{"id":"\#(id)","name":"\#(id)","latitude":60.39004,"longitude":\#(lon),"stopPlace":{"id":"\#(place)","name":"\#(place)","latitude":60.39004,"longitude":\#(lon)\#(parentJSON)}}"#
    }

    private static let enturLine = """
        {"data":{"line":{"journeyPatterns":[
          {"id":"TEST:JP:long","directionType":"outbound","pointsOnLink":{"points":"\(bergenStreet)"},
           "serviceJourneysForDate":[{"id":"a"},{"id":"b"}],
           "quays":[\(enturQuay("Q1", lon: 5.3201, place: "NSR:StopPlace:1", parent: "NSR:StopPlace:P1")),
                    \(enturQuay("Q2", lon: 5.3250, place: "NSR:StopPlace:2", parent: nil)),
                    \(enturQuay("Q3", lon: 5.3299, place: "NSR:StopPlace:3", parent: nil))]},
          {"id":"TEST:JP:short","directionType":"outbound","pointsOnLink":{"points":"o|qoJg`o_@?gE?gE?gE?gE?gE"},
           "serviceJourneysForDate":[{"id":"c"}],
           "quays":[\(enturQuay("Q2", lon: 5.3250, place: "NSR:StopPlace:2", parent: nil)),
                    \(enturQuay("Q3", lon: 5.3299, place: "NSR:StopPlace:3", parent: nil))]},
          {"id":"TEST:JP:back","directionType":"inbound","pointsOnLink":{"points":"_ibE_ibE"},
           "serviceJourneysForDate":[{"id":"d"},{"id":"e"},{"id":"f"}],
           "quays":[\(enturQuay("Q2", lon: 5.3250, place: "NSR:StopPlace:2", parent: nil))]}
        ]}}}
        """

    /// The busiest pattern of the direction is drawn, its path read from the pattern reply itself,
    /// and the stop shown as the interchange's centre (220 m off the road) is judged at its quay.
    @Test func enturTakesTheChosenPatternsPathFromThePatternReply() async throws {
        var provider = EnturProvider()
        provider.client = EnturClient(session: CannedReplies.session(["graphql": Self.enturLine]))
        let line = TransitLine(id: "TEST:Line:shapes#outbound#NSR:StopPlace:2", shortName: "4",
                               providerRefs: ["line": "TEST:Line:shapes", "direction": "outbound", "stop": "NSR:StopPlace:2"])

        let (pattern, shape) = try await provider.routePatternWithShape(for: line)
        let drawn = try #require(shape)
        #expect(drawn.version == "TEST:JP:long")
        #expect(drawn.pointCount == 11)
        #expect(pattern.stops.map(\.stop.code) == ["NSR:StopPlace:P1", "NSR:StopPlace:2", "NSR:StopPlace:3"])
        #expect(drawn.stopPositions?["NSR:StopPlace:P1"] == GeoPoint(lat: 60.39004, lon: 5.3201))
        #expect(StoredShape(judging: drawn, for: pattern, tolerance: provider.shapeTolerance).verdict.passes)
        // Judged at the parent's centre it would not pass.
        #expect(!ShapeCheck.verdict(drawn, stops: pattern.stops.map(\.stop.location)).passes)
        #expect(provider.capabilities.contains(.routeShape))
    }

    // MARK: Föli

    @Test func foliFetchesTheShapeOfTheTripThePatternCameFrom() async throws {
        var provider = FoliProvider()
        provider.http = CannedReplies.http([
            "/gtfs/v0/": #"{"latest":"20261014-184142"}"#,
            "/shapes/57": #"[{"lat":60.45168,"lon":22.26546,"traveled":0},{"lat":60.452,"lon":22.267,"traveled":120.5}]"#,
        ])
        let line = TransitLine(id: "6/0", shortName: "6", providerRefs: ["routeId": "13", "direction": "0", "shapeId": "51"])
        // The pattern fell back to a fresh trip with another shape; that one is the pattern's.
        var patternLine = line
        patternLine.providerRefs["shapeId"] = "57"
        let shape = try await provider.routeShape(for: line, pattern: pattern(patternLine, []))
        #expect(shape.branches == [[GeoPoint(lat: 60.45168, lon: 22.26546), GeoPoint(lat: 60.452, lon: 22.267)]])
        #expect(CannedReplies.asked.last?.path == "/gtfs/v0/20261014-184142/shapes/57")
    }

    /// The saved trip belongs to an older dataset and no trip has the saved shape any more: the
    /// pattern is built from a fresh trip, and the shape drawn is that trip's own.
    @Test func foliPatternFromAFreshTripCarriesThatTripsShape() async throws {
        var provider = FoliProvider()
        provider.http = CannedReplies.http([
            "/gtfs/v0/": #"{"latest":"20261014-184142"}"#,
            "20261014-184142/stops": #"{"1":{"stop_name":"Eins","stop_lat":60.45168,"stop_lon":22.26546},"2":{"stop_name":"Zwei","stop_lat":60.452,"stop_lon":22.267}}"#,
            "/stop_times/trip/old": "[]",
            "/trips/route/13": #"[{"route_id":"13","trip_id":"t9","direction_id":1,"shape_id":"99"},{"route_id":"13","trip_id":"t1","direction_id":0,"shape_id":"57"}]"#,
            "/stop_times/trip/t1": #"[{"stop_id":"1","stop_sequence":1},{"stop_id":"2","stop_sequence":2}]"#,
            "/shapes/57": #"[{"lat":60.45168,"lon":22.26546},{"lat":60.452,"lon":22.267}]"#,
        ])
        let line = TransitLine(id: "6/0", shortName: "6", providerRefs: ["routeId": "13", "direction": "0", "shapeId": "51", "tripId": "old"])
        let routePattern = try await provider.routePattern(for: line)
        #expect(routePattern.stops.map(\.stop.code) == ["1", "2"])
        #expect(routePattern.line.providerRefs["shapeId"] == "57")
        _ = try await provider.routeShape(for: line, pattern: routePattern)
        #expect(CannedReplies.asked.last?.path == "/gtfs/v0/20261014-184142/shapes/57")
    }

    // MARK: Tampere

    /// The deltas are subtracted: adding them would send this line south instead of north-east.
    @Test func tampereProjectionDeltasAreSubtracted() throws {
        let points = try TampereProvider.decodeProjection("6149800,2376000:-10,0:-5,-20")
        #expect(points == [GeoPoint(lat: 61.498, lon: 23.76), GeoPoint(lat: 61.4981, lon: 23.76),
                           GeoPoint(lat: 61.49815, lon: 23.7602)])
    }

    @Test func tampereKeepsThePatternsRouteAndDrawsItWithOneCall() async throws {
        var provider = TampereProvider()
        provider.http = CannedReplies.http([
            "/journey-patterns/abc": #"""
                {"status":"success","body":[{"url":"https://data.itsfactory.fi/journeys/api/1/journey-patterns/abc",
                 "lineUrl":"https://data.itsfactory.fi/journeys/api/1/lines/4",
                 "routeUrl":"https://data.itsfactory.fi/journeys/api/1/routes/745769644","direction":"0",
                 "stopPoints":[{"shortName":"0012","name":"Keskustori F","location":"61.4978,23.76253"},
                               {"shortName":"0015","name":"Hämeenkatu","location":"61.4986,23.7655"}]}]}
                """#,
            "/routes/745769644": #"{"status":"success","body":[{"geographicCoordinateProjection":"6149780,2376253:-80,-297"}]}"#,
        ])
        let line = TransitLine(id: "4/0", shortName: "4", providerRefs: ["line": "4", "direction": "0", "patternId": "abc"])
        let routePattern = try await provider.routePattern(for: line)
        #expect(routePattern.line.providerRefs["routeId"] == "745769644")

        let asked = CannedReplies.asked.count
        let shape = try await provider.routeShape(for: line, pattern: routePattern)
        #expect(CannedReplies.asked.count == asked + 1)
        #expect(CannedReplies.asked.last?.query?.contains("exclude-fields=journeys,journeyPatterns") == true)
        #expect(shape.branches == [[GeoPoint(lat: 61.4978, lon: 23.76253), GeoPoint(lat: 61.4986, lon: 23.7655)]])
        #expect(shape.version == "745769644")
    }

    // MARK: Gdańsk

    @Test func gdanskReadsTheVariantsLineStringAsLonLat() async throws {
        var provider = GdanskProvider()
        provider.http = CannedReplies.http([
            "/shapes": #"{"coordinates":[[18.57239,54.4115],[18.57227,54.41146]],"type":"LineString","properties":{"routeId":199,"tripId":121}}"#,
        ])
        let line = TransitLine(id: "199-1", shortName: "199", providerRefs: ["route": "199", "direction": "1", "trip": "121"])
        let shape = try await provider.routeShape(for: line, pattern: pattern(line, []))
        #expect(shape.branches == [[GeoPoint(lat: 54.4115, lon: 18.57239), GeoPoint(lat: 54.41146, lon: 18.57227)]])
        let query = try #require(CannedReplies.asked.last?.query)
        #expect(query.contains("routeId=199") && query.contains("tripId=121") && query.contains("date="))
    }

    // MARK: LPP

    @Test func lppPicksTheSubRouteByTripID() async throws {
        var provider = LPPProvider()
        provider.http = CannedReplies.http([
            "/route/routes": #"""
                {"success":true,"data":[
                  {"route_id":"BDE5","trip_id":"98FC3555-0962","route_number":"6","geojson_shape":{"type":"LineString","coordinates":[[14.53,46.10],[14.52,46.09]]}},
                  {"route_id":"BDE5","trip_id":"811F5A86-DCA6","route_number":"6","geojson_shape":{"type":"LineString","coordinates":[[14.46,46.03],[14.47,46.04]]}}]}
                """#,
        ])
        let line = TransitLine(id: "811f5a86-dca6", shortName: "6", providerRefs: ["routeId": "BDE5", "stationCode": "600011"])
        let shape = try await provider.routeShape(for: line, pattern: pattern(line, []))
        #expect(shape.branches == [[GeoPoint(lat: 46.03, lon: 14.46), GeoPoint(lat: 46.04, lon: 14.47)]])
        #expect(CannedReplies.asked.last?.query?.contains("shape=1") == true)

        // The other direction is in the same reply, kept for its card.
        let back = TransitLine(id: "98fc3555-0962", shortName: "6", providerRefs: ["routeId": "BDE5"])
        #expect(try await provider.routeShape(for: back, pattern: pattern(back, [])).branches
                == [[GeoPoint(lat: 46.10, lon: 14.53), GeoPoint(lat: 46.09, lon: 14.52)]])
        #expect(CannedReplies.asked.count == 1)
    }

    /// Another sub-route's MultiLineString does not break the reply, and one's own pieces are
    /// threaded from the first stop to the last; a piece off the route is left out.
    @Test func lppReadsMultiLineStrings() async throws {
        var provider = LPPProvider()
        provider.http = CannedReplies.http([
            "/route/routes": #"""
                {"success":true,"data":[
                  {"route_id":"E60E","trip_id":"A","geojson_shape":{"type":"MultiLineString","coordinates":[
                    [[14.5000,46.0500],[14.5010,46.0500]],[[14.5010,46.0500],[14.5020,46.0500]],[[14.6000,46.1000],[14.6010,46.1000]]]}},
                  {"route_id":"E60E","trip_id":"B","geojson_shape":{"type":"LineString","coordinates":[[14.46,46.03],[14.47,46.04]]}}]}
                """#,
        ])
        let line = TransitLine(id: "A", shortName: "2", providerRefs: ["routeId": "E60E"])
        let stops = [stop("1", 46.05003, 14.5000), stop("2", 46.05003, 14.5020)]
        let shape = try await provider.routeShape(for: line, pattern: pattern(line, stops))
        #expect(shape.branches == [[GeoPoint(lat: 46.05, lon: 14.5), GeoPoint(lat: 46.05, lon: 14.501),
                                    GeoPoint(lat: 46.05, lon: 14.502)]])
    }

    // MARK: Pikas

    @Test func pikasMapFilesAreNamedLikeTheSitesOwn() {
        #expect(PikasProvider.mapFile(city: PikasProvider.tallinn.city, transport: "bus", number: "9") == "tallinna-linn_bus_9.txt")
        #expect(PikasProvider.mapFile(city: PikasProvider.tallinn.city, transport: "nightbus", number: "N1") == "tallinna-linn_bus_n1.txt")
        #expect(PikasProvider.mapFile(city: PikasProvider.vilnius.city, transport: "expressbus", number: "3G") == "vilnius_expressbus_3g.txt")
        #expect(PikasProvider.mapFile(city: PikasProvider.kaunas.city, transport: "expressbus", number: "43P (10.22)")
                == "kaunas_bus_43p%2810.22%29.txt")
    }

    @Test func pikasMapRecordsAreReadPerVariantType() throws {
        let text = "a-b\r\no|qoJ_an_@?gE\r\nBBB\r\nB1-A\r\no|qoJg`o_@?gE\r\nBBB\r\n"
        let records = PikasProvider.mapRecords(text)
        #expect(records["a-b"] == "o|qoJ_an_@?gE")
        #expect(records["b1-a"] == "o|qoJg`o_@?gE")
        #expect(try Polyline.decode(try #require(records["a-b"])).count == 2)
    }

    // MARK: İETT

    @Test func iettJoinsTheLegsAndKeepsEachJointOnce() {
        let wkt = "LINESTRING (28.92 41.02, 28.93 41.03)|LINESTRING (28.93 41.03, 28.94 41.04)|LINESTRING EMPTY"
        #expect(IETTProvider.decodeRoutePin(wkt) == [GeoPoint(lat: 41.02, lon: 28.92), GeoPoint(lat: 41.03, lon: 28.93),
                                                     GeoPoint(lat: 41.04, lon: 28.94)])
        #expect(IETTProvider.decodeRoutePin("").isEmpty)
    }

    // MARK: EFA (Linz, Vienna)

    /// A street running east in Vienna, a point every ~10 m.
    private static let street = (0...30).map { GeoPoint(lat: 48.2, lon: 16.3 + Double($0) * 0.000135) }
    private static func north(_ point: GeoPoint, _ meters: Double) -> GeoPoint {
        GeoPoint(lat: point.lat + meters / 111_320, lon: point.lon)
    }

    @Test func efaPiecesInAnyOrderAndEitherWayRoundAreChainedFromTheFirstStop() {
        let s = Self.street
        let pieces = [Array(s[20...30]), Array(s[10...20].reversed()), Array(s[0...10]),
                      // Another variant's branch, far from the tail once it reaches the last stop.
                      [GeoPoint(lat: 48.21, lon: 16.31), GeoPoint(lat: 48.211, lon: 16.311)]]
        let stops = [s[0], s[15], s[30]].map { Self.north($0, 5) }
        let chain = EFAShape.stitch(pieces, stops: stops)
        #expect(chain == s)
    }

    /// A piece that starts back on the chain (variants split where they overlap) cuts the chain back
    /// to it; a far-away piece is never bridged to with a straight line.
    @Test func efaOverlappingPiecesCutBackAndFarPiecesAreNotBridged() {
        let s = Self.street
        let far = [GeoPoint(lat: 48.23, lon: 16.33), GeoPoint(lat: 48.231, lon: 16.331)]
        let pieces = [Array(s[0...14]), Array(s[10...30]), far]
        let stops = [s[0], s[20], s[30]].map { Self.north($0, 5) }
        #expect(EFAShape.stitch(pieces, stops: stops) == s)

        let short = EFAShape.stitch([Array(s[0...10]), far], stops: [s[0], s[30]])
        #expect(short == Array(s[0...10]))
    }

    @Test func efaDetourPiecesAreSplicedInWhereAStopIsOffTheChain() {
        let s = Self.street
        let detour = [s[12], Self.north(s[12], 100), Self.north(s[18], 100), s[18]]
        let pieces = [Array(s[0...15]), detour, Array(s[15...30])]
        let stops = [s[0], Self.north(s[15], 100), s[30]]
        let chain = EFAShape.stitch(pieces, stops: stops)
        #expect(ShapeCheck.verdict(RouteShape(chain), stops: stops).passes)
        #expect(chain.contains(Self.north(s[12], 100)))
    }

    /// A 3.2 km loop that ends 5 m from where it starts, and a turning stub into the terminal whose
    /// ends both lie ~40 m off, by the loop's first and last vertices. The last stop stands in the
    /// terminal, off the loop, so the stub is spliced in for it; it must not stand in for the loop.
    @Test func efaATurningStubAtALoopsTerminusDoesNotReplaceTheLoop() {
        let origin = GeoPoint(lat: 48.2, lon: 16.3)
        let east = 111_320 * cos(origin.lat * .pi / 180)
        func at(_ x: Double, _ y: Double) -> GeoPoint { GeoPoint(lat: origin.lat + y / 111_320, lon: origin.lon + x / east) }
        let corners: [(Double, Double)] = [(0, 0), (1000, 0), (1000, 600), (0, 600), (0, 5)]
        var loop: [GeoPoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let steps = Int((hypot(b.0 - a.0, b.1 - a.1) / 50).rounded(.down))
            loop += (0..<steps).map { at(a.0 + (b.0 - a.0) * Double($0) / Double(steps), a.1 + (b.1 - a.1) * Double($0) / Double(steps)) }
        }
        loop.append(at(0, 5))
        let stub = [at(-40, 1), at(-80, 3), at(-40, 9)]
        let stops = [at(5, -15), at(500, 10), at(990, 300), at(500, 590), at(10, 300), at(-75, 3)]

        let chain = EFAShape.stitch([Array(loop[..<40]), Array(loop[39...]), stub], stops: stops)
        #expect(ShapeCheck.length(chain) > ShapeCheck.length(loop))
        #expect(ShapeCheck.verdict(RouteShape(chain), stops: stops).passes)
    }

    /// Variants that part and meet again 400 m on: the pattern's direct road, with a stop on it,
    /// and a 1.3 km hospital loop with none, in a geo object that lists them in no order.
    private static func shortcut(directGap: Double) -> (west: [GeoPoint], loop: [GeoPoint], direct: [GeoPoint], east: [GeoPoint], stops: [GeoPoint]) {
        let origin = GeoPoint(lat: 52, lon: 10)
        let east = 111_320 * cos(origin.lat * .pi / 180)
        func at(_ x: Double, _ y: Double) -> GeoPoint { GeoPoint(lat: origin.lat + y / 111_320, lon: origin.lon + x / east) }
        func road(_ a: (Double, Double), _ b: (Double, Double)) -> [GeoPoint] {
            let steps = max(1, Int((hypot(b.0 - a.0, b.1 - a.1) / 25).rounded(.down)))
            return (0...steps).map { at(a.0 + (b.0 - a.0) * Double($0) / Double(steps), a.1 + (b.1 - a.1) * Double($0) / Double(steps)) }
        }
        let loop = road((1000, 0), (1000, 500)) + road((1000, 500), (1400, 500)).dropFirst() + road((1400, 500), (1400, 0)).dropFirst()
        return (road((0, 0), (1000, 0)), loop, road((1000 + directGap, 0), (1400 - directGap, 0)), road((1400, 0), (2400, 0)),
                [at(0, 8), at(500, 8), at(1200, 8), at(1900, 8), at(2400, 8)])
    }

    /// The chain took the loop (the direct road's ends lie 40 m off, too far to chain): the stop
    /// on the direct road splices it in, and the loop goes, however long, as no stop is on it.
    @Test func efaAShortcutReplacesALoopWithNoStopsOnIt() {
        let r = Self.shortcut(directGap: 40)
        for pieces in [[r.west, r.loop, r.direct, r.east], [r.east, r.direct, r.west, r.loop]] {
            let chain = EFAShape.stitch(pieces, stops: r.stops)
            #expect(ShapeCheck.verdict(RouteShape(chain), stops: r.stops).passes)
            #expect(ShapeCheck.length(chain) < 2_500)
        }
    }

    /// Where the direct road and the loop both start at the tail, the chain takes the one heading
    /// for the next stop, whichever the reply lists first.
    @Test func efaAtAJunctionTheChainTakesTheWayToTheNextStop() {
        let r = Self.shortcut(directGap: 0)
        for pieces in [[r.west, r.loop, r.direct, r.east], [r.west, r.direct, r.loop, r.east]] {
            let chain = EFAShape.stitch(pieces, stops: r.stops)
            #expect(ShapeCheck.verdict(RouteShape(chain), stops: r.stops).passes)
            #expect(ShapeCheck.length(chain) < 2_500)
        }
    }

    private static let linzGeoObject = #"""
        {"transportations":[{"id":"linz:26:H","locationSequence":[
          {"id":"at:44:1:1","type":"platform","coord":[48.20005,16.3],"parent":{"id":"at:44:1","name":"Eins"}},
          {"id":"at:44:2:1","type":"platform","coord":[48.20005,16.30202],"parent":{"id":"at:44:2","name":"Zwei"}},
          {"id":"at:44:3:1","type":"platform","coord":[48.20005,16.30405],"parent":{"id":"at:44:3","name":"Drei"}}],
         "coords":[[[48.2,16.30270],[48.2,16.30405]],[[48.2,16.30135],[48.2,16.3]],[[48.2,16.30135],[48.2,16.30270]]]}]}
        """#

    @Test func linzTakesTheShapeFromTheGeoObjectThePatternComesFrom() async throws {
        var provider = EFAProvider(.linz)
        provider.http = CannedReplies.http(["XML_GEOOBJECT_REQUEST": Self.linzGeoObject])
        let line = TransitLine(id: "linz:26:H", shortName: "26", providerRefs: ["stop": "at:44:2"])
        let (routePattern, shape) = try await provider.routePatternWithShape(for: line)
        #expect(CannedReplies.asked.count == 1)
        #expect(routePattern.stops.map(\.stop.code) == ["at:44:1", "at:44:2", "at:44:3"])
        let drawn = try #require(shape)
        #expect(drawn.branches.first?.first == GeoPoint(lat: 48.2, lon: 16.3))
        #expect(drawn.branches.first?.last == GeoPoint(lat: 48.2, lon: 16.30405))
        #expect(StoredShape(judging: drawn, for: routePattern, tolerance: provider.shapeTolerance).verdict.passes)
    }

    /// Linz's geo object can list two variants' stops in one run (tram 3's depot branch after its
    /// terminus). No path serves that order, so the next trip at the stop is taken whole instead.
    @Test func linzTakesTheNextTripWhenTheGeoObjectMergesVariants() async throws {
        let merged = Self.linzGeoObject.replacingOccurrences(of: #""parent":{"id":"at:44:3","name":"Drei"}}],"#, with: #"""
            "parent":{"id":"at:44:3","name":"Drei"}},
            {"id":"at:44:9:1","type":"platform","coord":[48.203,16.3],"parent":{"id":"at:44:9","name":"Remise"}}],
            """#)
        #expect(merged.contains("at:44:9"))
        var provider = EFAProvider(.linz)
        provider.http = CannedReplies.http([
            "XML_GEOOBJECT_REQUEST": merged,
            "XML_DM_REQUEST": #"""
                {"stopEvents":[{"location":{"id":"at:44:2:1","parent":{"id":"at:44:2"}},"departureTimePlanned":"2026-10-19T10:00:00Z",
                  "transportation":{"id":"linz:26:H","properties":{"tripCode":42}}}]}
                """#,
            "XML_STOPSEQCOORD_REQUEST": #"""
                {"leg":{"stopSequence":[
                  {"id":"at:44:1:1","type":"platform","coord":[48.20005,16.3],"parent":{"id":"at:44:1","name":"Eins"}},
                  {"id":"at:44:2:1","type":"platform","coord":[48.20005,16.30202],"parent":{"id":"at:44:2","name":"Zwei"}},
                  {"id":"at:44:3:1","type":"platform","coord":[48.20005,16.30405],"parent":{"id":"at:44:3","name":"Drei"}}],
                 "coords":[[48.2,16.3],[48.2,16.30135],[48.2,16.3027],[48.2,16.30405]]}}
                """#,
        ])
        let line = TransitLine(id: "linz:26:H", shortName: "26", providerRefs: ["stop": "at:44:2"])
        let (routePattern, shape) = try await provider.routePatternWithShape(for: line)
        #expect(routePattern.stops.map(\.stop.code) == ["at:44:1", "at:44:2", "at:44:3"])
        #expect(shape?.pointCount == 4)
        #expect(try await provider.routePattern(for: line).stops.count == 3)
    }

    /// The rider's stop is on no variant and has no trip now: the longest variant is shown, and the
    /// trip that was just not found is not asked for a second time when that variant's path fails.
    @Test func linzAsksForTheNextTripOnlyOnce() async throws {
        var provider = EFAProvider(.linz)
        provider.http = CannedReplies.http([
            "XML_GEOOBJECT_REQUEST": Self.linzGeoObject.replacingOccurrences(of: #""coords":"#, with: #""unused":"#),
            "XML_DM_REQUEST": #"{"stopEvents":[]}"#,
        ])
        let line = TransitLine(id: "linz:26:H", shortName: "26", providerRefs: ["stop": "at:44:7"])
        let (routePattern, shape) = try await provider.routePatternWithShape(for: line)
        #expect(routePattern.stops.count == 3)
        #expect(shape?.isEmpty == true)
        #expect(CannedReplies.asked.filter { $0.path.hasSuffix("XML_DM_REQUEST") }.count == 1)
    }

    /// The other EFA hosts keep their patterns as they were and draw no shape, at no extra request.
    @Test func otherEFAHostsDrawNoShape() async throws {
        var provider = EFAProvider(.badenWuerttemberg)
        provider.http = CannedReplies.http(["XML_GEOOBJECT_REQUEST": Self.linzGeoObject])
        let line = TransitLine(id: "linz:26:H", shortName: "26", providerRefs: ["stop": "at:44:2"])
        let (routePattern, shape) = try await provider.routePatternWithShape(for: line)
        #expect(shape == nil)
        #expect(routePattern.stops.count == 3)
        #expect(!provider.capabilities.contains(.routeShape))
        await #expect(throws: TransitError.self) { try await provider.routeShape(for: line, pattern: routePattern) }
        #expect(CannedReplies.asked.count == 1)
    }

    @Test func viennaRoutingLineIDsAreBuiltFromTheLineNameAndMode() {
        #expect(WienerLinienProvider.efaLineID(name: "13A", mode: "ptBusCity", direction: 1, year: 2026) == "vor:2313A: :H:j26")
        #expect(WienerLinienProvider.efaLineID(name: "2A", mode: "ptBusCity", direction: 1, year: 2026) == "vor:2302A: :H:j26")
        #expect(WienerLinienProvider.efaLineID(name: "6", mode: "ptTram", direction: 2, year: 2027) == "vor:22006: :R:j27")
        #expect(WienerLinienProvider.efaLineID(name: "N60", mode: "ptBusNight", direction: 1, year: 2026) == "vor:24N60: :H:j26")
        #expect(WienerLinienProvider.efaLineID(name: "N6", mode: "ptBusNight", direction: 2, year: 2026) == "vor:24N06: :R:j26")
        #expect(WienerLinienProvider.efaLineID(name: "WLB", mode: "ptTramWLB", direction: 1, year: 2026) == nil)
    }

    /// The line names its mode, so its path is the geo object alone: the reference files, which
    /// do not know line 99999, are never asked.
    @Test func viennaAsksOnlyForTheGeoObjectOfALineThatCarriesItsMode() async throws {
        var provider = WienerLinienProvider()
        provider.routingHTTP = CannedReplies.http([
            "XML_GEOOBJECT_REQUEST": #"{"transportations":[{"coords":[[[48.2,16.3],[48.2,16.301]],[[48.2,16.301],[48.2,16.302]]]}]}"#,
        ])
        let line = TransitLine(id: "99999:1", shortName: "13A",
                               providerRefs: ["lineId": "99999", "direction": "1", "rbl": "1", "mode": "ptBusCity"])
        let shape = try await provider.routeShape(for: line, pattern: pattern(line, [stop("1", 48.2, 16.3), stop("2", 48.2, 16.302)]))
        #expect(shape.pointCount == 3)
        #expect(CannedReplies.asked.count == 1)
        #expect(CannedReplies.asked.first?.query?.removingPercentEncoding?.contains("line=vor:2313A: :H:j") == true)
    }

    /// The file keeps every variant ever planned. Tram 6's longest runs on to Zentralfriedhof, a
    /// diversion that no longer runs; the lowest-numbered one is the timetable's base route, and
    /// it gives the line both its stops and its destination.
    @Test func viennaShowsTheBaseVariantNotTheLongest() {
        let names = ["Eins", "Zwei", "Drei", "Vier", "Zentralfriedhof"]
        let stopRows = names.enumerated().map { ["\($0.offset + 1)", "", $0.element, "Wien", "90001", "\(16.30 + Double($0.offset) * 0.002)", "48.2"] }
        let lineRows = [["106", "6", "6", "1", "ptTram"]]
        let base = [1, 2, 3].map { ["106", "10", "\($0)", "\($0)", "1"] }
        let diversion = [1, 2, 3, 4, 5].map { ["106", "20", "\($0)", "\($0)", "1"] }

        let lines = WienerLinienProvider.timetableLines(at: 1, stopRows: stopRows, lineRows: lineRows, patternRows: diversion + base)

        #expect(lines.count == 1)
        #expect(lines.first?.line.destination == "Drei")
        #expect(lines.first?.stops == ["1", "2", "3"])
    }

    /// The 2026 timetable started on Sunday 14 December 2025.
    @Test func viennaTimetableYearTurnsOnTheSecondSundayOfDecember() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna")!
        func years(_ month: Int, _ day: Int, _ year: Int = 2025) throws -> [Int] {
            WienerLinienProvider.timetableYears(try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))))
        }
        #expect(try years(10, 19, 2026) == [2026])
        #expect(try years(12, 13) == [2025, 2026])
        #expect(try years(12, 14) == [2026, 2025])
    }
}
