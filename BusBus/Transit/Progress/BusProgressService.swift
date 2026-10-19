import Foundation

/// A bus that has left the origin and hasn't finished the route, measured along it.
nonisolated struct TrackedBus: Identifiable, Sendable {
    /// Plate/trip when the provider has one; otherwise its rank along the route (bus.gov.il),
    /// which stays stable between refreshes as long as buses don't overtake each other.
    var id: String
    var vehicle: VehiclePosition
    var distanceAlongRoute: Double
    var offRoute: Double
    /// 0 = origin, 1 = last stop.
    var routeFraction: Double
    /// The next bus to reach the rider's stop.
    var isNext: Bool

    func metersToStop(_ progress: BusProgress) -> Double { progress.targetDistance - distanceAlongRoute }
    func hasPassedStop(_ progress: BusProgress) -> Bool { metersToStop(progress) < -BusProgressService.atStopToleranceMeters }
}

/// Where the buses of a line are, relative to the stop the rider waits at.
nonisolated struct BusProgress: Sendable {
    var providerId: String
    var fetchedAt: Date
    var fetchDuration: Duration

    var targetStopIndex: Int
    var targetDistance: Double
    var routeLength: Double

    /// Every bus between the origin and the last stop, ordered from the origin. All refreshed together.
    var buses: [TrackedBus]

    /// Every upcoming arrival, soonest first — the readout needs the second one too.
    var arrivals: [Arrival]
    /// Arrivals are optional for the bar, so a failure there is reported rather than thrown.
    var arrivalsError: String?
    /// Likewise the positions: without them the board loses its pucks, not its numbers.
    var vehiclesError: String?
    /// The replies behind those failures, when the server said something, for Crashlytics.
    var arrivalsReply: ResponseError? = nil
    var vehiclesReply: ResponseError? = nil
    /// Every position the provider returned, before filtering, for debugging.
    var allVehicleCount: Int

    var nextArrival: Arrival? { arrivals.first }
    var nextBus: TrackedBus? { buses.first(where: \.isNext) }
    var targetRouteFraction: Double { routeLength > 0 ? targetDistance / routeLength : 0 }
}

/// Provider-agnostic: combines route pattern + vehicles + arrivals into `BusProgress`.
nonisolated struct BusProgressService: Sendable {
    /// A bus this close past the stop still counts as "at the stop".
    static let atStopToleranceMeters = 40.0
    /// Buses farther than this from the stop-to-stop polyline are ignored.
    var maxOffRouteMeters = 400.0
    /// Within this distance of the origin the bus hasn't left yet; within this of the end it has finished.
    var terminalToleranceMeters = 50.0
    /// Fixes this much older than the newest one belong to rides that already ended (Stride keeps them).
    var staleAfter: TimeInterval = 3 * 60

    func progress(
        provider: any TransitProvider,
        geometry: RouteGeometry,
        line: TransitLine,
        stop: TransitStop
    ) async throws -> BusProgress {
        guard let targetIndex = geometry.pattern.stops.firstIndex(where: { $0.stop.code == stop.code }) else {
            throw TransitError.notFound("stop \(stop.code) on line \(line.shortName)")
        }
        let targetDistance = geometry.stopDistances[targetIndex]
        let started = ContinuousClock.now

        async let vehiclesRequest = provider.capabilities.contains(.vehiclePositions)
            ? provider.vehicles(for: line) : []
        async let arrivalsRequest = provider.arrivals(for: line, at: stop)
        var vehicles: [VehiclePosition] = []
        var vehiclesFailure: (any Error)?
        do { vehicles = try await vehiclesRequest } catch { vehiclesFailure = error }
        var arrivals: [Arrival] = []
        var arrivalsFailure: (any Error)?
        do { arrivals = try await arrivalsRequest } catch { arrivalsFailure = error }
        // Either half on its own still says something true; nothing at all does not.
        if let arrivalsFailure, vehiclesFailure != nil { throw arrivalsFailure }
        let returnedCount = vehicles.count

        // Providers that only attach the bus to its prediction still give us one position.
        if vehicles.isEmpty, let attached = arrivals.first(where: { $0.isRealtime && $0.vehicleLocation != nil })?.vehicleLocation {
            vehicles = [VehiclePosition(location: attached)]
        }

        let newest = vehicles.compactMap(\.recordedAt).max()
        var buses: [TrackedBus] = vehicles.compactMap { vehicle in
            if let newest, let recordedAt = vehicle.recordedAt, newest.timeIntervalSince(recordedAt) > staleAfter { return nil }

            let distance: Double, offRoute: Double
            if let published = vehicle.distanceAlongRoute {
                (distance, offRoute) = (published, 0)
            } else if let snapped = geometry.project(vehicle.location) {
                (distance, offRoute) = (snapped.distanceAlong, snapped.offRoute)
            } else {
                return nil
            }
            guard offRoute <= maxOffRouteMeters,
                  distance > terminalToleranceMeters,
                  distance < geometry.totalLength - terminalToleranceMeters else { return nil }

            return TrackedBus(
                id: "", vehicle: vehicle, distanceAlongRoute: distance, offRoute: offRoute,
                routeFraction: geometry.totalLength > 0 ? distance / geometry.totalLength : 0, isNext: false
            )
        }
        .sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }

        var upcoming = arrivals.filter { $0.expectedAt > AppClock.now.addingTimeInterval(-60) }
        if provider.reportsShadowTrips {
            (upcoming, buses) = Self.mergingShadowTrips(arrivals: upcoming, buses: buses) {
                geometry.project($0).map(\.distanceAlong)
            }
        }

        for index in buses.indices {
            buses[index].id = buses[index].vehicle.plateNumber ?? buses[index].vehicle.tripId ?? "bus-\(buses.count - index)"
        }
        // The next bus is the one closest to the stop that hasn't passed it.
        if let next = buses.lastIndex(where: { $0.distanceAlongRoute <= targetDistance + Self.atStopToleranceMeters }) {
            buses[next].isNext = true
        }

        return BusProgress(
            providerId: provider.id,
            fetchedAt: AppClock.now,
            fetchDuration: ContinuousClock.now - started,
            targetStopIndex: targetIndex,
            targetDistance: targetDistance,
            routeLength: geometry.totalLength,
            buses: buses,
            arrivals: upcoming,
            arrivalsError: arrivalsFailure?.localizedDescription,
            vehiclesError: vehiclesFailure?.localizedDescription,
            arrivalsReply: arrivalsFailure as? ResponseError,
            vehiclesReply: vehiclesFailure as? ResponseError,
            allVehicleCount: returnedCount
        )
    }

    /// Two live trips this close in place and time are one bus the feed carries twice.
    static let shadowTripMeters = 300.0
    static let shadowTripSeconds: TimeInterval = 3 * 60

    /// Folds one bus carried under two trips back into one: of two live predictions whose buses sit
    /// within `shadowTripMeters` along the route and are due within `shadowTripSeconds` of each
    /// other, the earlier is kept, and the drawn bus at the later one's position goes with it.
    /// `along` places a position on the route; one it cannot place is never merged.
    static func mergingShadowTrips(arrivals: [Arrival], buses: [TrackedBus],
                                   along: (GeoPoint) -> Double?) -> (arrivals: [Arrival], buses: [TrackedBus]) {
        var kept: [(arrival: Arrival, along: Double)] = []
        var dropped: [(kept: Double, shadow: Double)] = []
        var result: [Arrival] = []
        for arrival in arrivals.sorted(by: { $0.expectedAt < $1.expectedAt }) {
            guard arrival.isRealtime, let position = arrival.vehicleLocation.flatMap(along) else {
                result.append(arrival)
                continue
            }
            if let twin = kept.first(where: {
                abs($0.along - position) <= shadowTripMeters
                    && arrival.expectedAt.timeIntervalSince($0.arrival.expectedAt) <= shadowTripSeconds
            }) {
                dropped.append((twin.along, position))
                continue
            }
            kept.append((arrival, position))
            result.append(arrival)
        }

        var remaining = buses
        for pair in dropped {
            guard remaining.count > 1,
                  let real = remaining.indices.min(by: { abs(remaining[$0].distanceAlongRoute - pair.kept) < abs(remaining[$1].distanceAlongRoute - pair.kept) }),
                  let shadow = remaining.indices.filter({ $0 != real })
                      .min(by: { abs(remaining[$0].distanceAlongRoute - pair.shadow) < abs(remaining[$1].distanceAlongRoute - pair.shadow) }),
                  abs(remaining[shadow].distanceAlongRoute - pair.shadow) <= shadowTripMeters,
                  abs(remaining[shadow].distanceAlongRoute - remaining[real].distanceAlongRoute) <= shadowTripMeters
            else { continue }
            remaining.remove(at: shadow)
        }
        return (result, remaining)
    }
}
