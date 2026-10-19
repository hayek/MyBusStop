import Testing
import Foundation
@testable import BusBus

/// Answers by path (and `passlist`) with canned HAFAS JSON, and keeps every URL asked for.
private final class HafasStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [String: (status: Int, body: String)] = [:]
    nonisolated(unsafe) static var requested: [URL] = []

    /// "departureBoard", "departureBoard+passlist", and either with "@<id>" for one stop's board.
    static func keys(_ url: URL) -> [String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let passlist = items.first { $0.name == "passlist" }?.value == "1"
        let base = url.lastPathComponent + (passlist ? "+passlist" : "")
        let id = items.first { $0.name == "id" }?.value
        return (id.map { ["\(base)@\($0)"] } ?? []) + [base, url.lastPathComponent]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requested.append(url)
        let reply = Self.keys(url).lazy.compactMap { Self.replies[$0] }.first ?? (404, "{}")
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// HAFAS ReST (Luxembourg, VBB). Replies follow the field names both servers sent on 2026-10-01.
@Suite(.serialized)
struct HafasProviderTests {
    private static func provider(_ network: HafasProvider.Network, replies: [String: (Int, String)]) -> HafasProvider {
        HafasStub.replies = replies.mapValues { (status: $0.0, body: $0.1) }
        HafasStub.requested = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HafasStub.self]
        var provider = HafasProvider(network)
        provider.http = HTTPClient(session: URLSession(configuration: configuration))
        provider.endpoint = .proxy("https://hafas.test")
        return provider
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private static let gare = TransitStop(code: "200405036", name: "Luxembourg, Gare Centrale routière", city: nil,
                                          location: GeoPoint(lat: 49.59907, lon: 6.133034))

    /// One departure; `extra` adds or overrides fields ("cancelled":true, "rtTime":…).
    private static func departure(line: String, lineId: String, flag: String?, direction: String, time: String,
                                  date: String = "2026-10-01", platform: String = "300034009", extra: String = "") -> String {
        let flagField = flag.map { #""directionFlag":"\#($0)","# } ?? ""
        return #"""
            {"name":"Bus \#(line)","direction":"\#(direction)",\#(flagField)"date":"\#(date)","time":"\#(time)",
             "stopExtId":"\#(platform)","JourneyDetailRef":{"ref":"1|\#(line)|\#(time)"},
             "ProductAtStop":{"line":"\#(line)","lineId":"\#(lineId)","name":"Bus \#(line)","operator":"RGTR"}\#(extra)}
            """#
    }

    private static func board(_ departures: [String]) -> String {
        #"{"Departure":[\#(departures.joined(separator: ","))]}"#
    }

    // MARK: - Stations and search

    /// Platforms gather under their station ("main mast"), at the station's place, with the
    /// highest weight and the distinct lines of all of them.
    @Test func platformsBecomeOneStation() throws {
        let places = try Self.decode(HafasProvider.DTO.Locations.self, #"""
            {"stopLocationOrCoordLocation":[
              {"StopLocation":{"extId":"300101001","name":"Clervaux, Gare routière/Lycée","lat":50.0541,"lon":6.0291,"weight":2776,
                "mainMastExtId":"110101002","mainMastLat":50.0540,"mainMastLon":6.0290,"mainMast":{"name":"Clervaux, Gare routière/Lycée"},
                "productAtStop":[{"line":"160","lineId":"L_160"},{"line":"161","lineId":"L_161"}]}},
              {"StopLocation":{"extId":"300101002","name":"Clervaux, Gare routière/Lycée","lat":50.0542,"lon":6.0292,"weight":2776,
                "mainMastExtId":"110101002","productAtStop":[{"line":"160","lineId":"L_160"},{"line":"A05","lineId":"L_A05"}]}},
              {"CoordLocation":{"name":"an address"}},
              {"StopLocation":{"extId":"900078101","name":"U Hermannplatz (Berlin)","lat":52.48,"lon":13.42}}
            ]}
            """#)
        let stations = HafasProvider.stations(places.stops)
        #expect(stations.map(\.stop.code) == ["110101002", "900078101"])
        #expect(stations[0].stop.location == GeoPoint(lat: 50.0540, lon: 6.0290))
        #expect(stations[0].lines == ["L_160", "L_161", "L_A05"])
        #expect(stations[0].weight == 2776)
        #expect(stations[1].stop.name == "U Hermannplatz (Berlin)")
    }

    private static func station(_ code: String, _ name: String, weight: Int = 0, lines: Int = 0) -> HafasProvider.Station {
        HafasProvider.Station(stop: TransitStop(code: code, name: name, city: nil, location: GeoPoint(lat: 0, lon: 0)),
                              folded: HafasProvider.fold(name), weight: weight,
                              lines: Set((0..<lines).map(String.init)))
    }

    /// A town's bus station comes before a minor stop of the same town, though its name is longer;
    /// at equal weight, the one more lines call at.
    @Test func searchPrefersTheStationThatMatters() {
        let stations = [
            Self.station("1", "Clervaux, Lycée", weight: 439, lines: 6),
            Self.station("2", "Clervaux, Maison de Retraite", weight: 2776, lines: 20),
            Self.station("3", "Clervaux, Gare routière/Lycée", weight: 2776, lines: 27),
            Self.station("4", "Heinerscheid, Clervauxer Strooss", weight: 9000, lines: 40),
        ]
        #expect(HafasProvider.search("Clervaux", in: stations).map(\.code) == ["3", "2", "1", "4"])
    }

    @Test func searchIgnoresAccentsCaseAndWordOrder() {
        let stations = [Self.station("1", "Luxembourg, Gare Centrale routière"), Self.station("2", "Esch-sur-Alzette, Gare routière")]
        #expect(HafasProvider.search("gare centrale ROUTIERE", in: stations).map(\.code) == ["1"])
        #expect(HafasProvider.search("routiere esch", in: stations).map(\.code) == ["2"])
        #expect(HafasProvider.search("Gare", in: stations).count == 2)
        #expect(HafasProvider.search("Trier", in: stations).isEmpty)
        #expect(HafasProvider.search("  ,  ", in: stations).isEmpty)
    }

    /// A station id typed in finds that station alone.
    @Test func searchFindsAStationByItsID() {
        let stations = [Self.station("200405036", "Luxembourg, Gare Centrale routière"), Self.station("200405037", "Luxembourg, rue Heine")]
        #expect(HafasProvider.search("200405037", in: stations).map(\.name) == ["Luxembourg, rue Heine"])
    }

    // MARK: - Lines

    /// One line per HAFAS line and direction, shortest numbers first; a cancelled trip offers nothing.
    @Test func linesAreOnePerDirectionAndSkipCancelledTrips() throws {
        let board = try Self.decode(HafasProvider.DTO.Board.self, Self.board([
            Self.departure(line: "22", lineId: "X_22", flag: "1", direction: "Strassen, Primeurs", time: "14:59:00"),
            Self.departure(line: "22", lineId: "X_22", flag: "2", direction: "Hollerich, P+R Bouillon", time: "15:00:00"),
            Self.departure(line: "22", lineId: "X_22", flag: "1", direction: "Strassen, Primeurs", time: "15:09:00"),
            Self.departure(line: "180", lineId: "X_180", flag: "1", direction: "Bitburg, ZOB", time: "15:31:00",
                           extra: #","cancelled":true"#),
            Self.departure(line: "4", lineId: "X_4", flag: "1", direction: "Dommeldange", time: "15:02:00"),
        ]))
        let lines = HafasProvider.lines(from: board.Departure ?? [], at: "200405036")
        #expect(lines.map(\.shortName) == ["4", "22", "22"])
        #expect(lines.map(\.headsign) == ["Dommeldange", "Strassen, Primeurs", "Hollerich, P+R Bouillon"])
        #expect(lines.allSatisfy { $0.providerRefs["stop"] == "200405036" })
        #expect(Set(lines.map(\.id)).count == 3)
    }

    /// No `directionFlag` (some servers): the destination tells the directions apart instead.
    @Test func withoutADirectionFlagTheDestinationSplitsLines() throws {
        let board = try Self.decode(HafasProvider.DTO.Board.self, Self.board([
            Self.departure(line: "29", lineId: "X_29", flag: nil, direction: "Hesperange", time: "14:57:00"),
            Self.departure(line: "29", lineId: "X_29", flag: nil, direction: "Cessange", time: "14:58:00"),
        ]))
        #expect(HafasProvider.lines(from: board.Departure ?? [], at: "1").count == 2)
    }

    /// "Bus 29" when the product has no `line` of its own.
    @Test func aLineIsNamedWithoutItsCategory() throws {
        let visit = try Self.decode(HafasProvider.DTO.Visit.self, #"{"name":"Bus 29","ProductAtStop":{"name":"Bus 29"}}"#)
        #expect(visit.lineName == "29")
    }

    /// A loop runs both ways to one destination; each is told apart by its next stop.
    @Test func loopLinesAreToldApartByTheirNextStop() async throws {
        let stops = { (second: String) in
            #","Stops":{"Stop":[{"extId":"300526006","name":"Frankfurt (Oder), Bahnhof","lat":52.33,"lon":14.54},"#
                + #"{"extId":"9\#(second.count)","name":"\#(second)","lat":52.34,"lon":14.55}]}"#
        }
        let departures = [
            ("1", "300526007", "Frankfurt (Oder), Lenné-Passage"),
            ("2", "300526006", "Frankfurt (Oder), Europa-Universität"),
        ]
        let plain = departures.map { Self.departure(line: "980", lineId: "VBB|Bus|980", flag: $0.0,
                                                    direction: "Frankfurt (Oder), Kopernikusstr.", time: "16:20:00",
                                                    platform: $0.1) }
        let full = departures.map { Self.departure(line: "980", lineId: "VBB|Bus|980", flag: $0.0,
                                                   direction: "Frankfurt (Oder), Kopernikusstr.", time: "16:20:00",
                                                   platform: "300526006", extra: stops($0.2)) }
        let provider = Self.provider(.vbb, replies: [
            "departureBoard": (200, Self.board(plain)),
            "departureBoard+passlist": (200, Self.board(full)),
        ])
        let lines = try await provider.lines(atStop: Self.gare)
        #expect(Set(lines.compactMap(\.headsign)) == [
            "Frankfurt (Oder), Kopernikusstr. via Frankfurt (Oder), Lenné-Passage",
            "Frankfurt (Oder), Kopernikusstr. via Frankfurt (Oder), Europa-Universität",
        ])
    }

    /// Late at night a board has no `Departure` at all: no lines, not an error.
    @Test func anEmptyBoardIsNoLinesNotAnError() async throws {
        let provider = Self.provider(.luxembourg, replies: ["departureBoard": (200, #"{"serverVersion":"2.52"}"#)])
        #expect(try await provider.lines(atStop: Self.gare).isEmpty)
        let line = TransitLine(id: "X_22|1", shortName: "22", providerRefs: ["stop": Self.gare.code])
        #expect(try await provider.arrivals(for: line, at: Self.gare).isEmpty)
    }

    /// The board asks only for buses and trams, as JSON, over the same horizon for lines and times.
    @Test func boardsAskForSurfaceProductsOverOneHorizon() async throws {
        let provider = Self.provider(.luxembourg, replies: ["departureBoard": (200, #"{}"#)])
        _ = try await provider.lines(atStop: Self.gare)
        _ = try await provider.arrivals(for: TransitLine(id: "x", shortName: "x"), at: Self.gare)
        let queries = HafasStub.requested.map { Dictionary(uniqueKeysWithValues: (URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                                                    .queryItems ?? []).map { ($0.name, $0.value ?? "") }) }
        #expect(queries.count == 2)
        for query in queries {
            #expect(query["products"] == "288")
            #expect(query["format"] == "json")
            #expect(query["id"] == "200405036")
            #expect(query["duration"] == String(HafasProvider.horizonMinutes))
        }
    }

    // MARK: - Arrivals

    /// The prognosis when there is one, the plan otherwise; only this line and direction; nothing
    /// cancelled; soonest first.
    @Test func arrivalsReadThePrognosisAndKeepToTheLine() async throws {
        let now = Date()
        let clock = { (minutes: Double) -> (String, String) in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Europe/Luxembourg")
            formatter.dateFormat = "yyyy-MM-dd"
            let date = now.addingTimeInterval(minutes * 60)
            let day = formatter.string(from: date)
            formatter.dateFormat = "HH:mm:00"
            return (day, formatter.string(from: date))
        }
        let (d1, t1) = clock(20), (d2, t2) = clock(5), (rd2, rt2) = clock(8), (d3, t3) = clock(12), (d4, t4) = clock(3)
        let provider = Self.provider(.luxembourg, replies: ["departureBoard": (200, Self.board([
            Self.departure(line: "22", lineId: "X_22", flag: "1", direction: "Strassen", time: t1, date: d1),
            Self.departure(line: "22", lineId: "X_22", flag: "1", direction: "Strassen", time: t2, date: d2,
                           extra: #","rtDate":"\#(rd2)","rtTime":"\#(rt2)""#),
            Self.departure(line: "22", lineId: "X_22", flag: "1", direction: "Strassen", time: t3, date: d3,
                           extra: #","cancelled":true"#),
            Self.departure(line: "22", lineId: "X_22", flag: "2", direction: "Hollerich", time: t4, date: d4),
            Self.departure(line: "4", lineId: "X_4", flag: "1", direction: "Strassen", time: t4, date: d4),
        ]))])
        let line = TransitLine(id: "X_22|1", shortName: "22", providerRefs: ["stop": Self.gare.code])
        let arrivals = try await provider.arrivals(for: line, at: Self.gare)
        #expect(arrivals.count == 2)
        #expect(arrivals.map(\.isRealtime) == [true, false])
        let first = try #require(arrivals.first)
        #expect(abs(first.expectedAt.timeIntervalSince(now) - 8 * 60) < 61)
        #expect(abs((first.delay ?? 0) - 3 * 60) < 1)
    }

    /// A trip planned for 23:58 that runs five minutes late leaves at 00:03 the next day.
    @Test func aPrognosisPastMidnightLandsOnTheNextDay() throws {
        let zone = TimeZone(identifier: "Europe/Berlin")!
        let planned = try #require(HafasProvider.date("2026-10-01", "23:58:00", in: zone))
        let expected = try #require(HafasProvider.date("2026-10-02", "00:03:00", in: zone))
        #expect(expected.timeIntervalSince(planned) == 5 * 60)
        #expect(HafasProvider.date("2026-10-01", nil, in: zone) == nil)
        // Berlin is UTC+2 in October.
        #expect(planned == Date(timeIntervalSince1970: 1_790_891_880))
    }

    /// HAFAS refuses with a JSON `errorCode` and a 4xx; the body travels with the error.
    @Test func aRefusalCarriesItsBody() async throws {
        let provider = Self.provider(.luxembourg, replies: ["departureBoard": (400,
            #"{"errorCode":"API_AUTH","errorText":"access denied for accessId"}"#)])
        let error = await #expect(throws: ResponseError.self) { try await provider.lines(atStop: Self.gare) }
        #expect(error?.status == 400)
        #expect(error?.body.contains("API_AUTH") == true)
    }

    // MARK: - Patterns

    private static func tripStops(_ stops: [(extId: String, mast: String?)]) throws -> [HafasProvider.DTO.TripStop] {
        let json = stops.map { stop in
            #"{"extId":"\#(stop.extId)","name":"S\#(stop.extId)","lat":49.6,"lon":6.1\#(stop.mast.map { #","mainMastExtId":"\#($0)""# } ?? "")}"#
        }
        return try decode([HafasProvider.DTO.TripStop].self, "[\(json.joined(separator: ","))]")
    }

    /// The rider's platform becomes the rider's station; other stops go by their station.
    @Test func thePatternFindsTheRidersStop() throws {
        let trip = try Self.tripStops([("p1", "m1"), ("p2", "m2"), ("p3", "m3")])
        let stops = HafasProvider.patternStops(trip, boardingPlatform: "p2", riderStop: "m2-rider")
        #expect(stops.map(\.stop.code) == ["m1", "m2-rider", "m3"])
        #expect(stops.map(\.sequence) == [1, 2, 3])
    }

    /// Luxembourg's line 115 goes out from Ettelbruck and back through it: the rider's station is in
    /// the pattern once, where they board.
    @Test func anOutAndBackTripHasTheRidersStopOnce() throws {
        let trip = try Self.tripStops([("p1", "ETT"), ("p2", "ERP"), ("p3", "DIE"), ("p4", "ERP"), ("p5", "ETT"), ("p6", "ING")])
        let codes = HafasProvider.patternStops(trip, boardingPlatform: "p1", riderStop: "ETT").map(\.stop.code)
        #expect(codes.filter { $0 == "ETT" }.count == 1)
        #expect(codes.first == "ETT")
        #expect(codes.contains("p5"))
    }

    /// VBB's trips name platforms only: a loop back to the boarding platform keeps it once.
    @Test func aLoopBackToTheBoardingPlatformHasItOnce() throws {
        let trip = try Self.tripStops([("A", nil), ("B", nil), ("C", nil), ("A", nil)])
        let codes = HafasProvider.patternStops(trip, boardingPlatform: "A", riderStop: "900100003").map(\.stop.code)
        #expect(codes == ["900100003", "B", "C", "A"])
    }

    /// A trip lists one stop twice in a row when it waits there; that is one stop.
    @Test func aStopListedTwiceInARowIsOne() throws {
        let trip = try Self.tripStops([("p1", "m1"), ("p2", "m2"), ("p2b", "m2"), ("p3", "m3")])
        #expect(HafasProvider.patternStops(trip, boardingPlatform: "p1", riderStop: "m1").count == 3)
    }

    /// VBB: the whole trip from `journeyDetail`, asked for by the departure's own reference.
    @Test func vbbPatternsComeFromJourneyDetail() async throws {
        let provider = Self.provider(.vbb, replies: [
            "departureBoard": (200, Self.board([
                Self.departure(line: "200", lineId: "VBB|Bus|200", flag: "1", direction: "Michelangelostr.", time: "16:20:00",
                               platform: "300304047"),
            ])),
            "journeyDetail": (200, #"""
                {"Stops":{"Stop":[{"extId":"302414003","name":"Hertzallee (Berlin)","lat":52.50,"lon":13.33},
                  {"extId":"300304047","name":"S+U Alexanderplatz (Berlin)","lat":52.52,"lon":13.41},
                  {"extId":"300100777","name":"Michelangelostr. (Berlin)","lat":52.55,"lon":13.45}]}}
                """#),
        ])
        let line = TransitLine(id: "VBB|Bus|200|1", shortName: "200", headsign: "Michelangelostr.",
                               providerRefs: ["stop": "900100003"])
        let pattern = try await provider.routePattern(for: line)
        #expect(pattern.stops.map(\.stop.code) == ["302414003", "900100003", "300100777"])
        let detail = try #require(HafasStub.requested.first { $0.lastPathComponent == "journeyDetail" })
        #expect(detail.query?.contains("id=1%7C200%7C16:20:00") == true)
    }

    private static func passlist(_ stops: [(extId: String, mast: String)]) -> String {
        let list = stops.map { #"{"extId":"\#($0.extId)","name":"S\#($0.mast)","lat":49.6,"lon":6.1,"mainMastExtId":"\#($0.mast)"}"# }
        return #","Stops":{"Stop":[\#(list.joined(separator: ","))]}"#
    }

    /// Luxembourg has no `journeyDetail`: the stops before the rider's come from a board where the
    /// line starts, the end of a trip the other way. Without them the board's map would be empty.
    @Test func luxembourgPatternsReachBackToWhereTheLineStarts() async throws {
        let here = Self.board([
            Self.departure(line: "18", lineId: "X_18", flag: "1", direction: "Kirchberg", time: "16:20:00",
                           platform: "p-ham", extra: Self.passlist([("p-ham", "HAM"), ("p-k1", "K1"), ("p-kir", "KIR")])),
            Self.departure(line: "18", lineId: "X_18", flag: "2", direction: "Kockelscheuer", time: "16:22:00",
                           platform: "p-ham2", extra: Self.passlist([("p-ham2", "HAM"), ("p-c1", "C1"), ("p-koc", "KOC")])),
        ])
        let atStart = Self.board([
            Self.departure(line: "18", lineId: "X_18", flag: "1", direction: "Kirchberg", time: "16:05:00", platform: "p-koc",
                           extra: Self.passlist([("p-koc", "KOC"), ("p-c1b", "C1"), ("p-ham", "HAM"), ("p-k1", "K1"), ("p-kir", "KIR")])),
        ])
        let provider = Self.provider(.luxembourg, replies: [
            "departureBoard+passlist@HAM": (200, here),
            "departureBoard+passlist@KOC": (200, atStart),
        ])
        let line = TransitLine(id: "X_18|1", shortName: "18", providerRefs: ["stop": "HAM"])
        let pattern = try await provider.routePattern(for: line)
        #expect(pattern.stops.map(\.stop.code) == ["KOC", "C1", "HAM", "K1", "KIR"])
    }

    /// A diversion past a line's first stop cancels every trip there, but each still traces the
    /// route: a running trip is preferred, a cancelled one is still drawn.
    @Test func aTripCancelledAtItsFirstStopStillTracesTheRoute() throws {
        let board = try Self.decode(HafasProvider.DTO.Board.self, Self.board([
            Self.departure(line: "4", lineId: "X_4", flag: "1", direction: "Dommeldange", time: "16:10:00",
                           extra: #","cancelled":true"# + Self.passlist([("a", "LEU"), ("b", "HAM"), ("c", "DOM")])),
        ]))
        let trip = try #require(HafasProvider.tripCalling(at: "HAM", of: "X_4|1", in: board.Departure ?? []))
        #expect(trip.map(\.mainMastExtId) == ["LEU", "HAM", "DOM"])
        #expect(HafasProvider.tripCalling(at: "ELSEWHERE", of: "X_4|1", in: board.Departure ?? []) == nil)
    }

    /// Luxembourg has no `journeyDetail`: with nothing the other way, the board's onward stops,
    /// and never a call that 404s.
    @Test func luxembourgPatternsComeFromThePasslist() async throws {
        let provider = Self.provider(.luxembourg, replies: [
            "departureBoard+passlist": (200, Self.board([
                Self.departure(line: "22", lineId: "X_22", flag: "1", direction: "Strassen", time: "16:20:00",
                               platform: "300034009", extra: #"""
                    ,"Stops":{"Stop":[{"extId":"300034009","name":"Gare","lat":49.59,"lon":6.13,"mainMastExtId":"200405036"},
                      {"extId":"300339001","name":"Bonnevoie","lat":49.60,"lon":6.14,"mainMastExtId":"200404008"}]}
                    """#),
            ])),
        ])
        let line = TransitLine(id: "X_22|1", shortName: "22", providerRefs: ["stop": Self.gare.code])
        let pattern = try await provider.routePattern(for: line)
        #expect(pattern.stops.map(\.stop.code) == ["200405036", "200404008"])
        #expect(!HafasStub.requested.contains { $0.lastPathComponent == "journeyDetail" })
    }

    // MARK: - Registration

    @Test func luxembourgAndVBBShip() {
        #expect(SupportedRegions.region(containing: GeoPoint(lat: 49.6116, lon: 6.1319))?.providerID == "mobiliteit-lu")
        #expect(TransitProviders.all.contains { $0.id == "mobiliteit-lu" })
        // Alexanderplatz, and Potsdam in Brandenburg.
        #expect(SupportedRegions.region(containing: GeoPoint(lat: 52.5219, lon: 13.4132))?.providerID == "vbb")
        #expect(SupportedRegions.region(containing: GeoPoint(lat: 52.3906, lon: 13.0645))?.providerID == "vbb")
        #expect(TransitProviders.all.contains { $0.id == "vbb" })
        #expect(HafasProvider(.luxembourg).attribution?.contains("CC BY 4.0") == true)
        #expect(HafasProvider(.vbb).attribution?.contains("VBB") == true)
    }
}
