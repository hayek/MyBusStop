import Foundation

/// A 3rd-party transit data source. Adapters are swappable at runtime so we can A/B them.
nonisolated protocol TransitProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }
    /// How often it is reasonable to poll live data from this source.
    var suggestedRefreshInterval: Duration { get }
    /// What the board actually polls at. Held inside the brief's 20-30 second band for anything
    /// coming off a network; a source that costs nothing to ask can say otherwise.
    var refreshInterval: Duration { get }
    /// Identifies the *dataset* behind this provider, not just the adapter. Cached route patterns
    /// are keyed on it, so a provider that can serve more than one set of routes must vary it or
    /// it will keep handing back the routes of whichever set was loaded first.
    var datasetID: String { get }
    /// The credit line the data's licence asks the app to show, verbatim ("Powered by TfL Open
    /// Data"). Shown wherever the rider picks from this provider's data. Nil when none is owed.
    var attribution: String? { get }
    /// The `APIKeys` name this provider cannot work without in this build, or nil when it needs
    /// none — including when it reaches its API through our key-holding proxy.
    var requiredAPIKey: String? { get }
    /// True when the feed can carry one bus under two trips at once — a late slot and the next —
    /// each with a live time and a position of its own a little apart. The progress service then
    /// folds such a pair back into one bus (`BusProgressService.mergingShadowTrips`).
    var reportsShadowTrips: Bool { get }

    func searchStops(query: String) async throws -> [TransitStop]
    func lines(atStop stop: TransitStop) async throws -> [TransitLine]
    func routePattern(for line: TransitLine) async throws -> RoutePattern
    /// Current buses of the line. May be empty (night, no data) — that's not an error.
    func vehicles(for line: TransitLine) async throws -> [VehiclePosition]
    /// Upcoming arrivals of the line at the stop, soonest first.
    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival]
    /// Stops near a point, nearest first, each with the lines that serve it.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop]

    /// The line's real path along the roads, for the line card's map. Asked for only when a rider
    /// opens a line, and cached until the pattern's stops change (`TransitCache.shape`), so a line
    /// costs at most one request of its own. Throws `unsupported` when the feed has no shapes.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape
    /// The pattern, plus the shape when the very same reply carries it. A provider whose pattern
    /// reply holds the geometry overrides this so the shape costs no request at all;
    /// `routePattern(for:)` stays the plain call.
    func routePatternWithShape(for line: TransitLine) async throws -> (pattern: RoutePattern, shape: RouteShape?)
    /// Which cache a shape is kept under. Feeds that share line ids (Stride borrows bus.gov.il's
    /// shapes) return the same value, so one fetch serves both.
    var shapeDatasetID: String { get }
    /// How far a stop may stand from this feed's shapes; looser where stops are stop-area centres.
    var shapeTolerance: ShapeTolerance { get }
    /// Whether this line can have a route to draw. The ⓘ that opens a line's card is offered only
    /// then: a feed without shapes gets no map buttons at all.
    func hasRouteShape(for line: TransitLine) -> Bool
}

nonisolated extension TransitProvider {
    /// One adapter, one dataset, for every provider that talks to a single live feed.
    var datasetID: String { id }

    var attribution: String? { nil }

    var requiredAPIKey: String? { nil }

    var reportsShadowTrips: Bool { false }

    /// False when the provider needs a key this build does not have and cannot use the proxy
    /// instead (in Release: only while `transit_proxy_url` is switched off). Such a provider is
    /// treated as unavailable, like one switched off remotely, and every call throws `missingAPIKey`.
    var hasRequiredAPIKey: Bool { requiredAPIKey.map { APIKeys.key($0) != nil } ?? true }

    var refreshInterval: Duration {
        .seconds(min(max(suggestedRefreshInterval.components.seconds, 20), 30))
    }

    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        throw TransitError.unsupported("route shapes")
    }

    func routePatternWithShape(for line: TransitLine) async throws -> (pattern: RoutePattern, shape: RouteShape?) {
        (try await routePattern(for: line), nil)
    }

    var shapeDatasetID: String { datasetID }

    var shapeTolerance: ShapeTolerance { .platforms }

    func hasRouteShape(for line: TransitLine) -> Bool { capabilities.contains(.routeShape) }

    /// Most feeds have no proximity query; the setup screen falls back to search and says so.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        throw TransitError.unsupported("nearby stops")
    }
}

nonisolated enum TransitProviders {
    static let all: [any TransitProvider] = [
        BusGovILProvider(),
        StrideProvider(),
        MBTAProvider(),
        MetroTransitProvider(),
        MTABusTimeProvider(),
        OneBusAwayProvider(.pugetSound),
        OneBusAwayProvider(.tampa),
        CarrisMetropolitanaProvider(),
        STARRennesProvider(),
        STIBProvider(),
        EnturProvider(),
        FoliProvider(),
        TampereProvider(),
        PoznanProvider(),
        MTRBusProvider(),
        KMBProvider(),
        CitybusProvider(),
        GMBProvider(),
        NLBProvider(),
        TfLProvider(),
        WienerLinienProvider(),
        ToeiBusProvider(),
        AdelaideMetroProvider(),
        EFAProvider(.linz),
        GdanskProvider(),
        KrakowProvider(),
        IETTProvider(),
        UmoNextBusProvider(agency: .ttc),
        PikasProvider.tallinn,
        PikasProvider.vilnius,
        PikasProvider.kaunas,
        SwissTransportProvider(),
        VAGProvider(),
        LPPProvider(),
        HafasProvider(.luxembourg),
        HafasProvider(.vbb),
        BizkaibusProvider(),
        // Not a region we sell: only the fallback outside every region, behind `transitous_enabled`.
        TransitousProvider(),
    ] + staged

    /// The staged feed draws on the map engine's fixtures, which the widget does not carry.
    #if BUSBUS_WIDGET
    private static let staged: [any TransitProvider] = []
    #else
    private static let staged: [any TransitProvider] = [MockTransitProvider()]
    #endif

    /// Adapters that work but may not ship yet (production access or terms still pending). A Debug
    /// build can pick them in Settings › Debug; a Release build never sees them.
    #if DEBUG
    static let heldBack: [any TransitProvider] = []
    #else
    static let heldBack: [any TransitProvider] = []
    #endif

    static func provider(id: String) -> any TransitProvider {
        all.first { $0.id == id } ?? heldBack.first { $0.id == id } ?? all[0]
    }
}
