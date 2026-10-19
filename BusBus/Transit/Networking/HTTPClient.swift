import Foundation
import os

nonisolated struct HTTPClient: Sendable {
    var session: URLSession = .shared
    var timeout: TimeInterval = 30
    /// Sent with every request, over the system's defaults (e.g. a fixed `Accept-Language`).
    var headers: [String: String] = [:]

    private static let log = Logger(subsystem: "com.hayek.BusBus", category: "http")

    func get<T: Decodable>(_ type: T.Type, _ base: String, _ path: String, query: [String: String] = [:]) async throws -> T {
        guard var components = URLComponents(string: base + path) else {
            throw TransitError.badResponse("invalid URL \(base + path)")
        }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents leaves "+" alone, which servers read as a space ("MTA NYCT_M86+").
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw TransitError.badResponse("invalid URL \(base + path)") }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        // Our proxy only: a token is a credential, and no other host ever sees one.
        if let token = await TransitProxy.appCheckToken(for: url) {
            request.setValue(token, forHTTPHeaderField: "X-Firebase-AppCheck")
        }

        let started = ContinuousClock.now
        let (data, response) = try await Self.data(for: request, on: session)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        Self.log.debug("GET \(Self.redacted(components), privacy: .public) → \(status) \(data.count)B in \(ContinuousClock.now - started)")

        try Self.check(data, response, request, path)
        return try Self.decode(T.self, data, response, request, path)
    }

    /// Throws a `ResponseError` carrying the body unless the status is 2xx. Every provider's own
    /// networking goes through here too, so any failed reply reaches Crashlytics with what was said.
    static func check(_ data: Data, _ response: URLResponse, _ request: URLRequest, _ what: String) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw ResponseError("HTTP \(status) for \(what)", data, response, request)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data, _ response: URLResponse, _ request: URLRequest,
                                     _ what: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ResponseError("decoding \(what): \(error)", data, response, request)
        }
    }

    // MARK: Where the rider is

    /// Sends a request on `session`, unless its URL says where the rider is: then on a copy of it with
    /// no cache at all, so the reply (and the URL it is filed under) is never written to disk. The
    /// welcome story promises a rider their location is never stored.
    static func data(for request: URLRequest, on session: URLSession) async throws -> (Data, URLResponse) {
        guard carriesLocation(request.url) else { return try await session.data(for: request) }
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if session === URLSession.shared { return try await uncachedSession.data(for: request) }
        // Any other session (a test's canned replies, say) keeps its configuration, minus the cache.
        let uncached = URLSession(configuration: withoutCache(session.configuration))
        defer { uncached.finishTasksAndInvalidate() }
        return try await uncached.data(for: request)
    }

    /// The shared session's stand-in for requests that carry the rider's location.
    static let uncachedSession = URLSession(configuration: withoutCache(.default))

    static func withoutCache(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        // `configuration` getters hand back copies, so this never changes the session it came from.
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// Earlier builds sent nearby requests through the shared session, whose disk cache may still
    /// hold replies filed under URLs with the rider's coordinates in them. URLCache cannot be searched
    /// by URL, and nothing relies on it (the app keeps its own cache), so it is emptied, once.
    static func purgeCachedLocationRepliesOnce(cache: URLCache = .shared, defaults: UserDefaults = .standard) {
        let done = "privacy.urlCachePurged"
        guard !defaults.bool(forKey: done) else { return }
        cache.removeAllCachedResponses()
        defaults.set(true, forKey: done)
    }

    /// Query parameters that hold a coordinate, across every provider's nearby request: `lat`/`lon`
    /// (OneBusAway, TfL, Toei), `lng` (bus.gov.il), `latitude`/`longitude` (MVG, MBTA's `filter[…]`),
    /// the box edges `xmin`…`ymax` (bustimes.org), `x`/`y` (transport.opendata.ch), `coord` (EFA),
    /// `location` (Tampere) and `originCoordLat`/`originCoordLong` (HAFAS). Names are compared
    /// lowercased. Transitous's `min`/`max` corners are caught by their value instead.
    static let locationParameters: Set<String> = [
        "lat", "lon", "lng", "latitude", "longitude", "filter[latitude]", "filter[longitude]",
        "x", "y", "xmin", "xmax", "ymin", "ymax", "coord", "location", "origincoordlat", "origincoordlong",
    ]

    /// Two decimal numbers joined the way coordinates are written, "32.0871,34.7812" or EFA's
    /// "34.78120:32.08710": wherever it turns up, in a query value or a path segment, it is a place.
    private static let coordinatePair = /-?\d{1,3}\.\d+\s*(?:,|:|%2[Cc]|%3[Aa])\s*-?\d{1,3}\.\d+/

    /// Whether a request says where the rider is, and so must be kept out of caches and logs.
    static func carriesLocation(_ url: URL?) -> Bool {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.path.contains(coordinatePair)
            || (components.queryItems ?? []).contains(where: isLocation)
    }

    private static func isLocation(_ item: URLQueryItem) -> Bool {
        locationParameters.contains(item.name.lowercased()) || (item.value?.contains(coordinatePair) ?? false)
    }

    // MARK: Logging a URL

    /// Query parameters that carry an API key, masked wherever a URL is logged.
    static let secretParameters: Set<String> = ["key", "api_key", "apikey", "appid", "token", "accountkey", "accessid"]

    /// A URL as it may be logged or sent to Crashlytics: API keys and the rider's location masked.
    static func redacted(_ url: URL?) -> String {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "<url>" }
        return redacted(components)
    }

    static func redacted(_ components: URLComponents) -> String {
        var components = components
        components.queryItems = components.queryItems?.map {
            if secretParameters.contains($0.name.lowercased()) { return URLQueryItem(name: $0.name, value: "REDACTED") }
            if isLocation($0) { return URLQueryItem(name: $0.name, value: "LOCATION") }
            return $0
        }
        components.percentEncodedPath = components.percentEncodedPath.replacing(coordinatePair, with: "LOCATION")
        return components.string ?? "<url>"
    }

    /// Error text with every URL in it redacted, and any coordinates left over masked: a URLError's
    /// description quotes the whole failing URL, query and all.
    static func redacted(text: String) -> String {
        text.replacing(/https?:\/\/[^\s"'<>{}]+/) { match in
            // A description runs straight on after the URL: "…&lon=34.78, NSErrorFailingURLStringKey=…".
            var found = Substring(match.output)
            var trailing = ""
            while let last = found.last, ",;.)".contains(last) { trailing = String(last) + trailing; found = found.dropLast() }
            return (URL(string: String(found)).map { redacted($0) } ?? "<url>") + trailing
        }
        .replacing(coordinatePair, with: "LOCATION")
    }
}

/// A reply a provider could not use, with the reply itself: the status, the (key-redacted) URL and
/// the body, so a Crashlytics non-fatal shows exactly what the server said.
nonisolated struct ResponseError: LocalizedError, Hashable, Sendable {
    /// Crashlytics keeps 64 KB of log per report; a bigger body is cut, and says by how much.
    static let bodyLimit = 48_000

    var reason: String
    var url: String
    var status: Int
    var body: String

    var errorDescription: String? { TransitError.badResponse(reason).errorDescription }

    init(reason: String, url: String, status: Int, body: String) {
        (self.reason, self.url, self.status, self.body) = (reason, url, status, body)
    }

    init(_ reason: String, _ data: Data, _ response: URLResponse?, _ request: URLRequest) {
        self.init(reason: reason, url: HTTPClient.redacted(request.url),
                  status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: Self.text(of: data))
    }

    /// A parse error in words, for a reason that has already been read past the HTTP layer.
    static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// The body as text when it is text; protobuf and other binary replies as base64.
    static func text(of data: Data) -> String {
        let kept = data.prefix(bodyLimit)
        var text = String(data: kept, encoding: .utf8) ?? "<\(data.count) bytes, base64> " + kept.base64EncodedString()
        if data.count > kept.count { text += "\n… \(data.count - kept.count) more bytes of \(data.count)" }
        return text
    }
}
