import Testing
import Foundation
@testable import BusBus

/// Answers by the request's path with canned MOTIS JSON, and keeps every URL asked for.
private final class TransitousStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [String: String] = [:]
    nonisolated(unsafe) static var requested: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requested.append(url)
        let body = Self.replies[url.path]
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct TransitousProviderTests {
    static func provider(_ replies: [String: String]) -> TransitousProvider {
        TransitousStub.replies = replies
        TransitousStub.requested = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransitousStub.self]
        var provider = TransitousProvider()
        provider.session = URLSession(configuration: configuration)
        return provider
    }

    static func place(_ id: String, _ lat: Double, departure: String? = nil) -> String {
        let time = departure.map { #","departure":"\#($0)""# } ?? ""
        return #"{"name":"Stop \#(id)","stopId":"\#(id)","lat":\#(lat),"lon":8.54\#(time)}"#
    }

    /// The next departure of tram 4 from `stop`, on trip `T4`.
    static func departures(at stop: String) -> String {
        #"""
        {"stopTimes":[{"place":\#(place(stop, 47.37, departure: "2026-10-19T07:50:00Z")),"realTime":false,"headsign":"Rehalp",
                       "routeId":"r4","directionId":"0","tripId":"T4","routeShortName":"4"}]}
        """#
    }

    /// Zürich's tram 4 runs on from a tram 13 (stay seated). Unjoined, the trip comes as two legs;
    /// the pattern is tram 4's alone, from the stop where the 13 hands over.
    @Test func anInterlinedTripKeepsOnlyItsOwnLeg() async throws {
        let provider = Self.provider([
            "/api/v6/stoptimes": Self.departures(at: "HB-1"),
            "/api/v6/trip": #"""
                {"legs":[
                  {"tripId":"T13","from":\#(Self.place("ALB", 47.36)),"intermediateStops":[\#(Self.place("X", 47.365))],
                   "to":\#(Self.place("HB-1", 47.37, departure: "2026-10-19T07:50:00Z"))},
                  {"tripId":"T4","from":\#(Self.place("HB-1", 47.37, departure: "2026-10-19T07:50:00Z")),
                   "intermediateStops":[\#(Self.place("Y", 47.36))],"to":\#(Self.place("REH", 47.355))}
                ]}
                """#,
        ])
        let line = TransitLine(id: "r4|0", shortName: "4", providerRefs: ["routeId": "r4", "stopId": "HB-1"])
        let pattern = try await provider.routePattern(for: line)
        #expect(pattern.stops.map(\.stop.code) == ["HB-1", "Y", "REH"])
        let trip = try #require(TransitousStub.requested.last)
        #expect(trip.query?.contains("joinInterlinedLegs=false") == true)
    }

    /// Without trip ids, the leg is the one leaving from the rider's stop: the 13's leg ends there.
    @Test func withoutTripIDsTheLegLeavingTheStopIsTaken() async throws {
        let provider = Self.provider([
            "/api/v6/stoptimes": Self.departures(at: "HB-1"),
            "/api/v6/trip": #"""
                {"legs":[
                  {"from":\#(Self.place("ALB", 47.36)),"intermediateStops":[\#(Self.place("X", 47.365))],
                   "to":\#(Self.place("HB-1", 47.37, departure: "2026-10-19T07:50:00Z"))},
                  {"from":\#(Self.place("HB-1", 47.37, departure: "2026-10-19T07:50:00Z")),
                   "intermediateStops":[\#(Self.place("Y", 47.36))],"to":\#(Self.place("REH", 47.355))}
                ]}
                """#,
        ])
        let line = TransitLine(id: "r4|0", shortName: "4", providerRefs: ["routeId": "r4", "stopId": "HB-1"])
        let pattern = try await provider.routePattern(for: line)
        #expect(pattern.stops.map(\.stop.code) == ["HB-1", "Y", "REH"])
    }
}
