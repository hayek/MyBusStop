import Testing
import Foundation
@testable import BusBus

/// Answers by the longest path prefix that matches, with canned JSON, and keeps every URL asked for.
private final class ShapeStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [String: String] = [:]
    nonisolated(unsafe) static var requested: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requested.append(url)
        let path = url.absoluteString.components(separatedBy: "?")[0]
        let body = Self.replies.filter { path.hasSuffix($0.key) || url.path.hasPrefix($0.key) }.max { $0.key.count < $1.key.count }?.value
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session(_ replies: [String: String]) -> URLSession {
        Self.replies = replies
        Self.requested = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShapeStub.self]
        return URLSession(configuration: configuration)
    }
}

/// Shapes of tfl, star-rennes, carrismetropolitana, bizkaibus, VBB (HAFAS) and Transitous, from
/// made-up straight roads in replies shaped like what each sent on 2026-10-19
/// (docs/research/route-shapes/west-europe.md).
@Suite(.serialized)
struct WestEuropeShapeTests {
    // MARK: Geometry

    /// A straight road east from `start`, a vertex every ~70 m: `count` vertices.
    private static func road(lat: Double, from lon: Double, count: Int, step: Double = 0.001) -> [GeoPoint] {
        (0..<count).map { GeoPoint(lat: lat, lon: lon + Double($0) * step) }
    }

    /// Stops a few metres off the road at these longitudes.
    private static func stops(lat: Double, at lons: [Double], offset: Double = 0.00003) -> [GeoPoint] {
        lons.map { GeoPoint(lat: lat + offset, lon: $0) }
    }

    private static func pattern(_ points: [GeoPoint], line: TransitLine = TransitLine(id: "L", shortName: "L")) -> RoutePattern {
        RoutePattern(line: line, stops: points.enumerated().map { index, point in
            PatternStop(stop: TransitStop(code: "S\(index)", name: "Stop \(index)", city: nil, location: point), sequence: index)
        })
    }

    private static func lonLat(_ points: [GeoPoint]) -> [[Double]] { points.map { [$0.lon, $0.lat] } }

    private static func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private static func judged(_ shape: RouteShape?, _ pattern: RoutePattern, _ tolerance: ShapeTolerance = .platforms) -> ShapeVerdict? {
        shape.map { StoredShape(judging: $0, for: pattern, tolerance: tolerance).verdict }
    }

    // MARK: TfL

    private static let london = 51.5
    private static let full = road(lat: london, from: -0.10, count: 21)
    private static let shortWorking = road(lat: london, from: -0.10, count: 11)

    /// 63 inbound: two identical lineStrings, each holding the full route and the short working.
    private static let lineStrings = Array(repeating: json([lonLat(full), lonLat(shortWorking)]), count: 2)

    @Test func tflTakesTheShortestPieceTheStopsLieAlong() {
        let short = Self.pattern(Self.stops(lat: Self.london, at: [-0.10, -0.095, -0.09]))
        let whole = Self.pattern(Self.stops(lat: Self.london, at: [-0.10, -0.09, -0.08]))
        #expect(TfLProvider.shape(Self.lineStrings, for: short, tolerance: .platforms)?.branches == [Self.shortWorking])
        #expect(TfLProvider.shape(Self.lineStrings, for: whole, tolerance: .platforms)?.branches == [Self.full])
    }

    /// 19 inbound's Highbury Grove routing has no line of its own: the longest piece is kept, so
    /// the cache records it as rejected rather than asking again.
    @Test func tflKeepsARejectedShapeWhenNoPieceFits() throws {
        let elsewhere = Self.pattern(Self.stops(lat: Self.london + 0.01, at: [-0.10, -0.09, -0.08]))
        let shape = try #require(TfLProvider.shape(Self.lineStrings, for: elsewhere, tolerance: .platforms))
        #expect(shape.branches == [Self.full])
        #expect(Self.judged(shape, elsewhere)?.passes == false)
    }

    @Test func tflShapeComesWithThePatternReply() async throws {
        let ids = ["A", "B", "C"]
        let points = Self.stops(lat: Self.london, at: [-0.10, -0.09, -0.08])
        let sequence: [String: Any] = [
            "stopPointSequences": [["stopPoint": zip(ids, points).map { ["id": $0, "name": $0, "lat": $1.lat, "lon": $1.lon] }]],
            "orderedLineRoutes": [["naptanIds": ids]],
            "lineStrings": Self.lineStrings,
        ]
        var provider = TfLProvider()
        provider.http = HTTPClient(session: ShapeStub.session(["/Line/63/Route/Sequence/inbound": Self.json(sequence)]))
        let line = TransitLine(id: "63:inbound", shortName: "63", providerRefs: ["lineId": "63", "direction": "inbound", "naptanId": "A"])
        let (pattern, shape) = try await provider.routePatternWithShape(for: line)
        #expect(pattern.stops.map(\.stop.code) == ids)
        #expect(shape?.branches == [Self.full])
        #expect(Self.judged(shape, pattern)?.passes == true)
        #expect(ShapeStub.requested.count == 1)
    }

    /// A reply without `lineStrings` says there is no path: an empty shape, not "not asked".
    @Test func tflReplyWithoutALineGivesAnEmptyShape() async throws {
        let ids = ["A", "B"]
        let points = Self.stops(lat: Self.london, at: [-0.10, -0.09])
        let sequence: [String: Any] = [
            "stopPointSequences": [["stopPoint": zip(ids, points).map { ["id": $0, "name": $0, "lat": $1.lat, "lon": $1.lon] }]],
            "orderedLineRoutes": [["naptanIds": ids]],
        ]
        var provider = TfLProvider()
        provider.http = HTTPClient(session: ShapeStub.session(["/Line/63/Route/Sequence/inbound": Self.json(sequence)]))
        let line = TransitLine(id: "63:inbound", shortName: "63", providerRefs: ["lineId": "63", "direction": "inbound", "naptanId": "A"])
        let (_, shape) = try await provider.routePatternWithShape(for: line)
        #expect(shape?.isEmpty == true)
    }

    // MARK: STAR (Rennes)

    @Test func starReadsTheVariantsTraceAndItsVersion() async throws {
        let rennes = 48.11
        let trace = Self.road(lat: rennes, from: -1.68, count: 15)
        let reply: [String: Any] = ["total_count": 1, "results": [[
            "id": "0001-A-2844-3028", "datedebutversion": "2026-07-06",
            "parcours": ["type": "Feature", "geometry": ["type": "LineString", "coordinates": Self.lonLat(trace)], "properties": [:]],
        ]]]
        var provider = STARRennesProvider()
        provider.http = HTTPClient(session: ShapeStub.session(["/tco-bus-topologie-parcours-td/records": Self.json(reply)]))
        let line = TransitLine(id: "0001-0", shortName: "C1", providerRefs: ["parcours": "0001-A-2844-3028"])
        let pattern = Self.pattern(Self.stops(lat: rennes, at: [-1.68, -1.675, -1.666]), line: line)
        let shape = try await provider.routeShape(for: line, pattern: pattern)
        #expect(shape.branches == [trace])
        #expect(shape.version == "2026-07-06")
        #expect(Self.judged(shape, pattern)?.passes == true)
        let query = ShapeStub.requested.first?.query?.removingPercentEncoding ?? ""
        #expect(query.contains(#"where=id="0001-A-2844-3028""#))
    }

    // MARK: Carris Metropolitana

    @Test func carrisAsksForThePatternsShapeByItsID() async throws {
        let lisbon = 38.76
        let geometry = Self.road(lat: lisbon, from: -9.30, count: 12)
        let reply: [String: Any] = [
            "shape_id": "[0277F]2605_0_1", "extension": 900,
            "geojson": ["type": "Feature", "properties": [:], "geometry": ["type": "LineString", "coordinates": Self.lonLat(geometry)]],
            "points": [["shape_pt_lat": lisbon, "shape_pt_lon": -9.30, "shape_pt_sequence": 1, "shape_dist_traveled": 0]],
        ]
        var provider = CarrisMetropolitanaProvider()
        provider.http = HTTPClient(session: ShapeStub.session(["/v2/shapes/%5B0277F%5D2605_0_1": Self.json(reply)]))
        let line = TransitLine(id: "2605_0_1", shortName: "2605", providerRefs: ["lineId": "2605", "shape": "[0277F]2605_0_1"])
        let pattern = Self.pattern(Self.stops(lat: lisbon, at: [-9.30, -9.295, -9.289]), line: line)
        let shape = try await provider.routeShape(for: line, pattern: pattern)
        #expect(shape.branches == [geometry])
        #expect(shape.version == "[0277F]2605_0_1")
        #expect(ShapeStub.requested.count == 1)
        #expect(ShapeStub.requested.first?.absoluteString.hasSuffix("/v2/shapes/%5B0277F%5D2605_0_1") == true)
    }

    // MARK: Bizkaibus

    /// The reply as the service sends it: JSONP, single and double quotes mixed, with the route's
    /// stops (unordered) after the line.
    private static func bizkaibusReply(_ path: [GeoPoint]) -> String {
        let coordinates = path.map { "[\($0.lon),\($0.lat)]" }.joined(separator: ",")
        return """
            ({'STATUS': 'OK',"Ruta":{"attributes":{'Linea':'A3224', 'Descripcion':'BILBAO - DERIO', 'Ruta':'001', 'Sentido':'I'}, \
            "geometry":{"paths":[[\(coordinates)]]}}, "Paradas":{"features":[{"attributes":{"CodigoReducidoParada":"0806",\
            "Denominacion":"Deustuko Unibertsitatea"},"geometry":{"x":-2.94,"y":43.27}}]}});
            """
    }

    @Test func bizkaibusCutsThePathsOutOfTheReply() throws {
        let path = Self.road(lat: 43.26, from: -2.94, count: 8)
        #expect(try BizkaibusProvider.routePaths(Self.bizkaibusReply(path)) == [path])
        #expect(throws: (any Error).self) { try BizkaibusProvider.routePaths("({'STATUS': 'ERROR'});") }
    }

    /// A3224 `I` is stored end to start; it is turned to run the itinerary's way.
    @Test func bizkaibusTurnsABackwardRouteAround() throws {
        let path = Self.road(lat: 43.26, from: -2.94, count: 20)
        let stops = Self.stops(lat: 43.26, at: [-2.94, -2.93, -2.921])
        let backward = try BizkaibusProvider.routeShape(Self.bizkaibusReply(path.reversed()), stops: stops)
        #expect(backward.branches == [path])
        let forward = try BizkaibusProvider.routeShape(Self.bizkaibusReply(path), stops: stops)
        #expect(forward.branches == [path])
        #expect(Self.judged(backward, Self.pattern(stops))?.passes == true)
    }

    // MARK: VBB (HAFAS)

    private static let berlin = 52.51

    private static func vbb(journey: [String: Any]) -> HafasProvider {
        let board: [String: Any] = ["Departure": [[
            "name": "Bus 200", "direction": "Michelangelostr.", "directionFlag": "1", "date": "2026-10-19", "time": "12:00:00",
            "stopExtId": "900100003", "ProductAtStop": ["line": "200", "lineId": "200"], "JourneyDetailRef": ["ref": "1|32387|0|86|19102026"],
        ]]]
        var provider = HafasProvider(.vbb)
        provider.http = HTTPClient(session: ShapeStub.session(["/departureBoard": json(board), "/journeyDetail": json(journey)]))
        provider.endpoint = .proxy("https://hafas.test")
        return provider
    }

    /// Stops come at their station's centre; the second here stands 150 m off the road, as
    /// Potsdamer Platz does from the 200's.
    private static let vbbStops: [[String: Any]] = [
        ["extId": "900100003", "name": "Alexanderplatz", "lat": berlin + 0.00003, "lon": 13.40],
        ["extId": "900100020", "name": "Potsdamer Platz", "lat": berlin + 0.00135, "lon": 13.41],
        ["extId": "900110728", "name": "Michelangelostr.", "lat": berlin + 0.00003, "lon": 13.419],
    ]

    @Test func vbbShapeComesWithTheTripAndIsJudgedAgainstStationCentres() async throws {
        let line = Self.road(lat: Self.berlin, from: 13.40, count: 20)
        let crd = line.flatMap { [$0.lon, $0.lat] }
        let provider = Self.vbb(journey: [
            "Stops": ["Stop": Self.vbbStops],
            "PolylineGroup": ["polylineDesc": [["crd": crd, "delta": false, "dim": 2]]],
        ])
        let transitLine = TransitLine(id: "200|1", shortName: "200", providerRefs: ["stop": "900100003"])
        let (pattern, shape) = try await provider.routePatternWithShape(for: transitLine)
        #expect(shape?.branches == [line])
        #expect(provider.capabilities.contains(.routeShape))
        #expect(Self.judged(shape, pattern, provider.shapeTolerance)?.passes == true)
        #expect(Self.judged(shape, pattern, .platforms)?.passes == false)
        let journey = try #require(ShapeStub.requested.first { $0.path.hasSuffix("/journeyDetail") })
        #expect(journey.query?.contains("poly=1") == true)
    }

    /// The plain pattern call sends the same `journeyDetail` request, so the proxy's cache serves both.
    @Test func vbbPatternAsksForTheSameTrip() async throws {
        let provider = Self.vbb(journey: ["Stops": ["Stop": Self.vbbStops]])
        let pattern = try await provider.routePattern(for: TransitLine(id: "200|1", shortName: "200", providerRefs: ["stop": "900100003"]))
        #expect(pattern.stops.count == 3)
        #expect(ShapeStub.requested.first { $0.path.hasSuffix("/journeyDetail") }?.query?.contains("poly=1") == true)
    }

    /// A trip without its line is kept as "no path" along with the pattern, so the card asks
    /// nothing more.
    @Test func vbbTripWithoutItsLineIsKeptAsNoPath() async throws {
        let provider = Self.vbb(journey: ["Stops": ["Stop": Self.vbbStops]])
        let cache = TransitCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("vbb-\(UUID().uuidString)"))
        let line = TransitLine(id: "200|1", shortName: "200", providerRefs: ["stop": "900100003"])
        let pattern = try await cache.pattern(for: line, provider: provider)
        let asked = ShapeStub.requested.count
        #expect(try await cache.shape(for: pattern, provider: provider).drawable == nil)
        #expect(ShapeStub.requested.count == asked)
    }

    @Test func hafasPolylinesDecodeAbsoluteAndDelta() throws {
        func decode(_ json: String) throws -> RouteShape? {
            try JSONDecoder().decode(HafasProvider.DTO.Polylines.self, from: Data(json.utf8)).shape
        }
        let absolute = try decode(#"{"polylineDesc":[{"crd":[13.33,52.50,13.34,52.51],"delta":false,"dim":2}]}"#)
        #expect(absolute?.branches == [[GeoPoint(lat: 52.50, lon: 13.33), GeoPoint(lat: 52.51, lon: 13.34)]])
        let delta = try decode(#"{"polylineDesc":[{"crd":[13.33,52.50,0.01,0.01,0.01,0],"delta":true,"dim":2}]}"#)
        let points = try #require(delta?.branches.first)
        #expect(points.count == 3)
        #expect(abs(points[2].lon - 13.35) < 1e-9 && abs(points[2].lat - 52.51) < 1e-9)
    }

    // MARK: Transitous

    @Test func transitousShapeComesWithTheTrip() async throws {
        let zurich = 47.37
        let geometry = Self.road(lat: zurich, from: 8.54, count: 16)
        let stop = { (id: String, lon: Double, departure: String?) -> [String: Any] in
            var place: [String: Any] = ["name": id, "stopId": id, "lat": zurich + 0.00003, "lon": lon]
            place["departure"] = departure
            return place
        }
        let departure = "2026-10-19T07:50:00Z"
        let stopTimes: [String: Any] = ["stopTimes": [[
            "place": stop("ZH-HB", 8.54, departure), "realTime": false, "headsign": "Rehalp",
            "routeId": "r4", "directionId": "0", "tripId": "T4", "routeShortName": "4",
        ]]]
        let trip: [String: Any] = ["legs": [[
            "tripId": "T4", "from": stop("ZH-HB", 8.54, departure), "intermediateStops": [stop("ZH-M", 8.547, nil)],
            "to": stop("ZH-REH", 8.555, nil),
            "legGeometry": ["points": Polyline.encode(geometry, precision: 6), "precision": 6, "length": geometry.count],
        ]]]
        var provider = TransitousProvider()
        provider.session = ShapeStub.session(["/api/v6/stoptimes": Self.json(stopTimes), "/api/v6/trip": Self.json(trip)])
        let line = TransitLine(id: "r4|0", shortName: "4", providerRefs: ["routeId": "r4", "stopId": "ZH-HB"])
        let (pattern, shape) = try await provider.routePatternWithShape(for: line)
        #expect(pattern.stops.map(\.stop.code) == ["ZH-HB", "ZH-M", "ZH-REH"])
        #expect(shape?.pointCount == geometry.count)
        #expect(Self.judged(shape, pattern)?.passes == true)
        #expect(provider.shapeDatasetID == "transitous")
    }

    /// No departure soon (at night) says nothing about the path: the card is told to ask again,
    /// not that there is none, which the cache would keep for a week.
    @Test func noTripTonightIsAskedForAgainLater() async throws {
        func isTryLater(_ error: any Error) -> Bool { if case TransitError.tryLater = error { true } else { false } }
        var transitous = TransitousProvider()
        transitous.session = ShapeStub.session(["/api/v6/stoptimes": #"{"stopTimes":[]}"#])
        let line = TransitLine(id: "r4|0", shortName: "4", providerRefs: ["routeId": "r4", "stopId": "ZH-NIGHT"])
        let pattern = Self.pattern(Self.stops(lat: 47.37, at: [8.54, 8.55]), line: line)
        await #expect { try await transitous.routeShape(for: line, pattern: pattern) } throws: { isTryLater($0) }

        let vbb = Self.vbb(journey: ["Stops": ["Stop": Self.vbbStops]])
        let night = TransitLine(id: "N2|1", shortName: "N2", providerRefs: ["stop": "900100003"])
        await #expect { try await vbb.routeShape(for: night, pattern: pattern) } throws: { isTryLater($0) }
        #expect(!ShapeStub.requested.contains { $0.path.hasSuffix("/journeyDetail") })
    }
}
