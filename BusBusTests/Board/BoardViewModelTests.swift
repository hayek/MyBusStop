import Testing
import Foundation
@testable import BusBus

/// A provider whose vehicles and arrivals are dictated by the test, so the view model's matching,
/// staleness and readout rules can be checked without a clock or a network.
private nonisolated struct StubProvider: TransitProvider {
    let id = "stub"
    let displayName = "Stub"
    let capabilities: ProviderCapabilities = [.routePattern, .vehiclePositions, .realtimeArrivals]
    let suggestedRefreshInterval: Duration = .seconds(20)

    var mock = MockTransitProvider()
    /// Distances along the route, from the terminus, one per bus.
    var busDistances: [String: [Double]] = [:]
    var arrivalOffsets: [String: [TimeInterval]] = [:]
    /// Where each prediction says its bus is, as a distance along the route (bus.gov.il attaches
    /// one per realtime trip). Nil entries, or no list at all, send the prediction without one.
    var arrivalBusDistances: [String: [Double?]] = [:]
    var scheduledOffsets: [String: [TimeInterval]] = [:]
    var failingLines: Set<String> = []
    /// Lines whose positions come back but whose timetable call fails.
    var failingArrivals: Set<String> = []
    var arrivalsAreRealtime = true
    /// bus.gov.il publishes neither a plate nor a trip id, so the board falls back to ranking.
    var identifiesVehicles = true
    var now: Date = Date(timeIntervalSince1970: 1_800_000_000)

    func searchStops(query: String) async throws -> [TransitStop] { try await mock.searchStops(query: query) }
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] { try await mock.lines(atStop: stop) }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        if failingLines.contains(line.id) { throw TransitError.badResponse("stub failure") }
        return try await mock.routePattern(for: line)
    }

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] {
        if failingLines.contains(line.id) { throw TransitError.badResponse("stub failure") }
        let geometry = RouteGeometry(pattern: try await routePattern(for: line))
        return (busDistances[line.id] ?? []).enumerated().map { index, distance in
            VehiclePosition(location: point(atDistance: distance, geometry: geometry),
                            recordedAt: now,
                            tripId: identifiesVehicles ? "\(line.id)-t\(index)" : nil,
                            plateNumber: identifiesVehicles ? "\(line.id)-p\(index)" : nil)
        }
    }

    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        if failingLines.contains(line.id) || failingArrivals.contains(line.id) {
            throw TransitError.badResponse("stub failure")
        }
        let geometry = RouteGeometry(pattern: try await routePattern(for: line))
        let located = arrivalBusDistances[line.id] ?? []
        return (arrivalOffsets[line.id] ?? []).enumerated().map { index, offset in
            Arrival(expectedAt: now.addingTimeInterval(offset),
                    scheduledAt: (scheduledOffsets[line.id]?.indices.contains(index) ?? false)
                        ? now.addingTimeInterval(scheduledOffsets[line.id]![index]) : nil,
                    isRealtime: arrivalsAreRealtime, tripId: "\(line.id)-t\(index)",
                    vehicleLocation: located.indices.contains(index)
                        ? located[index].map { point(atDistance: $0, geometry: geometry) } : nil)
        }
    }

    private func point(atDistance distance: Double, geometry: RouteGeometry) -> GeoPoint {
        let stops = geometry.pattern.stops.map(\.stop.location)
        guard stops.count >= 2 else { return stops.first ?? GeoPoint(lat: 0, lon: 0) }
        let index = min(geometry.lastStopIndex(atDistance: distance), stops.count - 2)
        let segment = geometry.stopDistances[index + 1] - geometry.stopDistances[index]
        let t = segment > 0 ? (distance - geometry.stopDistances[index]) / segment : 0
        let a = stops[index], b = stops[index + 1]
        return GeoPoint(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
    }
}

/// A line that passes the rider's stop, carries on and comes back to it — the shape the map has to
/// draw as far as the *second* visit, not the first.
private nonisolated struct LoopProvider: TransitProvider {
    let id = "loop"
    let displayName = "Loop"
    let capabilities: ProviderCapabilities = [.routePattern, .realtimeArrivals]
    let suggestedRefreshInterval: Duration = .seconds(20)

    var mock = MockTransitProvider()

    func searchStops(query: String) async throws -> [TransitStop] { try await mock.searchStops(query: query) }
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] { try await mock.lines(atStop: stop) }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let base = try await mock.routePattern(for: line)
        let user = try await mock.searchStops(query: MapFixtures.user).first!
        var stops = base.stops
        // …USER, one more stop, USER again.
        stops.append(PatternStop(stop: base.stops[1].stop, sequence: stops.count))
        stops.append(PatternStop(stop: user, sequence: stops.count))
        return RoutePattern(line: base.line, stops: stops)
    }

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }

    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] {
        [Arrival(expectedAt: Date().addingTimeInterval(300), scheduledAt: nil, isRealtime: true,
                 tripId: nil, vehicleLocation: nil)]
    }
}

/// A line that runs on past the rider's stop, through two more, to a terminus beyond it.
private nonisolated struct ThroughProvider: TransitProvider {
    let id = "through"
    let displayName = "Through"
    let capabilities: ProviderCapabilities = [.routePattern, .realtimeArrivals]
    let suggestedRefreshInterval: Duration = .seconds(20)

    var mock = MockTransitProvider()

    func searchStops(query: String) async throws -> [TransitStop] { try await mock.searchStops(query: query) }
    func lines(atStop stop: TransitStop) async throws -> [TransitLine] { try await mock.lines(atStop: stop) }

    func routePattern(for line: TransitLine) async throws -> RoutePattern {
        let base = try await mock.routePattern(for: line)
        var stops = base.stops
        for (offset, code) in ["BEYOND-1", "BEYOND-END"].enumerated() {
            let last = stops[stops.count - 1].stop.location
            stops.append(PatternStop(stop: TransitStop(code: code, name: code,
                                                       location: GeoPoint(lat: last.lat + 0.002 * Double(offset + 1),
                                                                          lon: last.lon)),
                                     sequence: stops.count))
        }
        return RoutePattern(line: base.line, stops: stops)
    }

    func vehicles(for line: TransitLine) async throws -> [VehiclePosition] { [] }

    func arrivals(for line: TransitLine, at stop: TransitStop) async throws -> [Arrival] { [] }
}

/// Lets the tests hand the view model a provider of their own.
private nonisolated struct StubProviderBox: @unchecked Sendable { var provider: StubProvider }

@Suite(.appLanguage("en"))
@MainActor
struct BoardViewModelTests {

    private static func makeModel(cache: TransitCache? = nil,
                                  _ configure: (inout StubProvider) -> Void = { _ in },
                                  lineIDs: [String] = ["18", "41", "7"]) async -> (BoardViewModel, SettingsStore) {
        var stub = StubProvider()
        configure(&stub)
        let defaults = UserDefaults(suiteName: "vm-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.providerOverride = stub
        let stop = try! await stub.searchStops(query: MapFixtures.user).first!
        let all = try! await stub.lines(atStop: stop)
        settings.apply(stop: stop, lines: lineIDs.compactMap { id in all.first { $0.id == id } },
                       providerID: "stub")
        let model = BoardViewModel(settings: settings, cache: cache ?? TransitCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("vm-cache-\(UUID().uuidString)")))
        await model.refresh()
        return (model, settings)
    }

    @Test func matchesArrivalsToBusesClosestFirst() async throws {
        let (model, _) = await Self.makeModel { stub in
            // Two buses on line 41, one nearly at the stop and one well back.
            stub.busDistances = ["41": [2_000, 400]]
            stub.arrivalOffsets = ["41": [120, 900]]
        }
        let fortyOne = model.snapshot.arrivals.filter { $0.lineID == "41" }
        #expect(fortyOne.count == 2)
        let soonest = fortyOne[0].bus
        let later = fortyOne[1].bus
        #expect(soonest != nil)
        #expect(later != nil)
        #expect((soonest?.stopsAway ?? 99) < (later?.stopsAway ?? 0))
    }

    /// bus.gov.il draws every bus on the route but can leave one out of the timetable. A prediction
    /// that says where its bus is goes to that bus, and the bus it skipped gets a time of its own.
    @Test func aBusTheTimetableLeftOutIsEstimatedRatherThanGivenTheNextBussMinutes() async throws {
        let (model, _) = await Self.makeModel { stub in
            stub.identifiesVehicles = false
            stub.busDistances = ["41": [2_000, 400]]
            stub.arrivalOffsets = ["41": [660]]
            stub.arrivalBusDistances = ["41": [400]]
        }
        let fortyOne = model.snapshot.arrivals.filter { $0.lineID == "41" }
        let buses = model.snapshot.buses.filter { $0.lineID == "41" }
        let near = try #require(buses.min { $0.stopsAway < $1.stopsAway })
        let far = try #require(buses.max { $0.stopsAway < $1.stopsAway })
        #expect(fortyOne.count == 2)
        #expect(fortyOne.first?.bus?.id == near.id)
        #expect(fortyOne.last?.bus?.id == far.id)
        #expect(fortyOne.last?.expectedAt == Date(timeIntervalSince1970: 1_800_000_000 + 660))
        #expect((fortyOne.first?.expectedAt ?? .distantFuture) < (fortyOne.last?.expectedAt ?? .distantPast))
        // Worked out here rather than published, yet still from a live bus, not the timetable.
        #expect(fortyOne.first?.isEstimate == true)
        #expect(fortyOne.first?.isRealtime == true)
        #expect(fortyOne.last?.isEstimate == false)
    }

    @Test func aPredictionGoesToTheBusItNamesEvenWhenAnotherIsCloser() async throws {
        let (model, _) = await Self.makeModel { stub in
            stub.identifiesVehicles = false
            stub.busDistances = ["41": [2_000, 400]]
            stub.arrivalOffsets = ["41": [120, 900]]
            stub.arrivalBusDistances = ["41": [2_000, 400]]
        }
        let fortyOne = model.snapshot.arrivals.filter { $0.lineID == "41" }
        #expect(fortyOne.count == 2)
        #expect((fortyOne[0].bus?.stopsAway ?? 99) < (fortyOne[1].bus?.stopsAway ?? 0))
    }

    // MARK: Pairing predictions with buses

    private static let pairingNow = Date(timeIntervalSince1970: 1_800_000_000)
    /// The rider's stop on `straightRoad`.
    private static let pairingTarget = 4_000.0

    /// A point on `straightRoad`, which runs east along the equator so metres convert exactly.
    private static func roadPoint(_ meters: Double, offRoute: Double = 0) -> GeoPoint {
        GeoPoint(lat: offRoute / 6_371_000 * 180 / .pi, lon: meters / 6_371_000 * 180 / .pi)
    }

    /// Five kilometres of straight road with a stop every 500 m.
    private static func straightRoad() -> RouteGeometry {
        RouteGeometry(pattern: RoutePattern(
            line: TransitLine(id: "148", shortName: "148"),
            stops: (0...10).map { index in
                PatternStop(stop: TransitStop(code: "\(index)", name: "\(index)", city: nil,
                                              location: roadPoint(Double(index) * 500)),
                            sequence: index)
            }))
    }

    private static func bus(_ meters: Double, trip: String? = nil) -> TrackedBus {
        TrackedBus(id: "", vehicle: VehiclePosition(location: roadPoint(meters), tripId: trip),
                   distanceAlongRoute: meters, offRoute: 0, routeFraction: meters / 5_000, isNext: false)
    }

    private static func prediction(in seconds: TimeInterval, at location: GeoPoint?,
                                   realtime: Bool = true, trip: String? = nil) -> Arrival {
        Arrival(expectedAt: pairingNow.addingTimeInterval(seconds), scheduledAt: nil,
                isRealtime: realtime, tripId: trip, vehicleLocation: location)
    }

    private static func pair(_ arrivals: [Arrival], _ buses: [TrackedBus])
        -> [(arrival: Arrival, busIndex: Int?, isEstimate: Bool)] {
        BoardViewModel.pair(arrivals, with: buses, geometry: straightRoad(),
                            targetDistance: pairingTarget, now: pairingNow)
    }

    /// When no prediction lands near any drawn bus there is nothing to say which bus was left out,
    /// so order is used as before and no bus is given a time of its own.
    @Test func predictionsThatMatchNoBusFallBackToOrderWithoutEstimates() {
        let pairs = Self.pair([Self.prediction(in: 300, at: Self.roadPoint(2_300))],
                              [Self.bus(3_500), Self.bus(1_700)])
        #expect(pairs.count == 1)
        #expect(pairs.first?.busIndex == 0)
        #expect(pairs.allSatisfy { !$0.isEstimate })
    }

    /// A bare timetable slot says nothing about any bus. Allenby G, Haifa, 2026-09-28 21:40: a 112
    /// two stops out was shown as "35 MIN SCHEDULED", the slot after the one it was running, and the
    /// readout put a 148 half an hour away first. The bus gets a time of its own; the slot stays a slot.
    @Test func aTimetableSlotIsNotPinnedOnALiveBus() {
        let pairs = Self.pair([Self.prediction(in: 2_100, at: nil, realtime: false)], [Self.bus(3_300)])
        let estimate = pairs.first { $0.isEstimate }
        #expect(estimate?.busIndex == 0)
        #expect(estimate?.arrival.expectedAt == Self.pairingNow.addingTimeInterval(700 / BoardViewModel.fallbackBusSpeed))
        #expect(pairs.first { !$0.isEstimate }?.busIndex == nil)
        #expect(pairs.first?.isEstimate == true)
    }

    /// The slot the bus is running (late, or a little early) is the same bus; showing both would
    /// count it twice.
    @Test func theTimetableSlotALiveBusIsRunningIsNotShownBesideIt() {
        let pairs = Self.pair([Self.prediction(in: 60, at: nil, realtime: false),
                               Self.prediction(in: 1_800, at: nil, realtime: false)],
                              [Self.bus(3_300)])
        #expect(pairs.count == 2)
        #expect(pairs.first?.isEstimate == true)
        #expect(pairs.last?.arrival.expectedAt == Self.pairingNow.addingTimeInterval(1_800))
        #expect(pairs.last?.busIndex == nil)
    }

    /// A prediction with no position still has a bus; it takes the one its time puts it on, and that
    /// bus does not get a second row as if the timetable had missed it.
    @Test func aPredictionWithoutAPositionTakesTheBusItsTimePutsItOn() {
        let ahead = Self.pair([Self.prediction(in: 120, at: nil), Self.prediction(in: 400, at: Self.roadPoint(2_450))],
                              [Self.bus(3_500), Self.bus(2_500), Self.bus(1_500)])
        #expect(ahead.map(\.busIndex) == [0, 1])
        #expect(ahead.allSatisfy { !$0.isEstimate })

        // Due after a matched bus, it goes behind that bus rather than to the free one in front.
        let behind = Self.pair([Self.prediction(in: 120, at: Self.roadPoint(2_500)), Self.prediction(in: 400, at: nil)],
                               [Self.bus(3_500), Self.bus(2_500), Self.bus(1_500)])
        #expect(behind.filter { !$0.isEstimate }.map(\.busIndex) == [1, 2])
        #expect(behind.filter(\.isEstimate).map(\.busIndex) == [0])
    }

    /// The next trip's bus waiting at the origin is not drawn, so its prediction must not claim the
    /// drawn bus that has just left; neither may a position well off the route.
    @Test func aPredictionFromTheOriginOrOffTheRouteClaimsNoBus() {
        let origin = Self.pair([Self.prediction(in: 200, at: Self.roadPoint(3_000)),
                                Self.prediction(in: 900, at: Self.roadPoint(20))],
                               [Self.bus(3_000), Self.bus(300)])
        #expect(origin.map(\.busIndex) == [0, nil])

        let offRoute = Self.pair([Self.prediction(in: 200, at: Self.roadPoint(3_000)),
                                  Self.prediction(in: 900, at: Self.roadPoint(1_000, offRoute: 600))],
                                 [Self.bus(3_000), Self.bus(1_000)])
        #expect(offRoute.map(\.busIndex) == [0, nil])
    }

    /// A prediction's position is a sample older than the vehicle feed's, so on a clear road the bus
    /// can already be well past it. Line 112 at Allenby G, Haifa, 2026-10-02 08:39: the 08:43 trip
    /// still put its bus at the spot the bus had left a minute before, 536 m back. Left unmatched,
    /// that bus was given an estimate of its own and the readout showed it twice: "1 MIN" with no
    /// stops, then "3 MIN · 4 STOPS" for the same bus.
    @Test func aPredictionLaggingItsBusStillTakesIt() {
        let pairs = Self.pair([Self.prediction(in: 234, at: Self.roadPoint(2_000)),
                               Self.prediction(in: 354, at: Self.roadPoint(1_200))],
                              [Self.bus(2_536), Self.bus(1_215)])
        #expect(pairs.map(\.busIndex) == [0, 1])
        #expect(pairs.allSatisfy { !$0.isEstimate })
    }

    /// The next trip's bus a little behind a lagging position must not take it from the bus ahead
    /// that the position is about; that would leave the lead bus with a second, estimated time.
    @Test func aLaggingPredictionKeepsItsBusOverTheNextOneBehind() {
        let pairs = Self.pair([Self.prediction(in: 234, at: Self.roadPoint(2_000)),
                               Self.prediction(in: 354, at: Self.roadPoint(1_100))],
                              [Self.bus(2_536), Self.bus(1_600)])
        #expect(pairs.map(\.busIndex) == [0, 1])
        #expect(pairs.allSatisfy { !$0.isEstimate })
    }

    /// A bus that far behind a prediction's position is not that prediction's: buses do not run
    /// backwards, so the lag only ever puts the bus ahead.
    @Test func aPredictionDoesNotReachBackToABusFarBehindIt() {
        let pairs = Self.pair([Self.prediction(in: 120, at: Self.roadPoint(2_700)),
                               Self.prediction(in: 600, at: Self.roadPoint(1_000))],
                              [Self.bus(2_100), Self.bus(1_000)])
        #expect(pairs.first { !$0.isEstimate && $0.arrival.expectedAt == Self.pairingNow.addingTimeInterval(120) }?.busIndex == nil)
    }

    /// Where both feeds carry the trip id, the id decides, whatever the sampled position says.
    @Test func aSharedTripIdOutranksThePredictionsPosition() {
        let pairs = Self.pair([Self.prediction(in: 200, at: nil, trip: "a"),
                               Self.prediction(in: 500, at: Self.roadPoint(3_000), trip: "b")],
                              [Self.bus(3_000, trip: "a"), Self.bus(2_000, trip: "b")])
        #expect(pairs.map(\.busIndex) == [0, 1])
        #expect(pairs.allSatisfy { !$0.isEstimate })
    }

    /// Taken in time order, the sooner prediction would grab the bus the later one sits on and the
    /// two would swap; the closest pair is settled first instead.
    @Test func predictionsAndBusesArePairedClosestFirstSoTheyNeverCross() {
        let pairs = Self.pair([Self.prediction(in: 100, at: Self.roadPoint(2_800)),
                               Self.prediction(in: 300, at: Self.roadPoint(2_650))],
                              [Self.bus(3_000), Self.bus(2_700)])
        #expect(pairs.map(\.busIndex) == [0, 1])
    }

    /// A timetable time says nothing of how fast the bus is going, so the estimate uses city pace
    /// and is not pulled forward to it.
    @Test func anEstimateBorrowsNoPaceFromATimetableOnlyPrediction() {
        let pairs = Self.pair([Self.prediction(in: 60, at: Self.roadPoint(2_000), realtime: false)],
                              [Self.bus(3_600), Self.bus(2_000)])
        let estimate = pairs.first { $0.isEstimate }
        #expect(estimate?.busIndex == 0)
        #expect(estimate?.arrival.expectedAt == Self.pairingNow.addingTimeInterval(400 / BoardViewModel.fallbackBusSpeed))
    }

    /// One prediction implying a bus doing 144 km/h, or one standing still, would otherwise set
    /// the estimate for the bus ahead of it.
    @Test func aBorrowedPaceIsKeptToWhatABusCanDo() {
        let fast = Self.pair([Self.prediction(in: 50, at: Self.roadPoint(2_000))], [Self.bus(3_700), Self.bus(2_000)])
        #expect(fast.first { $0.isEstimate }?.arrival.expectedAt
                == Self.pairingNow.addingTimeInterval(300 / BoardViewModel.plausibleBusSpeeds.upperBound))

        let slow = Self.pair([Self.prediction(in: 2_000, at: Self.roadPoint(2_000))], [Self.bus(3_000), Self.bus(2_000)])
        #expect(slow.first { $0.isEstimate }?.arrival.expectedAt
                == Self.pairingNow.addingTimeInterval(1_000 / BoardViewModel.plausibleBusSpeeds.lowerBound))
    }

    /// A bus at the stop, or just past it, has had its trip dropped from the feed; it is not one
    /// the timetable forgot, and an estimate would read "now" as it drives away.
    @Test func aBusAtOrJustPastTheStopIsNotEstimated() {
        for position in [Self.pairingTarget, Self.pairingTarget + 20] {
            let pairs = Self.pair([Self.prediction(in: 300, at: Self.roadPoint(2_000))],
                                  [Self.bus(position), Self.bus(2_000)])
            #expect(pairs.count == 1)
            #expect(pairs.first?.busIndex == 1)
        }
    }

    @Test func unmatchedArrivalHasNoBus() async throws {
        let (model, _) = await Self.makeModel { stub in
            stub.busDistances = ["41": []]
            stub.arrivalOffsets = ["41": [300]]
        }
        #expect(model.snapshot.arrivals.first { $0.lineID == "41" }?.bus == nil)
    }

    @Test func primaryIsSoonestAndSecondaryIsNextAcrossLines() async throws {
        let (model, _) = await Self.makeModel { stub in
            stub.busDistances = ["41": [2_000], "18": [2_000]]
            stub.arrivalOffsets = ["41": [600], "18": [180]]
        }
        #expect(model.primary?.line.id == "18")
        #expect(model.primary?.kicker == .nextArrival)
        #expect(model.secondary?.line.id == "41")
    }

    @Test func swapTapMovesTheReadoutAndTheKicker() async throws {
        let (model, settings) = await Self.makeModel { stub in
            stub.busDistances = ["41": [2_000], "18": [2_000]]
            stub.arrivalOffsets = ["41": [600], "18": [180]]
        }
        settings.tapBehaviourOverride = .swap
        let other = model.snapshot.arrivals.first { $0.lineID == "41" }?.bus
        model.tap(busID: try #require(other).id)
        #expect(model.primary?.line.id == "41")
        #expect(model.primary?.kicker == .selectedBus)
        model.tap(busID: try #require(other).id)
        #expect(model.primary?.kicker == .nextArrival)
    }

    @Test func besideTapOpensADetailAndLeavesTheReadoutAlone() async throws {
        let (model, settings) = await Self.makeModel { stub in
            stub.busDistances = ["41": [2_000], "18": [2_000]]
            stub.arrivalOffsets = ["41": [600], "18": [180]]
        }
        settings.tapBehaviourOverride = .beside
        let other = model.snapshot.arrivals.first { $0.lineID == "41" }?.bus
        model.tap(busID: try #require(other).id)
        #expect(model.primary?.line.id == "18")
        #expect(model.tappedDetail?.line.id == "41")
        #expect(model.tappedDetail?.bus.lastStopName != nil)
        // In beside mode the ring moves to the tapped bus.
        #expect(model.ringedBusID == other?.id)
        model.dismissTapped()
        #expect(model.tappedDetail == nil)
    }

    @Test func anyTapOnTheBoardPutsTheSetupTipAway() async throws {
        let (model, _) = await Self.makeModel { stub in
            stub.busDistances = ["41": [2_000]]
            stub.arrivalOffsets = ["41": [600]]
        }
        model.showsSetupTip = true
        model.dismissTapped()
        #expect(!model.showsSetupTip)

        model.showsSetupTip = true
        let bus = model.snapshot.arrivals.first { $0.lineID == "41" }?.bus
        model.tap(busID: try #require(bus).id)
        #expect(!model.showsSetupTip)
    }

    @Test func staleAfterNinetySeconds() async throws {
        let (model, _) = await Self.makeModel { stub in
            stub.busDistances = ["41": [2_000]]
            stub.arrivalOffsets = ["41": [300]]
        }
        let updated = try #require(model.lastSuccessAt)
        #expect(model.liveState(at: updated.addingTimeInterval(89)) == .live)
        #expect(model.liveState(at: updated.addingTimeInterval(91)) == .stale)
    }

    @Test func lastGoodSnapshotSurvivesATotalFailure() async throws {
        let (model, settings) = await Self.makeModel { stub in
            stub.busDistances = ["41": [2_000]]
            stub.arrivalOffsets = ["41": [300]]
        }
        let before = model.snapshot.arrivals.count
        let success = try #require(model.lastSuccessAt)
        var failing = StubProvider()
        failing.failingLines = ["18", "41", "7"]
        settings.providerOverride = failing
        await model.refresh()
        #expect(model.snapshot.arrivals.count == before)
        #expect(model.lastSuccessAt == success)
        #expect(model.lastError != nil)
    }

    @Test func delayComesFromTheTimetableNotTheVehicle() async throws {
        let (model, _) = await Self.makeModel { stub in
            stub.busDistances = ["41": [2_000]]
            stub.arrivalOffsets = ["41": [300]]
            stub.scheduledOffsets = ["41": [180]]
        }
        let arrival = try #require(model.snapshot.arrivals.first { $0.lineID == "41" })
        #expect(abs(try #require(arrival.delay) - 120) < 1)
        #expect(DelayPhrase.text(for: arrival.delay) == "2 MIN LATE")
    }

    @Test func minutesRoundUpAndGoImminent() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let arrival = BoardArrival(id: "a", lineID: "41", expectedAt: now.addingTimeInterval(90),
                                   isRealtime: true, delay: nil, bus: nil)
        #expect(arrival.minutes(at: now) == 2)
        #expect(arrival.isImminent(at: now) == false)
        let soon = BoardArrival(id: "b", lineID: "41", expectedAt: now.addingTimeInterval(44),
                                isRealtime: true, delay: nil, bus: nil)
        #expect(soon.isImminent(at: now))
    }

    @Test func everyWatchedLineGetsADistinctColour() async throws {
        let (model, _) = await Self.makeModel { stub in
            stub.arrivalOffsets = ["41": [300]]
        }
        let indices = model.lines.map { model.colorIndex($0.id) }
        #expect(Set(indices).count == indices.count)
    }

    @Test func aLineThatFailsKeepsItsLastGoodNumbersWhileTheOthersRefresh() async throws {
        let (model, settings) = await Self.makeModel { stub in
            stub.busDistances = ["41": [2_000], "18": [2_000], "7": [2_000]]
            stub.arrivalOffsets = ["41": [600], "18": [300], "7": [900]]
        }
        #expect(model.snapshot.arrivals.count == 3)

        var partial = StubProvider()
        partial.busDistances = ["41": [2_000], "7": [2_000]]
        partial.arrivalOffsets = ["41": [660], "7": [960]]
        partial.failingLines = ["18"]
        settings.providerOverride = partial
        await model.refresh()

        // One arrival per line: 18's is the one from before, not a second copy of 41's.
        for lineID in ["18", "41", "7"] {
            #expect(model.snapshot.arrivals.filter { $0.lineID == lineID }.count == 1,
                    "expected exactly one arrival for \(lineID)")
            #expect(model.snapshot.buses.filter { $0.lineID == lineID }.count == 1)
        }
        #expect(model.lastError != nil)
    }

    @Test func aBusWithoutItsTimetableKeepsTheLastNumbersAndRetriesSoon() async throws {
        let (model, settings) = await Self.makeModel { stub in
            stub.busDistances = ["41": [2_000]]
            stub.arrivalOffsets = ["41": [600]]
        }
        #expect(model.snapshot.arrivals.count == 1)

        // Positions answer, the timetable does not: the bus stays and so do its minutes.
        var partial = StubProvider()
        partial.busDistances = ["41": [2_100]]
        partial.failingArrivals = ["41"]
        settings.providerOverride = partial
        await model.refresh()

        #expect(model.snapshot.buses.count == 1)
        #expect(model.snapshot.arrivals.count == 1)
        #expect(model.snapshot.arrivals.first?.bus != nil)
        #expect(model.lastError != nil)
        #expect(model.nextInterval() == BoardViewModel.quickRetrySeconds)
    }

    @Test func aBusOnItsWayWithAnEmptyTimetableIsTreatedAsAMissingAnswer() async throws {
        let (model, settings) = await Self.makeModel { stub in
            stub.busDistances = ["41": [2_000]]
            stub.arrivalOffsets = ["41": [600]]
        }

        var empty = StubProvider()
        empty.busDistances = ["41": [2_100]]
        settings.providerOverride = empty
        await model.refresh()

        #expect(model.snapshot.arrivals.count == 1)
        #expect(model.nextInterval() == BoardViewModel.quickRetrySeconds)
    }

    /// A morning where the timetable came back empty — with and without buses on the map — and
    /// then answered: the next refresh, a pull on the board, has to show the minutes.
    @Test(arguments: [[Double](), [2_000]])
    func aRefreshAfterAnEmptyTimetableShowsTheMinutes(buses: [Double]) async throws {
        let (model, settings) = await Self.makeModel { stub in
            stub.busDistances = ["41": buses]
        }
        #expect(model.snapshot.arrivals.isEmpty)

        var answered = StubProvider()
        answered.busDistances = ["41": buses]
        answered.arrivalOffsets = ["41": [600]]
        settings.providerOverride = answered
        await model.refresh()

        #expect(model.snapshot.arrivals.count == 1)
        #expect(model.primary != nil)
    }

    /// The debug log says what set each refresh off and, per line, what the feed returned against
    /// what the board showed — the two numbers that tell an empty feed from a board that lost times.
    @Test func eachRefreshIsWrittenToTheDebugLog() async throws {
        let (model, settings) = await Self.makeModel(lineIDs: ["41", "18"])
        let log = RefreshLog(file: nil)
        model.refreshLog = log

        var answered = StubProvider()
        answered.busDistances = ["41": [2_000]]
        answered.arrivalOffsets = ["41": [600]]
        answered.failingLines = ["18"]
        settings.providerOverride = answered
        await model.refresh(.pull)

        let entry = try #require(log.entries.first)
        #expect(log.entries.count == 1)
        #expect(entry.trigger == .pull)
        #expect(entry.outcome == .updated)
        let line41 = try #require(entry.lines.first { $0.name == "41" })
        #expect(line41.fromFeed == 1)
        #expect(line41.shown == 1)
        #expect(line41.buses == 1)
        #expect(line41.next != nil)
        let line18 = try #require(entry.lines.first { $0.name == "18" })
        #expect(line18.error != nil)
        #expect(line18.shown == nil)
    }

    @Test func aPullDuringARefreshIsLoggedAsJoiningIt() async throws {
        let (model, _) = await Self.makeModel { stub in
            stub.busDistances = ["41": [2_000]]
            stub.arrivalOffsets = ["41": [600]]
        }
        let log = RefreshLog(file: nil)
        model.refreshLog = log

        async let poll: Void = model.refresh(.poll)
        async let pull: Void = model.refresh(.pull)
        _ = await (poll, pull)

        #expect(log.entries.map(\.trigger).sorted { $0.rawValue < $1.rawValue } == [.poll, .pull])
        #expect(log.entries.contains { $0.outcome == .joined })
    }

    @Test func theDebugLogSurvivesARelaunch() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-log-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        RefreshLog(file: file).record(RefreshLogEntry(at: Date(), trigger: .foreground, stop: "S", provider: "p",
                                                      outcome: .failed))
        #expect(RefreshLog(file: file).entries.map(\.trigger) == [.foreground])
    }

    @Test func aCompleteAnswerPollsAtTheNormalPace() async throws {
        let (model, _) = await Self.makeModel { stub in
            stub.busDistances = ["41": [2_000]]
            stub.arrivalOffsets = ["41": [600]]
        }
        #expect(model.nextInterval() == 20)
    }

    @Test func aRouteThatCallsTwiceIsDrawnToTheSecondVisit() async throws {
        let defaults = UserDefaults(suiteName: "vm-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.providerOverride = LoopProvider()
        let stop = try #require(await LoopProvider().searchStops(query: MapFixtures.user).first)
        let lines = try await LoopProvider().lines(atStop: stop)
        settings.apply(stop: stop, lines: lines.filter { $0.id == "41" }, providerID: "loop")
        let model = BoardViewModel(settings: settings, cache: TransitCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("vm-cache-\(UUID().uuidString)")))
        await model.refresh()

        let pattern = try #require(model.snapshot.patterns["41"])
        #expect(pattern.stops.count == MapFixtures.line41Main.stops.count + 2)
        #expect(pattern.stops.last?.stop.code == MapFixtures.userCode)
        #expect(pattern.stops.filter { $0.stop.code == MapFixtures.userCode }.count == 2)
    }

    /// The board stops at the rider's stop; the full route view needs the rest of the way too.
    @Test func theFullRouteKeepsTheStopsPastTheRidersStop() async throws {
        let defaults = UserDefaults(suiteName: "vm-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.providerOverride = ThroughProvider()
        let stop = try #require(await ThroughProvider().searchStops(query: MapFixtures.user).first)
        let lines = try await ThroughProvider().lines(atStop: stop)
        settings.apply(stop: stop, lines: lines.filter { $0.id == "41" }, providerID: "through")
        let model = BoardViewModel(settings: settings, cache: TransitCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("vm-cache-\(UUID().uuidString)")))
        await model.refresh()

        let trimmed = try #require(model.snapshot.patterns["41"])
        let full = try #require(model.snapshot.fullPatterns["41"])
        #expect(trimmed.stops.last?.stop.code == MapFixtures.userCode)
        #expect(full.stops.count == trimmed.stops.count + 2)
        #expect(full.stops.last?.stop.code == "BEYOND-END")

        let input = try #require(model.fullRouteInputs().lines.first)
        #expect(input.stops.count == full.stops.count)
        #expect(input.userStopIndex == trimmed.stops.count - 1)
        #expect(model.hasFullRoute)

        // A stop past the rider's is still one the card can open.
        let card = try #require(model.stopCard(code: "BEYOND-1"))
        #expect(card.stop.name == "BEYOND-1")
        #expect(card.providerID == "through")
        #expect(card.watched.map(\.id) == ["41"])
        #expect(model.stopCard(code: "NOWHERE") == nil)
    }

    /// The full route survives a relaunch with the feed down, like the board's own routes.
    @Test func theFullRouteIsDrawnFromCacheToo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString)")
        let cache = TransitCache(directory: directory)
        let (warm, settings) = await Self.makeModel(cache: cache)
        #expect(warm.snapshot.fullPatterns.count == 3)

        let reopened = BoardViewModel(settings: settings, cache: cache)
        await reopened.showCachedRoutes()
        #expect(reopened.snapshot.fullPatterns.count == 3)
        #expect(reopened.fullRouteInputs().lines.count == 3)
    }

    @Test func theLastStopIsNamedAndTheElapsedTimeIsNotInvented() async throws {
        let (model, settings) = await Self.makeModel { stub in
            stub.busDistances = ["41": [2_000]]
            stub.arrivalOffsets = ["41": [300]]
        }
        let bus = try #require(model.snapshot.buses.first { $0.lineID == "41" })
        // The exact stop 2 km along line 41's route: a wrong index would name a different one.
        #expect(bus.lastStopName == "V 3")
        #expect(bus.stopsAway == 7)
        // First sighting: we did not watch it pass, so there is no elapsed time to report.
        #expect(bus.lastStopPassedAt == nil)
        #expect(LastStopPhrase.text(for: bus, at: .now) == "LEFT V 3")

        // Still no elapsed time on the next poll from the same position.
        await model.refresh()
        let again = try #require(model.snapshot.buses.first { $0.lineID == "41" })
        #expect(again.lastStopPassedAt == nil)
        #expect(LastStopPhrase.text(for: again, at: .now) == "LEFT V 3")

        // Once it moves on, the time is ours and the phrase can carry it.
        var moved = StubProvider()
        moved.busDistances = ["41": [3_000]]
        moved.arrivalOffsets = ["41": [120]]
        settings.providerOverride = moved
        await model.refresh()
        let after = try #require(model.snapshot.buses.first { $0.lineID == "41" })
        #expect(after.lastStopIndex > again.lastStopIndex)
        let passedAt = try #require(after.lastStopPassedAt)
        #expect(LastStopPhrase.text(for: after, at: passedAt) == "LEFT \(after.lastStopName ?? "") JUST NOW")
        #expect(LastStopPhrase.text(for: after, at: passedAt.addingTimeInterval(200))
                == "LEFT \(after.lastStopName ?? "") 3 MIN AGO")
    }

    @Test func lastStopPhraseNamesTheTerminusWhileTheBusIsStillOnIt() {
        let waiting = BoardBus(id: "a", lineID: "41", lastStopIndex: 0, progressToNext: 0,
                               stopsAway: 9, lastStopCode: "VISTA-PARK", lastStopName: "VISTA PARK",
                               lastStopPassedAt: nil, positionAge: nil)
        #expect(LastStopPhrase.text(for: waiting, at: .now) == "AT VISTA PARK")
        let unknown = BoardBus(id: "b", lineID: "41", lastStopIndex: 3, progressToNext: 0.5,
                               stopsAway: 4, lastStopCode: nil, lastStopName: nil,
                               lastStopPassedAt: nil, positionAge: nil)
        #expect(LastStopPhrase.text(for: unknown, at: .now) == nil)
    }

    @Test func punctualityIsOnlyClaimedWhenItIsMeasured() async throws {
        #expect(DelayPhrase.text(for: nil) == nil)
        // Under a minute there is nothing to say, so the segment is left out entirely.
        #expect(DelayPhrase.text(for: 20) == nil)
        #expect(DelayPhrase.text(for: -20) == nil)
        #expect(DelayPhrase.text(for: 120) == "2 MIN LATE")
        #expect(DelayPhrase.text(for: -150) == "3 MIN EARLY")
        #expect(DelayPhrase.isLate(120))
        #expect(DelayPhrase.isLate(-120) == false)
        #expect(DelayPhrase.isLate(nil) == false)
    }

    @Test func aTimetableOnlyArrivalCarriesNoDelay() async throws {
        let (model, _) = await Self.makeModel { stub in
            stub.busDistances = ["41": [2_000]]
            stub.arrivalOffsets = ["41": [300]]
            stub.scheduledOffsets = ["41": [180]]
            stub.arrivalsAreRealtime = false
        }
        let arrival = try #require(model.snapshot.arrivals.first { $0.lineID == "41" })
        #expect(arrival.isRealtime == false)
        #expect(arrival.delay == nil)
        #expect(DelayPhrase.text(for: arrival.delay) == nil)
    }

    @Test func imminentAndMinutesAtTheirBoundaries() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func arrival(_ seconds: TimeInterval) -> BoardArrival {
            BoardArrival(id: "a", lineID: "41", expectedAt: now.addingTimeInterval(seconds),
                         isRealtime: true, delay: nil, bus: nil)
        }
        #expect(arrival(45).isImminent(at: now) == false)
        #expect(arrival(44).isImminent(at: now))
        #expect(arrival(60).minutes(at: now) == 1)
        #expect(arrival(61).minutes(at: now) == 2)
        #expect(arrival(-30).minutes(at: now) == 0)
    }

    @Test func countdownTurnsToHoursAtTheHour() {
        #expect(Countdown(minutes: 59).figure == "59")
        #expect(Countdown(minutes: 59).isHours == false)
        #expect(Countdown(minutes: 60).figure == "1:00")
        #expect(Countdown(minutes: 75).figure == "1:15")
        #expect(Countdown(minutes: 75).isHours)
        #expect(Countdown(minutes: 125).figure == "2:05")
    }

    @Test func theBoardSaysItIsConnectingUntilTheFirstAnswer() async throws {
        let defaults = UserDefaults(suiteName: "vm-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        var failing = StubProvider()
        failing.failingLines = ["18", "41", "7"]
        settings.providerOverride = failing
        let stop = try #require(await failing.searchStops(query: MapFixtures.user).first)
        settings.apply(stop: stop, lines: try await failing.lines(atStop: stop), providerID: "stub")
        let model = BoardViewModel(settings: settings, cache: TransitCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("vm-cache-\(UUID().uuidString)")))
        #expect(model.liveState(at: .now) == .connecting)
        await model.refresh()
        #expect(model.liveState(at: .now) == .connecting)
        #expect(model.lastError != nil)
    }

    @Test func aSelectionIsDroppedRatherThanSilentlyMovedToAnotherBus() async throws {
        let (model, settings) = await Self.makeModel { stub in
            stub.identifiesVehicles = false
            stub.busDistances = ["41": [1_000, 2_000, 3_000]]
            stub.arrivalOffsets = ["41": [120, 480, 900]]
        }
        settings.tapBehaviourOverride = .beside
        // With no plate and no trip id the ids are ranks, closest to the stop first.
        #expect(model.snapshot.buses.contains { $0.id == "41-rank1" })
        model.tap(busID: "41-rank1")
        #expect(model.tappedDetail?.bus.id == "41-rank1")

        // The leading bus reaches the stop and drops out; every remaining rank shifts down one.
        var moved = StubProvider()
        moved.identifiesVehicles = false
        moved.busDistances = ["41": [1_000, 2_000]]
        moved.arrivalOffsets = ["41": [120, 480]]
        settings.providerOverride = moved
        await model.refresh()

        #expect(model.snapshot.buses.contains { $0.id == "41-rank1" })
        #expect(model.selectedBusID == nil)
        #expect(model.tappedDetail == nil)
    }

    /// Everything but the buses themselves is already known by the second time a stop is opened,
    /// so the map has no reason to wait for the network to draw itself.
    @Test func routesAreDrawnFromCacheBeforeAnyRequest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-\(UUID().uuidString)")
        let cache = TransitCache(directory: directory)
        let (warm, settings) = await Self.makeModel(cache: cache) { stub in
            stub.busDistances = ["41": [2_000]]
            stub.arrivalOffsets = ["41": [300]]
        }
        #expect(warm.snapshot.patterns.count == 3)

        // Open the same board again with the feed completely down.
        var dead = StubProvider()
        dead.failingLines = ["18", "41", "7"]
        settings.providerOverride = dead
        let reopened = BoardViewModel(settings: settings, cache: cache)
        #expect(reopened.snapshot.patterns.isEmpty)

        await reopened.showCachedRoutes()
        #expect(reopened.snapshot.patterns.count == 3)
        #expect(reopened.mapInputs().lines.count == 3)
        // Routes, yes; buses and times, no — those are the one thing that is never cached.
        #expect(reopened.snapshot.buses.isEmpty)
        #expect(reopened.snapshot.arrivals.isEmpty)
        #expect(reopened.liveState(at: .now) == .connecting)
    }

    @Test func cachedRoutesNeverOverwriteLiveOnes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-\(UUID().uuidString)")
        let cache = TransitCache(directory: directory)
        let (model, _) = await Self.makeModel(cache: cache) { stub in
            stub.busDistances = ["41": [2_000]]
            stub.arrivalOffsets = ["41": [300]]
        }
        let arrivals = model.snapshot.arrivals.count
        #expect(arrivals > 0)
        await model.showCachedRoutes()
        #expect(model.snapshot.arrivals.count == arrivals)
    }

    @Test func changingTheStopDropsTheOldBoard() async throws {
        let (model, settings) = await Self.makeModel { stub in
            stub.busDistances = ["41": [2_000]]
            stub.arrivalOffsets = ["41": [300]]
        }
        #expect(model.snapshot.patterns.isEmpty == false)
        #expect(model.lastSuccessAt != nil)
        let firstStop = try #require(model.stop).code

        // The same line at a different stop is the dangerous case: the ids still match, so nothing
        // would look obviously wrong while the map drew the previous stop's route and ETAs.
        let provider = settings.provider
        let other = try #require(await provider.searchStops(query: "BELL TOWER").first)
        #expect(other.code != firstStop)
        let lines = try await provider.lines(atStop: other)
        settings.apply(stop: other, lines: Array(lines.prefix(1)), providerID: "stub")
        model.configurationChanged()

        #expect(model.stop?.code == other.code)
        #expect(model.snapshot.patterns.isEmpty)
        #expect(model.snapshot.arrivals.isEmpty)
        #expect(model.snapshot.buses.isEmpty)
        #expect(model.lastSuccessAt == nil)
        #expect(model.trunkLineID == nil)
        #expect(model.mapInputs().lines.isEmpty)

        await model.refresh()
        for line in model.mapInputs().lines {
            #expect(line.stops.last?.code == other.code)
        }
    }

    @Test func changingTheStopClearsASelectedBus() async throws {
        let (model, settings) = await Self.makeModel { stub in
            stub.busDistances = ["41": [2_000]]
            stub.arrivalOffsets = ["41": [300]]
        }
        let bus = try #require(model.snapshot.buses.first)
        model.tap(busID: bus.id)
        #expect(model.selectedBusID != nil)

        let provider = settings.provider
        let other = try #require(await provider.searchStops(query: "BELL TOWER").first)
        settings.apply(stop: other, lines: Array(try await provider.lines(atStop: other).prefix(1)),
                       providerID: "stub")
        model.configurationChanged()
        #expect(model.selectedBusID == nil)
    }

    @Test func mapInputsStopAtTheRidersStop() async throws {
        let (model, _) = await Self.makeModel { stub in
            stub.busDistances = ["41": [2_000]]
            stub.arrivalOffsets = ["41": [300]]
        }
        let inputs = model.mapInputs()
        #expect(inputs.lines.count == 3)
        for line in inputs.lines {
            #expect(line.stops.last?.code == MapFixtures.userCode)
        }
    }
}
