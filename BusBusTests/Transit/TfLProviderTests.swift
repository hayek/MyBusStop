import Testing
import Foundation
@testable import BusBus

/// Answers by the request's path with canned TfL JSON, and keeps every URL asked for.
private final class TfLStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [String: String] = [:]
    nonisolated(unsafe) static var requested: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requested.append(url)
        let body = Self.replies.first { url.path.hasPrefix($0.key) }?.value
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct TfLProviderTests {
    private static func provider(_ replies: [String: String]) -> TfLProvider {
        TfLStub.replies = replies
        TfLStub.requested = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TfLStub.self]
        var provider = TfLProvider()
        provider.http = HTTPClient(session: URLSession(configuration: configuration))
        return provider
    }

    private static let line = TransitLine(id: "19:inbound", shortName: "19",
                                          providerRefs: ["lineId": "19", "direction": "inbound", "naptanId": "A"])

    private static func point(_ id: String, _ lat: Double) -> String {
        #"{"id":"\#(id)","name":"Stop \#(id)","lat":\#(lat),"lon":-0.1}"#
    }

    /// 19 inbound during the Highbury Grove works: the running route (the diversion) lists stops
    /// that `stopPointSequences` leaves out. They are fetched in one call, not dropped, and once.
    @Test func aRoutesStopsMissingFromTheSequenceAreLookedUp() async throws {
        let provider = Self.provider([
            "/Line/19/Route/Sequence/inbound": #"""
                {"stopPointSequences":[{"stopPoint":[\#(Self.point("A", 51.50)),\#(Self.point("B", 51.51)),\#(Self.point("D", 51.53))]}],
                 "orderedLineRoutes":[{"naptanIds":["A","B","C","D"]},{"naptanIds":["A","B","D"]}]}
                """#,
            "/StopPoint/C": #"""
                {"naptanId":"490G0C","commonName":"Hub","stopType":"NaptanOnstreetBusCoachStopCluster","lat":51.52,"lon":-0.1,
                 "children":[{"naptanId":"C","commonName":"Holloway Road","stopLetter":"SU","stopType":"NaptanPublicBusCoachTram",
                              "modes":["bus"],"lat":51.52,"lon":-0.1}]}
                """#,
        ])
        let pattern = try await provider.routePattern(for: Self.line)
        #expect(pattern.stops.map(\.stop.code) == ["A", "B", "C", "D"])
        #expect(pattern.stops[2].stop.name == "Holloway Road (Stop SU)")
        #expect(TfLStub.requested.count == 2)

        // Asked again (the line card, tomorrow's refresh), the stops come from the session.
        #expect(try await provider.routePattern(for: Self.line).stops.count == 4)
        #expect(TfLStub.requested.count == 3)
    }

    /// When every stop is in the sequence, the pattern costs its one call.
    @Test func aCompleteRouteCostsOneCall() async throws {
        let provider = Self.provider([
            "/Line/19/Route/Sequence/inbound": #"""
                {"stopPointSequences":[{"stopPoint":[\#(Self.point("A", 51.50)),\#(Self.point("B", 51.51))]}],
                 "orderedLineRoutes":[{"naptanIds":["A","B"]}]}
                """#,
        ])
        let pattern = try await provider.routePattern(for: Self.line)
        #expect(pattern.stops.map(\.stop.code) == ["A", "B"])
        #expect(TfLStub.requested.count == 1)
    }
}
