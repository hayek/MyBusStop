import Testing
import Foundation
@testable import BusBus

/// The rider's coordinates never reach a log, Crashlytics or a cache: every provider's nearby URL
/// is masked wherever it is written down, and its reply is never kept.
struct LocationRedactionTests {

    /// Every shape a nearby request takes, one per provider family, with the rider at 32.08712,34.78123.
    nonisolated static let nearbyURLs = [
        "https://open-bus-stride-api.hasadna.org.il/stops?lat=32.08712&lng=34.78123&radius=500", // bus.gov.il
        "https://api.pugetsound.onebusaway.org/api/where/stops-for-location.json?key=abc&lat=32.08712&lon=34.78123", // OBA
        "https://api.tfl.gov.uk/StopPoint?lat=32.08712&lon=34.78123&radius=500&modes=bus", // TfL, Toei
        "https://www.mvg.de/api/fib/v2/stations/nearby?latitude=32.08712&longitude=34.78123", // MVG
        "https://api-v3.mbta.com/stops?filter%5Blatitude%5D=32.08712&filter%5Blongitude%5D=34.78123", // MBTA
        "https://bustimes.org/stops.json?xmax=34.79&xmin=34.77123&ymax=32.09123&ymin=32.08212", // bustimes.org
        "https://transport.opendata.ch/v1/locations?type=station&x=32.08712&y=34.78123", // Swiss
        "https://efa.example/XML_COORD_REQUEST?coord=34.781230:32.087120:WGS84%5Bdd.ddddd%5D&max=20", // EFA
        "https://data.itsfactory.fi/journeys/api/1/stop-points?location=32.08,34.77:32.09,34.79", // Tampere
        "https://fahrinfo.vbb.de/restproxy/latest/location.nearbystops?originCoordLat=32.08712&originCoordLong=34.78123&r=500", // HAFAS
        "https://api.transitous.org/api/v6/map/stops?max=32.09123,34.79123&min=32.08212,34.77123", // Transitous
        "https://proxy.example/stops/near/32.08712,34.78123", // a coordinate in the path
    ]

    nonisolated private static let coordinates = ["32.08", "34.77", "34.78", "34.79", "32.09"]

    @Test(arguments: nearbyURLs)
    func nearbyURLsAreRedacted(_ string: String) throws {
        let url = try #require(URL(string: string))
        #expect(HTTPClient.carriesLocation(url))
        let redacted = HTTPClient.redacted(url)
        for coordinate in Self.coordinates {
            #expect(!redacted.contains(coordinate), "\(redacted)")
        }
        #expect(redacted.contains("LOCATION"))
    }

    @Test func keysAreStillMaskedAndOrdinaryParametersKept() throws {
        let url = try #require(URL(string: "https://api.example/where/stop.json?key=secret&stopcode=21&lat=32.1234"))
        let redacted = HTTPClient.redacted(url)
        #expect(!redacted.contains("secret"))
        #expect(redacted.contains("stopcode=21"))
        let hafas = try #require(URL(string: "https://fahrinfo.vbb.de/restproxy/latest/departureBoard?id=900100003&accessId=secret"))
        #expect(!HTTPClient.redacted(hafas).contains("secret"))
        #expect(!redacted.contains("32.1234"))
    }

    @Test func requestsThatSayNothingOfTheRiderAreLeftAlone() throws {
        let url = try #require(URL(string: "https://bus.example/Stops/GetStopByCode?stopcode=21472&routeId=11"))
        #expect(!HTTPClient.carriesLocation(url))
        #expect(HTTPClient.redacted(url) == url.absoluteString)
    }

    @Test func aResponseErrorCarriesARedactedURL() throws {
        let url = try #require(URL(string: Self.nearbyURLs[0]))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil))
        let error = ResponseError("HTTP 500 for /stops", Data("oops".utf8), response, URLRequest(url: url))
        #expect(!error.url.contains("32.08712"))
        #expect(!error.url.contains("34.78123"))
    }

    /// A timed-out nearby request is reportable, and a URLError's description quotes its URL whole.
    @Test func aURLErrorDescriptionLosesItsCoordinates() throws {
        let url = try #require(URL(string: Self.nearbyURLs[1]))
        let error = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url,
                                                   NSURLErrorFailingURLStringErrorKey: url.absoluteString])
        #expect(String(describing: error).contains("32.08712"))
        let described = ServiceHealth.describe(error)
        #expect(!described.contains("32.08712"))
        #expect(!described.contains("34.78123"))
        #expect(!described.contains("key=abc"))
        #expect(described.contains("stops-for-location.json"))
    }

    @Test func coordinatesLeftInPlainTextAreMasked() {
        #expect(HTTPClient.redacted(text: "no stops near 32.08712,34.78123 today") == "no stops near LOCATION today")
        #expect(HTTPClient.redacted(text: "HTTP 500 for /Stops/GetStopByCode") == "HTTP 500 for /Stops/GetStopByCode")
    }
}

/// A reply the tests hand back, marked as cacheable so only the session's own settings keep it out.
private final class CacheableReply: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json",
                                                      "Cache-Control": "max-age=600"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct LocationCachingTests {

    private static func session(cache: URLCache) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CacheableReply.self]
        configuration.urlCache = cache
        configuration.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: configuration)
    }

    @Test func aNearbyReplyIsNeverCached() async throws {
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
        let session = Self.session(cache: cache)
        let url = try #require(URL(string: LocationRedactionTests.nearbyURLs[0]))
        _ = try await HTTPClient.data(for: URLRequest(url: url), on: session)
        try await Task.sleep(for: .milliseconds(300))
        #expect(cache.cachedResponse(for: URLRequest(url: url)) == nil)
    }

    @Test func theSessionPassedInIsLeftAsItWas() throws {
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
        let session = Self.session(cache: cache)
        let uncached = HTTPClient.withoutCache(session.configuration)
        #expect(uncached.urlCache == nil)
        #expect(uncached.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(session.configuration.urlCache === cache)
        #expect(HTTPClient.uncachedSession.configuration.urlCache == nil)
    }

    @Test func repliesCachedByEarlierBuildsAreEmptiedOnce() throws {
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
        let defaults = try #require(UserDefaults(suiteName: "url-cache-\(UUID().uuidString)"))
        let url = try #require(URL(string: LocationRedactionTests.nearbyURLs[0]))
        let stored = CachedURLResponse(response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                                 headerFields: nil)!, data: Data("[]".utf8))
        cache.storeCachedResponse(stored, for: URLRequest(url: url))
        #expect(cache.cachedResponse(for: URLRequest(url: url)) != nil)

        HTTPClient.purgeCachedLocationRepliesOnce(cache: cache, defaults: defaults)
        #expect(cache.cachedResponse(for: URLRequest(url: url)) == nil)

        // Once only: the app's later replies are not thrown away on every launch.
        cache.storeCachedResponse(stored, for: URLRequest(url: url))
        HTTPClient.purgeCachedLocationRepliesOnce(cache: cache, defaults: defaults)
        #expect(cache.cachedResponse(for: URLRequest(url: url)) != nil)
    }
}
