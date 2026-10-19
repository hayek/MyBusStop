import Foundation
import os

/// Everything the board knows that is not a bus's current position.
///
/// Routes, the lines calling at a stop and the stops near a point all come from timetable data that
/// changes rarely, so they are kept on disk and read back before anything is asked of the network.
/// That is what lets the map draw the moment the app opens, or the moment a stop is picked out of
/// history, instead of after a round trip. Only the live positions and arrivals are always fetched.
///
/// If a refresh fails the cached copy is still returned: the board keeps its shape through an
/// outage rather than emptying out.
///
/// Nearby stops are the exception to the disk: their key is where the rider was standing, so they
/// are kept in memory only and never written down. The welcome story promises a rider their
/// location is never stored, and this is where that promise is kept.
actor TransitCache {
    /// Staged screenshots start cold in a folder of their own, so nothing a rider or an earlier
    /// run stored can reach them.
    static let shared = !AppClock.isStaging ? TransitCache() : TransitCache(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("screenshots-\(UUID().uuidString)"))

    /// Routes and the lines at a stop come from a timetable that is published daily at most.
    static let staticDataLifetime: TimeInterval = 24 * 60 * 60
    /// Nearby stops depend on where the rider is, so they go stale as soon as they move.
    static let nearbyLifetime: TimeInterval = 10 * 60
    /// A line's path barely ever moves. It is fetched again when the pattern's stops change, or
    /// when a month-old copy is opened (the old one is drawn meanwhile).
    static let shapeLifetime: TimeInterval = 30 * 24 * 60 * 60
    /// A line with no usable path is asked again after a week: a feed or our own files may have
    /// gained it, but not so soon that opening the card again costs a request each time.
    static let missingShapeLifetime: TimeInterval = 7 * 24 * 60 * 60

    private static let log = Logger(subsystem: "com.hayek.BusBus", category: "cache")
    private let directoryOverride: URL?
    private var memory: [String: (data: Data, storedAt: Date)] = [:]
    /// Actors are re-entrant, so two callers that arrive on a cold key would both reach the
    /// network. The second one waits on the first one's request instead.
    private var inFlight: [String: Task<Data, any Error>] = [:]

    /// - Parameter directory: where the cache lives. Tests pass a temporary one so they start cold;
    ///   the app leaves it nil and uses Application Support.
    init(directory: URL? = nil) {
        self.directoryOverride = directory
    }

    // MARK: What the board asks for

    func pattern(for line: TransitLine, providerID: String,
                 fetch: @escaping @Sendable () async throws -> RoutePattern) async throws -> RoutePattern {
        try await value(RoutePattern.self, key: "pattern/\(providerID)/\(line.id)",
                        lifetime: Self.staticDataLifetime, fetch: fetch)
    }

    /// The pattern through the provider's own call. When that reply also carries the line's
    /// shape, the shape is kept too, so opening the line's card later costs nothing.
    func pattern(for line: TransitLine, provider: any TransitProvider) async throws -> RoutePattern {
        try await pattern(for: line, providerID: provider.datasetID) { [self] in
            let (pattern, shape) = try await provider.routePatternWithShape(for: line)
            // Apple TV has no line card to draw it on.
            #if !os(tvOS)
            if let shape { await keep(await StoredShape.judging(shape, for: pattern, tolerance: provider.shapeTolerance), provider: provider) }
            #endif
            return pattern
        }
    }

    /// The line's path, judged against its stops. A rejected shape is kept as well, with the
    /// reason, and so is an answer that will not change by asking again soon — no path for this
    /// line, a reply that cannot be read, a 4xx — so a line is not asked for on every opening.
    /// What may pass (no connection, a server error, `tryLater`) is thrown and asked again next
    /// time. Throws `TransitError.unsupported` for feeds without shapes; those make no request.
    func shape(for pattern: RoutePattern, provider: any TransitProvider) async throws -> StoredShape {
        let fingerprint = pattern.stopsFingerprint
        return try await value(StoredShape.self, key: Self.shapeKey(pattern.line.id, provider), lifetime: Self.shapeLifetime,
                               accept: { $0.stopsFingerprint == fingerprint && !$0.isStaleRejection }) {
            let shape: RouteShape
            do {
                shape = try await provider.routeShape(for: pattern.line, pattern: pattern)
            } catch where Self.isLasting(error) {
                return StoredShape(rejecting: "\(error.localizedDescription)", for: pattern)
            }
            return await StoredShape.judging(shape, for: pattern, tolerance: provider.shapeTolerance)
        }
    }

    /// The stored path for this pattern, however old, without asking the network; nil when there
    /// is none or it was made for a different stop list.
    func cachedShape(for pattern: RoutePattern, provider: any TransitProvider) -> StoredShape? {
        guard let stored = cached(StoredShape.self, key: Self.shapeKey(pattern.line.id, provider)),
              stored.stopsFingerprint == pattern.stopsFingerprint else { return nil }
        return stored
    }

    private func keep(_ stored: StoredShape, provider: any TransitProvider) {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        store(key: Self.shapeKey(stored.lineID, provider), data: data, persists: true)
    }

    /// An answer that asking again soon would not change. Connection failures, server errors
    /// (5xx, 429) and `tryLater` may pass; anything unknown is assumed to as well.
    static func isLasting(_ error: any Error) -> Bool {
        switch error {
        case TransitError.notFound: return true
        case TransitError.badResponse(let message):
            return !(message.hasPrefix("HTTP 5") || message.hasPrefix("HTTP 429"))
        case let error as ResponseError: return (400..<500).contains(error.status) && error.status != 408 && error.status != 429
        case is DecodingError, is Polyline.DecodingError: return true
        default: return false
        }
    }

    private static func shapeKey(_ lineID: String, _ provider: any TransitProvider) -> String {
        "shape/\(provider.shapeDatasetID)/\(lineID)"
    }

    func lines(atStop stop: TransitStop, providerID: String,
               fetch: @escaping @Sendable () async throws -> [TransitLine]) async throws -> [TransitLine] {
        try await value([TransitLine].self, key: "lines/\(providerID)/\(stop.code)",
                        lifetime: Self.staticDataLifetime, fetch: fetch)
    }

    func nearby(around point: GeoPoint, radiusMeters: Double, providerID: String,
                fetch: @escaping @Sendable () async throws -> [NearbyStop]) async throws -> [NearbyStop] {
        // Rounded to about a hundred metres: walking a few steps should not miss the cache.
        let key = String(format: "nearby/%@/%.3f,%.3f/%.0f", providerID, point.lat, point.lon, radiusMeters)
        return try await value([NearbyStop].self, key: key, lifetime: Self.nearbyLifetime,
                               persists: false, fetch: fetch)
    }

    /// Deletes the nearby lists earlier builds wrote to disk, each named after a place the rider
    /// stood. Once at launch; with none left it does nothing.
    func purgeStoredNearby() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.lastPathComponent.hasPrefix(Self.nearbyFilePrefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// What a nearby key's file name starts with (`fileURL(key:)` turns its slashes into these).
    static let nearbyFilePrefix = "nearby_"

    /// Whatever is already stored, however old, without asking the network. This is what the board
    /// draws from on the first frame.
    func cached<T: Codable & Sendable>(_ type: T.Type, key: String) -> T? {
        guard let entry = memory[key] ?? readFromDisk(key: key) else { return nil }
        memory[key] = entry
        return try? JSONDecoder().decode(type, from: entry.data)
    }

    func cachedPattern(for lineID: String, providerID: String) -> RoutePattern? {
        cached(RoutePattern.self, key: "pattern/\(providerID)/\(lineID)")
    }

    // MARK: The one implementation

    /// - Parameter persists: false keeps the value in memory only: nothing is written to disk, and
    ///   nothing is looked for there.
    /// - Parameter accept: false for a stored value that no longer answers the question however
    ///   fresh it is (a shape made for another stop list); it is neither returned nor served stale.
    private func value<T: Codable & Sendable>(_ type: T.Type, key: String, lifetime: TimeInterval,
                                              persists: Bool = true,
                                              accept: (T) -> Bool = { _ in true },
                                              fetch: @escaping @Sendable () async throws -> T) async throws -> T {
        if let entry = memory[key] ?? (persists ? readFromDisk(key: key) : nil) {
            memory[key] = entry
            if Date().timeIntervalSince(entry.storedAt) < lifetime,
               let decoded = try? JSONDecoder().decode(type, from: entry.data), accept(decoded) {
                return decoded
            }
        }
        if let running = inFlight[key] {
            return try JSONDecoder().decode(type, from: try await running.value)
        }

        let request = Task<Data, any Error> { try JSONEncoder().encode(try await fetch()) }
        inFlight[key] = request
        defer { inFlight[key] = nil }
        do {
            let data = try await request.value
            store(key: key, data: data, persists: persists)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Stale beats blank: an out-of-date route still draws the right shape.
            if let stale = memory[key] ?? (persists ? readFromDisk(key: key) : nil),
               let decoded = try? JSONDecoder().decode(type, from: stale.data), accept(decoded) {
                // A nearby key is where the rider stood: it stays out of the log's public text.
                let what = persists ? key : "nearby"
                Self.log.warning("serving stale \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
                memory[key] = stale
                return decoded
            }
            throw error
        }
    }

    // MARK: Disk

    private struct Entry: Codable {
        var data: Data
        var storedAt: Date
    }

    private var directory: URL? {
        if let directoryOverride { return directoryOverride }
        // Apple TV gives an app no lasting storage of its own; what it keeps is a cache there.
        #if os(tvOS)
        let base = FileManager.SearchPathDirectory.cachesDirectory
        #else
        let base = FileManager.SearchPathDirectory.applicationSupportDirectory
        #endif
        return try? FileManager.default.url(for: base, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("BusBus/cache", isDirectory: true)
    }

    private func fileURL(key: String) -> URL? {
        let safe = key.replacingOccurrences(of: "/", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "._-"))) ?? key
        return directory?.appendingPathComponent(safe + ".json")
    }

    private func readFromDisk(key: String) -> (data: Data, storedAt: Date)? {
        guard let url = fileURL(key: key), let raw = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: raw) else { return nil }
        return (entry.data, entry.storedAt)
    }

    private func store(key: String, data: Data, persists: Bool) {
        let entry = (data: data, storedAt: Date())
        memory[key] = entry
        guard persists, let directory, let url = fileURL(key: key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let encoded = try? JSONEncoder().encode(Entry(data: data, storedAt: entry.storedAt)) else { return }
        try? encoded.write(to: url, options: .atomic)
    }
}

/// A line's path as the cache keeps it: thinned for drawing, with the verdict reached on the full
/// geometry against the stops it was fetched for.
nonisolated struct StoredShape: Codable, Hashable, Sendable {
    var shape: RouteShape
    var verdict: ShapeVerdict
    var stopsFingerprint: String
    var judgedAt: Date
    /// The line it was judged for, which names it in the cache.
    var lineID: String

    /// What the map may draw; nil when the shape failed its check (the card shows the stops alone).
    var drawable: RouteShape? { verdict.passes ? shape : nil }

    /// A rejection old enough to ask again (`TransitCache.missingShapeLifetime`).
    var isStaleRejection: Bool {
        !verdict.passes && Date().timeIntervalSince(judgedAt) >= TransitCache.missingShapeLifetime
    }

    /// Judges and thins off the cache's actor: a long shape against many stops takes a few
    /// milliseconds, and every other cache read would wait for it.
    @concurrent static func judging(_ shape: RouteShape, for pattern: RoutePattern, tolerance: ShapeTolerance) async -> StoredShape {
        StoredShape(judging: shape, for: pattern, tolerance: tolerance)
    }

    /// A line the feed has no usable path for, and why.
    init(rejecting reason: String, for pattern: RoutePattern, at date: Date = Date()) {
        shape = RouteShape(branches: [])
        verdict = .rejected(reason)
        stopsFingerprint = pattern.stopsFingerprint
        judgedAt = date
        lineID = pattern.line.id
    }

    init(judging shape: RouteShape, for pattern: RoutePattern, tolerance: ShapeTolerance, at date: Date = Date()) {
        judgedAt = date
        lineID = pattern.line.id
        let stops = pattern.stops.map { shape.stopPositions?[$0.stop.code] ?? $0.stop.location }
        verdict = ShapeCheck.verdict(shape, stops: stops, tolerance: tolerance)
        self.shape = RouteShape(branches: shape.branches.map { ShapeCheck.simplified($0) },
                                stopPositions: shape.stopPositions, version: shape.version)
        stopsFingerprint = pattern.stopsFingerprint
    }
}
