import Testing
import Foundation
@testable import BusBus

/// Answers every request with one canned JSON body.
private final class CannedResponse: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var lastURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastURL = request.url
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct BusGovILProviderTests {
    private static func provider(answering json: String, status: Int = 200) -> BusGovILProvider {
        CannedResponse.body = Data(json.utf8)
        CannedResponse.status = status
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedResponse.self]
        var provider = BusGovILProvider()
        provider.http = HTTPClient(session: URLSession(configuration: configuration))
        return provider
    }

    private static let line = TransitLine(id: "15041", shortName: "110", headsign: nil, agency: nil, origin: nil,
                                          destination: nil, isAccessible: nil, providerRefs: ["routeDesc": "13110-2-#"])
    private static let stop = TransitStop(code: "41122", name: "Allenby G", city: nil,
                                          location: GeoPoint(lat: 32.827, lon: 34.975), address: nil)

    /// Late at night and on Shabbat the calendar answers `null` for the stop. That is an empty
    /// board, not a broken feed; decoding it as one put Israel on the service-down screen.
    @Test func aStopWithNoDeparturesLeftIsEmptyNotAnError() async throws {
        let provider = Self.provider(answering: #"{"data":{"41122":null},"success":true,"message":"","duration":null}"#)
        let arrivals = try await provider.arrivals(for: Self.line, at: Self.stop)
        #expect(arrivals.isEmpty)
    }

    @Test func departuresAreRead() async throws {
        let provider = Self.provider(answering: #"""
            {"data":{"41122":{"stopTimes":[{"staticTripId":"t1","minutesToArrival":4,"isRealTime":true}]}},"success":true}
            """#)
        let arrivals = try await provider.arrivals(for: Self.line, at: Self.stop)
        #expect(arrivals.count == 1)
        #expect(arrivals.first?.isRealtime == true)
        #expect(arrivals.first?.tripId == "t1")
    }

    /// A failed reply keeps its status, URL and body, so Crashlytics shows what the server said.
    @Test func aFailedReplyCarriesItsBody() async throws {
        let provider = Self.provider(answering: "<html>הרשות הארצית לתחבורה ציבורית</html>", status: 503)
        let error = await #expect(throws: ResponseError.self) {
            try await provider.arrivals(for: Self.line, at: Self.stop)
        }
        #expect(error?.status == 503)
        #expect(error?.body.contains("הרשות הארצית") == true)
        #expect(error?.url.contains("GetRouteCalendarAtStopsByStopCodes") == true)
    }

    @Test func anUndecodableReplyCarriesItsBody() async throws {
        let provider = Self.provider(answering: #"{"data":{"41122":{"stopTimes":"nope"}}}"#)
        let error = await #expect(throws: ResponseError.self) {
            try await provider.arrivals(for: Self.line, at: Self.stop)
        }
        #expect(error?.reason.hasPrefix("decoding /Calendar/GetRouteCalendarAtStopsByStopCodes") == true)
        #expect(error?.body.contains("nope") == true)
    }

    /// Each language path only matches names written in that language: אלנבי finds nothing on the
    /// English path and Allenby nothing on the Hebrew one. So the query's letters pick the path.
    @Test(.appLanguage("en")) func hebrewIsSearchedInHebrewWhateverTheAppLanguage() async throws {
        let provider = Self.provider(answering: #"{"data":[],"success":true}"#)
        _ = try await provider.searchStops(query: "אלנבי")
        #expect(CannedResponse.lastURL?.path.contains("/route-planner-prod/api/he/") == true)
    }

    @Test(.appLanguage("he")) func latinIsSearchedInEnglishWhateverTheAppLanguage() async throws {
        let provider = Self.provider(answering: #"{"data":[],"success":true}"#)
        _ = try await provider.searchStops(query: "Allenby")
        #expect(CannedResponse.lastURL?.path.contains("/route-planner-prod/api/en/") == true)
    }

    @Test(.appLanguage("en")) func arabicIsSearchedInArabicWhateverTheAppLanguage() async throws {
        let provider = Self.provider(answering: #"{"data":[],"success":true}"#)
        _ = try await provider.searchStops(query: "اللنبي")
        #expect(CannedResponse.lastURL?.path.contains("/route-planner-prod/api/ar/") == true)
    }

    @Test(.appLanguage("ar")) func aQueryWithNoLettersIsSearchedInTheAppLanguage() async throws {
        let provider = Self.provider(answering: #"{"data":[],"success":true}"#)
        _ = try? await provider.searchStops(query: "41122")
        #expect(CannedResponse.lastURL?.path.contains("/api/ar/") == true)
    }
}
