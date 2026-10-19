import Foundation

/// Offline provider backed by the design fixtures, so every state of the board can be exercised
/// with no network: the four merge topologies of the artboards, moving buses, arrivals, lateness
/// and a nearby list.
nonisolated struct MockTransitProvider: TransitProvider {
    let id = "mock"
    let displayName = "Mock (design fixtures)"
    let capabilities: ProviderCapabilities = [
        .stopSearchByName, .stopSearchByCode, .linesAtStop, .routePattern,
        .vehiclePositions, .realtimeArrivals, .scheduledArrivals, .nearbyStops, .routeShape,
    ]
    let suggestedRefreshInterval: Duration = .seconds(5)
    /// Nothing leaves the device, so the band that protects a live endpoint does not apply. A
    /// running staged clock polls every second, so its buses move on screen as they are recorded.
    var refreshInterval: Duration { AppClock.rate > 0 ? .seconds(1) : suggestedRefreshInterval }

    /// Which artboard topology to serve. Settable so the debug picker can switch scenarios.
    var scenario: MockScenario = .main
    /// How many stops each route runs on past HARBOR GATE, where the design's routes end: the
    /// board draws the next one faded, as a terminus when it is the only one.
    var onwardCount = 0

    /// Each scenario is a different set of routes for the same line ids, so it is a different
    /// dataset as far as the pattern cache is concerned.
    var datasetID: String { onwardCount > 0 ? "mock.\(scenario.rawValue)+\(onwardCount)" : "mock.\(scenario.rawValue)" }

    /// One stop every two minutes, and a bus on each line at these intervals.
    private static let secondsPerStop: TimeInterval = 120
    private static let headways: [String: TimeInterval] = ["41": 9 * 60, "18": 12 * 60, "7": 15 * 60]
    /// Line 7 runs behind its timetable, so "RUNNING LATE" has something honest to show.
    private static let lateness: [String: TimeInterval] = ["7": 90]

    private var fixtureLines: [MapLineInput] { scenario.lines }

    // MARK: Geography
    //
    // Latitude is driven by how far a stop is from the user's stop rather than by its index, so a
    // stop shared by two routes lands in the same place on both and the polyline never doubles back.

    /// Where the user's stop is: on land in central Tel Aviv, so a map behind the stops has streets
    /// on it rather than open sea, or the real stop of the city screenshots stage (`MockPlace`).
    /// The routes run south and east of it.
    static var anchor: GeoPoint { MockPlace.current?.anchor ?? GeoPoint(lat: 32.090, lon: 34.780) }

    private var coordinates: [String: GeoPoint] {
        var result: [String: GeoPoint] = [:]
        let ordered = fixtureLines.sorted { $0.id == "41" && $1.id != "41" }
        for (row, line) in ordered.enumerated() {
            let last = line.stops.count - 1
            for (index, stop) in line.stops.enumerated() where result[stop.code] == nil {
                result[stop.code] = GeoPoint(lat: Self.anchor.lat - 0.004 * Double(last - index),
                                             lon: Self.anchor.lon + 0.006 * Double(row))
            }
        }
        return result
    }

    private func transitStop(_ input: MapStopInput) -> TransitStop {
        guard let place = MockPlace.current else {
            return TransitStop(code: input.code, name: input.name, city: "Harbor City",
                               location: coordinates[input.code] ?? Self.anchor)
        }
        return TransitStop(code: MockPlace.code(for: input.code), name: place.name(for: input.name), city: place.city,
                           location: coordinates[input.code] ?? Self.anchor)
    }

    private func transitLine(_ input: MapLineInput) -> TransitLine {
        // The artboards label the readout with the name at the far end of the drawn route, so the
        // mock's destination matches its terminus. A real feed supplies its own headsign.
        let terminus = MockPlace.current?.name(for: input.stops[0].name) ?? input.stops[0].name
        return TransitLine(id: input.id, shortName: input.number, headsign: terminus,
                           agency: "Mock Transit", origin: terminus,
                           destination: terminus, isAccessible: true,
                           brandColorIndex: input.colorIndex,
                           providerRefs: ["routeDesc": input.id])
    }

    private var allStops: [TransitStop] {
        var seen: Set<String> = []
        var result: [TransitStop] = []
        for line in fixtureLines {
            for stop in line.stops where seen.insert(stop.code).inserted {
                result.append(transitStop(stop))
            }
        }
        return result
    }

    // MARK: TransitProvider

    func searchStops(query: String) async throws -> [TransitStop] {
        let needle = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard !needle.isEmpty else { return allStops }
        return (allStops + [Self.linelessStop]).filter { $0.name.contains(needle) || $0.code == needle }
    }

    /// A stop no line calls at, as real feeds have (bus.gov.il's 41489): found by name only, never
    /// listed nearby, so the staged screens are unchanged and the confirm step's "no lines" can be
    /// reached on purpose.
    static var linelessStop: TransitStop {
        TransitStop(code: "MARSH", name: "SALT MARSH", city: "Harbor City",
                    location: GeoPoint(lat: anchor.lat - 0.006, lon: anchor.lon - 0.008))
    }

    func lines(atStop stop: TransitStop) async throws -> [TransitLine] {
        fixtureLines.filter { line in line.stops.contains { $0.code == MockPlace.fixtureCode(for: stop.code) } }.map(transitLine)
    }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        guard let fixture = fixtureLines.first(where: { $0.id == line.id }) else {
            throw TransitError.notFound("line \(line.id)")
        }
        var pattern = fixturePattern(fixture)
        // On past the user's stop, northwards, where no fixture stop lies.
        for (offset, name) in Self.onwardNames.prefix(onwardCount).enumerated() {
            let input = MapStopInput(code: name.replacingOccurrences(of: " ", with: "-"), name: name)
            var stop = transitStop(input)
            stop.location = GeoPoint(lat: Self.anchor.lat + 0.004 * Double(offset + 1), lon: Self.anchor.lon)
            pattern.stops.append(PatternStop(stop: stop, sequence: pattern.stops.count + 1, distanceAlongRoute: nil))
        }
        return pattern
    }

    private static let onwardNames = ["LIGHTHOUSE", "SEA WALL", "NORTH POINT", "CAPE ROAD"]

    /// The route along a street grid: from each stop half way to the next, across to its column,
    /// and on. The fixtures' stops stand on columns a block apart, so this is the path a bus
    /// between them would drive, and it passes `ShapeCheck` for the line card.
    func routeShape(for line: TransitLine, pattern: RoutePattern) async throws -> RouteShape {
        let stops = pattern.stops.map(\.stop.location)
        guard var previous = stops.first else { throw TransitError.notFound("line \(line.id)") }
        var points = [previous]
        for next in stops.dropFirst() {
            let middle = (previous.lat + next.lat) / 2
            points += [GeoPoint(lat: middle, lon: previous.lon), GeoPoint(lat: middle, lon: next.lon), next]
            previous = next
        }
        return RouteShape(points, version: "mock")
    }

    /// The route as the design draws it, terminus to HARBOR GATE: what the buses are simulated on.
    private func fixturePattern(_ fixture: MapLineInput) -> RoutePattern {
        RoutePattern(line: transitLine(fixture), stops: fixture.stops.enumerated().map {
            PatternStop(stop: transitStop($1), sequence: $0 + 1, distanceAlongRoute: nil)
        })
    }

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        guard let fixture = fixtureLines.first(where: { $0.id == line.id }) else { return [] }
        let geometry = RouteGeometry(pattern: fixturePattern(fixture))
        let now = AppClock.now
        return fractions(for: fixture, at: now).enumerated().map { index, fraction in
            let departed = now.addingTimeInterval(-fraction * tripDuration(fixture))
            return VehiclePosition(
                location: point(atFraction: fraction, geometry: geometry),
                recordedAt: now.addingTimeInterval(-8),
                tripId: "\(line.id)-trip\(index)",
                plateNumber: "\(line.id)-\(1000 + index)",
                speedKmh: 24,
                aimedDeparture: departed.addingTimeInterval(-Self.lateness[line.id, default: 0]),
                actualDeparture: departed,
                isAccessible: true)
        }
    }

    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        arrivals(for: line, at: stop, now: AppClock.now)
    }

    /// The arrivals as they would have been fetched at `now`: the widget screenshots stage numbers
    /// fetched a while before the frozen 9:41, to show them going stale.
    func arrivals(for line: TransitLine, at stop: TransitStop, now: Date) -> [Arrival] {
        guard let fixture = fixtureLines.first(where: { $0.id == line.id }),
              let target = fixture.stops.lastIndex(where: { $0.code == MockPlace.fixtureCode(for: stop.code) }) else { return [] }
        let duration = tripDuration(fixture)
        let targetFraction = Double(target) / Double(max(1, fixture.stops.count - 1))
        let late = Self.lateness[line.id, default: 0]

        // Each arrival keeps the index of the bus it belongs to, so its trip id names that bus.
        return fractions(for: fixture, at: now)
            .enumerated()
            .map { (index: $0, seconds: (targetFraction - $1) * duration) }
            .filter { $0.seconds >= -60 }
            .sorted { $0.seconds < $1.seconds }
            .map { index, seconds in
                let expected = now.addingTimeInterval(seconds)
                return Arrival(expectedAt: expected,
                               scheduledAt: expected.addingTimeInterval(-late),
                               isRealtime: true,
                               tripId: "\(line.id)-trip\(index)",
                               vehicleLocation: nil)
            }
    }

    /// Where the bus behind one of those arrivals is at `now`, as the board places it (`BoardBus`):
    /// stops short of `stop`, and how far on towards the next. The widget screenshots' map puts
    /// its pucks here.
    func position(of arrival: Arrival, line: TransitLine, at stop: TransitStop,
                  now: Date) -> (stopsAway: Int, progressToNext: Double)? {
        guard let fixture = fixtureLines.first(where: { $0.id == line.id }),
              let target = fixture.stops.lastIndex(where: { $0.code == MockPlace.fixtureCode(for: stop.code) }) else { return nil }
        let along = min(max(Double(target) - arrival.expectedAt.timeIntervalSince(now) / Self.secondsPerStop, 0),
                        Double(target))
        let index = min(Int(along.rounded(.down)), max(0, target - 1))
        return (target - index, min(max(along - Double(index), 0), 1))
    }

    func stopsNearby(_ point: GeoPoint, radiusMeters: Double) async throws -> [NearbyStop] {
        var result: [NearbyStop] = []
        for stop in allStops {
            let distance = RouteGeometry.meters(point, stop.location)
            guard distance <= radiusMeters else { continue }
            result.append(NearbyStop(stop: stop, distanceMeters: distance,
                                     lines: try await lines(atStop: stop)))
        }
        return result.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    /// A stop and the lines through it, without a round trip: screenshots stage a rider's history
    /// before the first frame is drawn.
    func staged(stopCode: String) -> (stop: TransitStop, lines: [TransitLine])? {
        guard let input = fixtureLines.lazy.flatMap(\.stops).first(where: { $0.code == stopCode }) else { return nil }
        let lines = fixtureLines.filter { line in line.stops.contains { $0.code == stopCode } }.map(transitLine)
        return (transitStop(input), lines)
    }

    // MARK: Simulation

    private func tripDuration(_ line: MapLineInput) -> TimeInterval {
        Self.secondsPerStop * Double(max(1, line.stops.count - 1))
    }

    /// Where each bus of the line is along its trip, as a fraction from 0 (terminus) to 1 (the end).
    private func fractions(for line: MapLineInput, at date: Date) -> [Double] {
        let duration = tripDuration(line)
        // No more than three buses on a line at once, however long it is, so a long route's
        // compressed run is not a pile of overlapping pucks.
        let headway = max(Self.headways[line.id] ?? 6 * 60, duration / 3)
        let elapsed = date.timeIntervalSinceReferenceDate
        // A per-line phase keeps the three lines from arriving in lockstep. Built from the id's
        // characters rather than `hashValue`, which is seeded afresh on every launch.
        let phase = Double(line.id.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 97 }) * 3
        return stride(from: 0.0, to: duration, by: headway).map { offset in
            ((elapsed + offset + phase).truncatingRemainder(dividingBy: duration)) / duration
        }
    }

    private func point(atFraction fraction: Double, geometry: RouteGeometry) -> GeoPoint {
        let stops = geometry.pattern.stops.map(\.stop.location)
        guard stops.count >= 2 else { return stops.first ?? Self.anchor }
        let distance = fraction * geometry.totalLength
        let index = min(geometry.lastStopIndex(atDistance: distance), stops.count - 2)
        let segment = geometry.stopDistances[index + 1] - geometry.stopDistances[index]
        let t = segment > 0 ? (distance - geometry.stopDistances[index]) / segment : 0
        let a = stops[index], b = stops[index + 1]
        return GeoPoint(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
    }
}
