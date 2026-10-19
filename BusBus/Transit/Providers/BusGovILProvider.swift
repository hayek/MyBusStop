import Foundation

/// Israel — the JSON API behind route.bus.gov.il (National Public Transport Authority).
/// Undocumented & keyless: no ToS, no published rate limit, may change without notice.
/// Live positions are ~≤40 s fresh (straight from MOT SIRI). See docs/research/transit-apis.md §3.1.4.
nonisolated struct BusGovILProvider: TransitProvider {
    let id = "bus.gov.il"
    let displayName = "bus.gov.il (unofficial, live)"
    let attribution: String? = "Data: Israel National Public Transport Authority (bus.gov.il)"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .scheduledArrivals, .nearbyStops, .routeShape,
    ]
    let suggestedRefreshInterval: Duration = .seconds(20)

    var http = HTTPClient()

    /// Stop names come in Hebrew, English and Arabic. Hebrew and Arabic readers get their own;
    /// everyone else gets English, the one a visitor can read. Resolved per call, since the rider
    /// can change the app's language at any time.
    static var language: String {
        switch AppLanguage.locale.language.languageCode?.identifier {
        case "he": "he"
        case "ar": "ar"
        default: "en"
        }
    }
    private var language: String { Self.language }

    /// Cached lines and routes carry names, so each language is its own dataset.
    var datasetID: String { "\(id).\(language)" }

    /// A route's path has no names in it, and Stride's line refs are the same MOT route ids.
    static let shapeDatasetID = "il-mot"
    var shapeDatasetID: String { Self.shapeDatasetID }

    private var scheduler: String { "https://api.bus.gov.il/prod/mot-scheduler-prod/api/\(language)" }
    private var planner: String { Self.planner(language) }
    private static func planner(_ language: String) -> String { "https://api.bus.gov.il/prod/route-planner-prod/api/\(language)" }

    /// Each language path only matches names written in that language — אלנבי finds nothing on
    /// the English path, Allenby nothing on the Hebrew one — so a name is searched in the language
    /// its letters are written in, and the app's language only decides when there are no letters.
    static func searchLanguage(for query: String) -> String {
        for scalar in query.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0590...0x05FF, 0xFB1D...0xFB4F: return "he"
            case 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return "ar"
            default: return "en"
            }
        }
        return language
    }

    func searchStops(query: String) async throws -> [TransitStop] {
        let query = query.trimmingCharacters(in: .whitespaces)
        if Int(query) != nil {
            // The planner names the stop in the app's language; the scheduler's own lookup often
            // has only the Hebrew name, so it is the fallback for codes the planner does not know.
            let planned = try? await http.get(Envelope<[DTO.SearchStation]>.self, planner, "/AutoComplete/SearchStations", query: ["searchTerm": query])
            if let exact = planned?.data?.first(where: { String($0.stopcode) == query }) { return [exact.stop] }
            let response = try await http.get(Envelope<DTO.Stop?>.self, scheduler, "/Stops/GetStopByCode", query: ["stopcode": query])
            return response.data.flatMap { $0 }.map { [$0.stop] } ?? []
        }
        let response = try await http.get(Envelope<[DTO.SearchStation]>.self, Self.planner(Self.searchLanguage(for: query)),
                                          "/AutoComplete/SearchStations", query: ["searchTerm": query])
        return (response.data ?? []).map(\.stop)
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        let response = try await http.get(Envelope<DTO.StopFullData>.self, scheduler, "/Stops/GetStopFullData", query: ["stopCode": stop.code])
        guard let routes = response.data?.routesInStop else { return [] }
        return routes.map(\.line)
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let response = try await http.get(Envelope<DTO.RouteStopsData>.self, scheduler, "/Routes/GetRouteStops", query: ["routeId": line.id])
        guard let stops = response.data?.route?.stops, !stops.isEmpty else {
            throw TransitError.notFound("stops for route \(line.id)")
        }
        return RoutePattern(
            line: line,
            stops: stops.sorted { $0.stopSequence < $1.stopSequence }.map {
                PatternStop(stop: $0.stop, sequence: $0.stopSequence, distanceAlongRoute: nil)
            }
        )
    }

    /// The Ministry of Transport's own shape (GTFS `shapes.txt`), which the site draws its map
    /// from. `GetRouteFullData` carries it whatever day it is asked, Shabbat included; the
    /// lighter `GetRouteStops` stays the pattern call, since the board refreshes that daily and
    /// this reply is 50–110 KB. docs/research/route-shapes/israel.md.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        let response = try await http.get(Envelope<DTO.RouteFullData>.self, scheduler, "/Routes/GetRouteFullData",
                                          query: ["routeId": line.id])
        guard let encoded = response.data?.polyline, !encoded.isEmpty else {
            throw TransitError.notFound("shape of route \(line.id)")
        }
        return RouteShape(try Polyline.decodeFlexible(encoded))
    }

    /// Seen on line 3 in Haifa: the 14:33 slot running 17 minutes late and the 14:45 slot both live,
    /// both due at 14:51, their positions 15–250 m apart and swapping order for minutes on end, and
    /// one bus at the stop.
    var reportsShadowTrips: Bool { true }

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        // Bare lat/lng of every bus on the route — no trip id, plate, speed, departure times or timestamp.
        let response = try await http.get(Envelope<[DTO.LatLng]>.self, scheduler, "/Routes/GetRouteLocations", query: ["routeId": line.id])
        return (response.data ?? []).map { VehiclePosition(location: $0.point) }
    }

    /// `Stops/GetStopsCloseToLocation` returns each nearby stop together with the lines that serve
    /// it, which is exactly what the NEARBY list needs — one call, no per-stop fan-out.
    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        let response = try await http.get(
            Envelope<[DTO.NearbyStop]>.self, scheduler, "/Stops/GetStopsCloseToLocation",
            query: ["lat": String(point.lat), "lng": String(point.lon), "radius": String(Int(radiusMeters))]
        )
        return (response.data ?? [])
            .map { entry in
                let stop = entry.stop
                return NearbyStop(stop: stop,
                                  distanceMeters: RouteGeometry.meters(point, stop.location),
                                  lines: (entry.routesInStop ?? []).map(\.line))
            }
            .sorted { $0.distanceMeters < $1.distanceMeters }
    }

    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        guard let routeDesc = line.providerRefs["routeDesc"] else {
            throw TransitError.unsupported("line \(line.id) has no routeDesc (was it loaded from another provider?)")
        }
        // A stop with no departures left today (late at night, on Shabbat) comes back as
        // `{"41122": null}`, so the value is optional: that is an empty board, not a broken feed.
        let response = try await http.get(
            Envelope<[String: DTO.StopCalendar?]>.self, scheduler, "/Calendar/GetRouteCalendarAtStopsByStopCodes",
            query: ["stopCodes": stop.code, "routeDesc": routeDesc]
        )
        let now = Date()
        let times = response.data?[stop.code]??.stopTimes ?? []
        // A live trip's timetable slot can come back a second time as a bare scheduled entry (no
        // trip id, `arrivalTime` = the live one's `staticArrivalTime`): one bus, shown twice.
        let tracked = Set(times.filter { $0.isRealTime == true }.compactMap(\.staticArrivalTime))
        return times
            .filter { $0.isRealTime == true || !tracked.contains($0.arrivalTime ?? "") }
            .compactMap { time -> Arrival? in
                let expected = time.minutesToArrival.map { now.addingTimeInterval($0 * 60) }
                    ?? time.arrivalTime.flatMap(DTO.parseLocal)
                guard let expected else { return nil }
                return Arrival(
                    expectedAt: expected,
                    scheduledAt: time.staticArrivalTime.flatMap(DTO.parseLocal),
                    isRealtime: time.isRealTime ?? false,
                    tripId: time.staticTripId,
                    vehicleLocation: time.routeLocation?.point
                )
            }
            .sorted { $0.expectedAt < $1.expectedAt }
    }
}

// MARK: - Wire format

private nonisolated struct Envelope<T: Decodable & Sendable>: Decodable, Sendable {
    var data: T?
    var success: Bool?
    var message: String?
}

private nonisolated enum DTO {
    struct Names: Decodable, Sendable {
        var he: String?
        var en: String?
        var ar: String?

        /// The app's language when the feed has it, Hebrew (always filled) when it does not.
        var preferred: String? {
            let wanted = switch BusGovILProvider.language {
            case "ar": ar
            case "en": en
            default: he
            }
            return [wanted, he, en, ar].compactMap { $0?.isEmpty == false ? $0 : nil }.first
        }
    }

    /// The scheduler's city names are Hebrew whatever the path says, so they are only shown to
    /// Hebrew readers; the planner's search results carry a translated city of their own.
    static func city(_ name: String?) -> String? {
        BusGovILProvider.language == "he" ? name : nil
    }

    struct LatLng: Decodable, Sendable {
        var lat: Double
        var lng: Double
        var point: GeoPoint { GeoPoint(lat: lat, lon: lng) }
    }

    struct Stop: Decodable, Sendable {
        var stopcode: Int
        var name: Names?
        var cityName: String?
        /// Hebrew on every language path. Filled on the scheduler's stop-by-code and route-stops.
        var streetName: String?
        var streetNumber: String?
        var lat: Double
        var lng: Double
        var stopSequence: Int

        var stop: TransitStop {
            TransitStop(code: String(stopcode), name: name?.preferred ?? String(stopcode), city: DTO.city(cityName),
                        location: GeoPoint(lat: lat, lon: lng),
                        address: TransitStop.address([streetName, streetNumber]))
        }

        /// "stop name, city"
        var place: String {
            [name?.preferred, DTO.city(cityName)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    struct SearchStation: Decodable, Sendable {
        var stopcode: Int
        var name: String   // "אלנבי ג (41122)"
        var cityName: String?
        /// Present but empty on every search seen so far; read anyway so a fix upstream shows up.
        var streetName: String?
        var streetNumber: String?
        var lat: Double
        var lng: Double

        var stop: TransitStop {
            let clean = name.replacingOccurrences(of: " (\(stopcode))", with: "")
            return TransitStop(code: String(stopcode), name: clean, city: cityName, location: GeoPoint(lat: lat, lon: lng),
                               address: TransitStop.address([streetName, streetNumber]))
        }
    }

    /// The name field comes back as a localised object on some endpoints and a bare string on
    /// others, so it is decoded either way rather than guessing.
    struct LocalizedName: Decodable, Sendable {
        var value: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                value = text
            } else if let names = try? container.decode(Names.self) {
                value = names.preferred
            } else {
                value = nil
            }
        }
    }

    struct NearbyStop: Decodable, Sendable {
        var stopcode: Int
        var name: LocalizedName?
        var cityName: String?
        /// Hebrew on every language path, and filled for nearly every stop.
        var streetName: String?
        var streetNumber: String?
        var lat: Double
        var lng: Double
        var routesInStop: [RouteInStop]?

        var stop: TransitStop {
            let clean = (name?.value ?? String(stopcode))
                .replacingOccurrences(of: " (\(stopcode))", with: "")
            return TransitStop(code: String(stopcode), name: clean, city: DTO.city(cityName),
                               location: GeoPoint(lat: lat, lon: lng),
                               address: TransitStop.address([streetName, streetNumber]))
        }
    }

    struct StopFullData: Decodable, Sendable {
        var routesInStop: [RouteInStop]?
    }

    struct RouteInStop: Decodable, Sendable {
        struct SpecialData: Decodable, Sendable { var isAccessible: Bool? }

        var routeId: Int
        var routeName: String
        var routeDesc: String?
        var routeLongName: String?
        var agencyName: String?
        var headsign: Names?
        var stops: [Stop]?
        var specialData: SpecialData?

        var line: TransitLine {
            let longName = routeLongName.map(IsraelRouteLongName.init)
            let ordered = stops?.sorted { $0.stopSequence < $1.stopSequence }
            return TransitLine(
                id: String(routeId),
                shortName: routeName,
                headsign: headsign?.preferred,
                agency: agencyName,
                origin: ordered?.first.map(\.place) ?? longName?.origin,
                destination: ordered?.last.map(\.place) ?? longName?.destination,
                isAccessible: specialData?.isAccessible,
                providerRefs: routeDesc.map { ["routeDesc": $0] } ?? [:]
            )
        }
    }

    struct RouteFullData: Decodable, Sendable {
        /// HERE flexible polyline; the header claims precision 15, the values carry about 6 decimals.
        var polyline: String?
    }

    struct RouteStopsData: Decodable, Sendable {
        struct Route: Decodable, Sendable { var stops: [Stop]? }
        var route: Route?
    }

    struct StopCalendar: Decodable, Sendable {
        var stopTimes: [StopTime]?
    }

    struct StopTime: Decodable, Sendable {
        var staticTripId: String?
        var staticArrivalTime: String?
        var arrivalTime: String?
        var minutesToArrival: Double?
        var isRealTime: Bool?
        var routeLocation: LatLng?
    }

    /// Times come as Israel local time without an offset: "2026-09-17T05:59:26".
    static func parseLocal(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Jerusalem")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: String(string.prefix(19)))
    }
}
