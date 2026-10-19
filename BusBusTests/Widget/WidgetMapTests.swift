import Testing
import Foundation
import CoreGraphics
import WidgetKit
@testable import BusBus

/// The larger widgets' map: the routes the app saves for it, where its buses are as the countdown
/// runs, and that it fits the box it is given.
struct WidgetMapTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func line(_ id: String) -> TransitLine {
        TransitLine(id: id, shortName: id, headsign: nil, agency: nil, origin: nil, destination: nil,
                    isAccessible: nil, brandColorIndex: nil)
    }

    /// HARBOR GATE watching the Main artboard's three lines.
    private var setup: SavedSetup {
        SavedSetup(stop: TransitStop(code: MapFixtures.userCode, name: MapFixtures.user, city: nil,
                                     location: GeoPoint(lat: 32, lon: 34)),
                   lines: [line("18"), line("41"), line("7")], lastUsedAt: now)
    }

    private var routes: WidgetRoutes {
        WidgetRoutes(setupID: setup.id, lines: Dictionary(uniqueKeysWithValues: MapFixtures.main.map { ($0.id, $0.stops) }))
    }

    private func arrival(_ line: String, in seconds: TimeInterval, stopsAway: Int?, progress: Double? = nil) -> WidgetArrival {
        WidgetArrival(lineID: line, expectedAt: now.addingTimeInterval(seconds), isRealtime: true,
                      stopsAway: stopsAway, progressToNext: progress, busID: stopsAway.map { "\(line)-bus\($0)" })
    }

    // MARK: Stored routes

    @Test func routesRoundTripThroughJSON() throws {
        let decoded = try JSONDecoder().decode(WidgetRoutes.self, from: JSONEncoder().encode(routes))
        #expect(decoded == routes)
    }

    @Test func routesKeepOnlyWhatTheMapDraws() {
        let stop = setup.stop
        func pattern(_ id: String, _ codes: [String]) -> RoutePattern {
            RoutePattern(line: line(id), stops: codes.enumerated().map { index, code in
                PatternStop(stop: TransitStop(code: code, name: "Stop \(code)", city: nil, location: stop.location),
                            sequence: index + 1, distanceAlongRoute: nil)
            })
        }
        let routes = WidgetRoutes(setupID: "x", patterns: ["18": pattern("18", ["A", "B", stop.code]),
                                                           "41": pattern("41", [stop.code])])
        #expect(routes.lines["18"]?.map(\.code) == ["A", "B", stop.code])
        #expect(routes.lines["18"]?.first?.name == "Stop A")
        // One stop is not a route.
        #expect(routes.lines["41"] == nil)
    }

    /// Snapshots written before the map existed still decode: the positions are simply unknown.
    @Test func olderSnapshotsDecodeWithoutPositions() throws {
        let json = #"{"lineID":"18","expectedAt":800000000,"isRealtime":true,"stopsAway":3}"#
        let decoded = try JSONDecoder().decode(WidgetArrival.self, from: Data(json.utf8))
        #expect(decoded.stopsAway == 3)
        #expect(decoded.progressToNext == nil)
        #expect(decoded.busID == nil)
    }

    @Test func storeSavesOnlyWhatChangedAndPrunesWithTheHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "routes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetRouteStore(directory: directory)
        let other = WidgetRoutes(setupID: "99|5", lines: ["5": [MapStopInput(code: "A", name: "A"),
                                                                MapStopInput(code: "99", name: "B")]])

        #expect(store.save(routes))
        #expect(!store.save(routes), "the same routes again are not rewritten")
        #expect(store.save(other))
        #expect(store.load(setupID: setup.id) == routes)

        store.prune(keeping: [other.setupID])
        #expect(store.load(setupID: setup.id) == nil)
        #expect(store.load(setupID: other.setupID) == other)
    }

    @Test func noDirectoryIsANoOp() {
        let store = WidgetRouteStore(directory: nil)
        #expect(!store.save(routes))
        #expect(store.load(setupID: setup.id) == nil)
        store.prune(keeping: [])
    }

    // MARK: Buses over time

    /// Three stops out on a route of eleven stops (the rider's is index 10), a quarter of the way
    /// on from the last it passed, due in six minutes.
    @Test func aBusMovesOnToTheStopWithItsCountdown() throws {
        let bus = arrival("18", in: 360, stopsAway: 3, progress: 0.25)
        func along(at seconds: TimeInterval) throws -> Double {
            let position = try #require(WidgetMap.position(of: bus, stopCount: 11, fetchedAt: now,
                                                           at: now.addingTimeInterval(seconds)))
            return Double(position.lastStopIndex) + position.progressToNext
        }
        // Where the board saw it, and never behind that.
        #expect(try along(at: 0) == 7.25)
        #expect(try along(at: -120) == 7.25)
        // Halfway through its wait, halfway through the stops it had left.
        #expect(try abs(along(at: 180) - 8.625) < 1e-9)
        // Due: on the last stretch into the rider's stop, where the engine holds it short of the node.
        let due = try #require(WidgetMap.position(of: bus, stopCount: 11, fetchedAt: now, at: bus.expectedAt))
        #expect(due.lastStopIndex == 9 && due.progressToNext == 1)
        #expect(try along(at: 600) == 10)
    }

    /// The sub-line's count goes down with the puck: 2.75 stops to go, then half of that, then one.
    @Test func theStopsToGoCountDownWithIt() {
        let bus = arrival("18", in: 360, stopsAway: 3, progress: 0.25)
        func stops(at seconds: TimeInterval) -> Int? {
            WidgetMap.stopsAway(of: bus, fetchedAt: now, at: now.addingTimeInterval(seconds))
        }
        #expect(stops(at: 0) == 3)
        #expect(stops(at: 180) == 2)
        #expect(stops(at: 300) == 1)
        #expect(stops(at: 360) == 1)
        #expect(WidgetMap.stopsAway(of: arrival("18", in: 60, stopsAway: nil), fetchedAt: now, at: now) == nil)
    }

    @Test func aBusWithNoPositionIsNotPlaced() {
        #expect(WidgetMap.position(of: arrival("18", in: 60, stopsAway: nil), stopCount: 11,
                                   fetchedAt: now, at: now) == nil)
    }

    @Test func eachLineShowsItsNextBusAndTheReadoutsCarriesTheRing() throws {
        let arrivals = [arrival("41", in: 120, stopsAway: 1), arrival("18", in: 480, stopsAway: 4),
                        arrival("41", in: 660, stopsAway: 6), arrival("7", in: 900, stopsAway: nil)]
        let frame = try #require(WidgetMap.frame(setup: setup, routes: routes, arrivals: arrivals, fetchedAt: now,
                                                 liveness: .live, palette: [:], date: now))
        #expect(frame.lines.map(\.id) == ["18", "41", "7"])
        #expect(frame.trunkLineID == "41")
        #expect(frame.vehicles.map(\.lineID) == ["41", "18"])
        #expect(frame.vehicles.map(\.isSelected) == [true, false])
        #expect(!frame.vehiclesAreStale)
    }

    @Test func oldNumbersDimTheBusesAndExpiredOnesDropThem() throws {
        let arrivals = [arrival("41", in: 120, stopsAway: 1)]
        let stale = try #require(WidgetMap.frame(setup: setup, routes: routes, arrivals: arrivals, fetchedAt: now,
                                                 liveness: .stale(asOf: now), palette: [:], date: now))
        #expect(stale.vehiclesAreStale && stale.vehicles.count == 1)
        let expired = try #require(WidgetMap.frame(setup: setup, routes: routes, arrivals: arrivals, fetchedAt: now,
                                                   liveness: .expired, palette: [:], date: now))
        #expect(expired.vehicles.isEmpty)
        #expect(expired.lines.count == 3, "the rails stay")
    }

    @Test func routesForAnotherStopOrNoneDrawNothing() {
        #expect(WidgetMap.frame(setup: setup, routes: nil, arrivals: [], fetchedAt: nil,
                                liveness: .live, palette: [:], date: now) == nil)
        var elsewhere = routes
        elsewhere.setupID = "OTHER|18"
        #expect(!WidgetMap.canDraw(setup, routes: elsewhere))
        // A line whose saved route no longer ends at the stop is left off the map.
        var shortened = routes
        shortened.lines["7"]?.removeLast()
        #expect(WidgetMap.frame(setup: setup, routes: shortened, arrivals: [], fetchedAt: nil,
                                liveness: .expired, palette: [:], date: now)?.lines.map(\.id) == ["18", "41"])
    }

    /// The timeline's pictures carry the map, and the bus the readout counts down to moves closer
    /// in each of them.
    @Test func theTimelinesPucksAdvance() throws {
        let snapshot = WidgetSnapshot(setupID: setup.id, fetchedAt: now,
                                      arrivals: [arrival("41", in: 400, stopsAway: 3, progress: 0)])
        let entries = NextBusTimeline.entries(
            history: [setup], chosenID: setup.id, snapshot: snapshot, routes: routes,
            layout: WidgetLayout.for(.systemLarge, content: .map, hasMap: true),
            palette: [:], appearance: .dark, now: now)
        let positions = entries.compactMap { entry in
            entry.map?.vehicles.first.map { Double($0.lastStopIndex) + $0.progressToNext }
        }
        #expect(positions.count > 3)
        #expect(zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 })
        #expect(entries.allSatisfy { $0.content == .map && $0.map != nil })
    }

    // MARK: Fitting

    /// Every artboard topology, one to three lines, with buses near both ends, in every box a large
    /// or extra large widget gives its map: inside the box, no text on text, nothing under a badge.
    ///
    /// The large widget's map has what the header and the one-row readout leave of the content
    /// (about 97 pt), from the smallest iPhone's to the iPad's; the extra large one's is a column,
    /// from the iPad mini's to the 13" iPad's. A little below the smallest, for safety.
    @Test(arguments: MockScenario.allCases)
    func theMapFitsEveryBox(scenario: MockScenario) {
        let boxes = [CGSize(width: 260, height: 172), CGSize(width: 260, height: 182), CGSize(width: 289, height: 195),
                     CGSize(width: 306, height: 225), CGSize(width: 332, height: 253), CGSize(width: 346, height: 249),
                     CGSize(width: 291, height: 273), CGSize(width: 331, height: 298), CGSize(width: 350, height: 350),
                     CGSize(width: 371, height: 346)]
        let all = scenario.lines
        for count in 1...all.count {
            let lines = Array(all.prefix(count))
            let vehicles = lines.flatMap { line in
                [MapVehicleInput(id: "\(line.id)-a", lineID: line.id, lastStopIndex: 1, progressToNext: 0.5),
                 MapVehicleInput(id: "\(line.id)-b", lineID: line.id, lastStopIndex: line.stops.count - 2,
                                 progressToNext: 0.9, isSelected: line.id == lines[0].id)]
            }
            let frame = WidgetMapFrame(lines: lines, trunkLineID: lines[0].id, userStopCode: MapFixtures.userCode,
                                       vehicles: vehicles, vehiclesAreStale: false)
            for box in boxes {
                let label = "\(scenario) \(count) lines in \(Int(box.width))×\(Int(box.height))"
                let scene = WidgetMapLayout.scene(for: frame, in: box)
                let bounds = scene.drawnBounds(captions: .english)
                #expect(bounds.minX >= -0.5 && bounds.maxX <= box.width + 0.5, "\(label): \(bounds) wide")
                #expect(bounds.minY >= -0.5 && bounds.maxY <= box.height + 0.5, "\(label): \(bounds) tall")
                #expect(!scene.hasCollidingText(captions: .english), "\(label): text collides")
                #expect(!scene.rails.isEmpty, "\(label): nothing drawn")
            }
        }
    }
}
