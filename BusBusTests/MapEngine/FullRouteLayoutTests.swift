import Testing
import CoreGraphics
@testable import BusBus

private func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.5) -> Bool { abs(a - b) <= tolerance }

/// A line whose stops are its own, except the rider's, which every line shares as in real data.
private func line(_ id: String, stops count: Int, userAt userIndex: Int, colorIndex: Int = 0) -> FullRouteLineInput {
    FullRouteLineInput(id: id, number: id, colorIndex: colorIndex,
                       stops: (0..<count).map { $0 == userIndex ? MapStopInput(code: "USER", name: "Harbor Gate")
                                                                : MapStopInput(code: "\(id)-\($0)", name: "Stop \($0)") },
                       userStopIndex: userIndex)
}

/// A line from stop codes, the rider's stop given by its code.
private func route(_ id: String, _ codes: [String], user: String = "USER") -> FullRouteLineInput {
    FullRouteLineInput(id: id, number: id, colorIndex: 0,
                       stops: codes.map { MapStopInput(code: $0, name: $0) },
                       userStopIndex: codes.lastIndex(of: user) ?? codes.count - 1)
}

/// One of the board's fixtures, every route ending at the rider's stop.
private func fixture(_ lines: [MapLineInput]) -> [FullRouteLineInput] {
    lines.map { FullRouteLineInput(id: $0.id, number: $0.number, colorIndex: $0.colorIndex, stops: $0.stops,
                                   userStopIndex: $0.stops.count - 1) }
}

private extension FullRouteScene {
    func line(_ id: String) -> FullRouteLine? { lines.first { $0.lineID == id } }
    func stop(_ code: String) -> FullRouteStop? { stops.first { $0.code == code } }
}

private let wide = CGSize(width: 844, height: 300)
private let tall = CGSize(width: 600, height: 700)

struct FullRouteLayoutTests {

    // MARK: Every stop, no folds

    @Test func everyStopIsDrawnEvenlyWithNothingFolded() throws {
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: [line("41", stops: 60, userAt: 40)],
                                                            axis: .horizontal, viewport: wide))
        let route = try #require(scene.line("41"))
        #expect(route.stopCenters.count == 60)
        #expect(scene.stops.count == 60)
        for (a, b) in zip(route.stopCenters, route.stopCenters.dropFirst()) {
            #expect(close(b.x - a.x, FullRouteLayout.horizontalPitch))
            #expect(close(b.y, a.y))
        }
        #expect(route.segments.allSatisfy { !$0.bends })
        // The content is as long as the route, not the screen.
        #expect(scene.contentSize.width > 59 * FullRouteLayout.horizontalPitch)
    }

    @Test func theRidersStopAndWhatComesAfterIt() throws {
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: [line("41", stops: 10, userAt: 6)],
                                                            axis: .horizontal, viewport: wide))
        #expect(scene.stop("USER")?.role == .userStop)
        #expect(scene.stop("41-9")?.role == .lastStop)
        #expect(scene.stops.filter(\.isPastUserStop).map(\.code) == ["41-7", "41-8", "41-9"])
        let route = try #require(scene.line("41"))
        #expect(route.segments.map(\.faded) == [false, false, false, false, false, false, true, true, true])
    }

    // MARK: Lines on their own

    @Test func independentStretchesRunSideBySideNotEndToEnd() throws {
        // Three lines with nothing in common but the rider's stop: their own stops share columns,
        // so the content is as long as the longest, not all three laid end to end.
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: fixture(MapFixtures.main), axis: .vertical,
                                                            viewport: tall))
        let longest = MapFixtures.main.map(\.stops.count).max()!
        #expect(scene.userStopAlong < FullRouteLayout.verticalPitch * CGFloat(longest + 6))
        let seven = try #require(scene.line("7")), eighteen = try #require(scene.line("18"))
        // Each line keeps its own lane until the rider's stop.
        #expect(Set(seven.stopCenters.dropLast().map(\.x)).count == 1)
        #expect(Set(eighteen.stopCenters.dropLast().map(\.x)).count == 1)
        #expect(seven.stopCenters[0].x != eighteen.stopCenters[0].x)
    }

    @Test func everyLineMeetsAtTheRidersStop() throws {
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: fixture(MapFixtures.main), axis: .vertical,
                                                            viewport: tall))
        let node = try #require(scene.stop(MapFixtures.userCode))
        #expect(node.role == .userStop)
        #expect(node.lineIDs.count == 3)
        #expect(Set(node.memberCenters.map(\.y)).count == 1)
        // Side by side, a rail's width and a sliver apart.
        let xs = node.memberCenters.map(\.x).sorted()
        #expect(close(xs[1] - xs[0], FullRouteLayout.bundleSpacing))
        #expect(close(xs[2] - xs[1], FullRouteLayout.bundleSpacing))
        // Coming in from their lanes, the lines bend; a bend gets more than a stop's length.
        for route in scene.lines where route.segments.last?.bends == true {
            let last = route.segments[route.segments.count - 1]
            #expect(last.to.y - last.from.y > FullRouteLayout.verticalPitch)
        }
    }

    // MARK: Merging and parting

    @Test func linesSharingAStretchRunTogetherWithOneMarkAndName() throws {
        // Merge B: 18 joins 41 at BELL TOWER; 7 joins both at PIER FOUR.
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: fixture(MapFixtures.mergeB), axis: .vertical,
                                                            viewport: tall))
        #expect(scene.stop("CIVIC-CTR")?.lineIDs == ["18"])
        let bell = try #require(scene.stop("BELL-TOWER"))
        #expect(Set(bell.lineIDs) == ["18", "41"])
        #expect(scene.stops.filter { $0.code == "BELL-TOWER" }.count == 1)
        let pier = try #require(scene.stop("PIER-FOUR"))
        #expect(Set(pier.lineIDs) == ["18", "41", "7"])
        // A capsule across the bundle, one rail's spacing per line.
        let xs = pier.memberCenters.map(\.x).sorted()
        #expect(close(xs.last! - xs.first!, 2 * FullRouteLayout.bundleSpacing))
        // Its name starts after the last rail of the bundle.
        #expect(pier.labelAnchor.x > xs.last!)
    }

    @Test func aLineLeavesItsLaneToJoinAndTheBendIsACurve() throws {
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: fixture(MapFixtures.mergeB), axis: .vertical,
                                                            viewport: tall))
        let seven = try #require(scene.line("7"))
        // 7 runs on its own lane, then bends into the bundle at PIER FOUR.
        let joinIndex = try #require(MapFixtures.line7B.stops.firstIndex { $0.code == "PIER-FOUR" })
        let into = seven.segments[joinIndex - 1]
        #expect(into.bends)
        #expect(into.from.x != into.to.x)
        #expect(!seven.segments[0].bends)
    }

    @Test func anExpressStaysInTheBundlePastAStopItSkips() throws {
        // A calls at X; B runs straight through. B is not drawn leaving A for one stop.
        let a = route("A", ["a1", "S1", "X", "S2", "USER"])
        let b = route("B", ["b1", "S1", "S2", "USER"])
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: [a, b], axis: .vertical, viewport: tall))
        #expect(scene.stop("X")?.lineIDs == ["A"])
        let lineA = try #require(scene.line("A"))
        // S1, X and S2 all on A's slot of the bundle.
        #expect(close(lineA.stopCenters[1].x, lineA.stopCenters[2].x))
        #expect(close(lineA.stopCenters[2].x, lineA.stopCenters[3].x))
        #expect(!lineA.segments[1].bends && !lineA.segments[2].bends)
        let lineB = try #require(scene.line("B"))
        #expect(!lineB.segments[1].bends)
    }

    @Test func linesPartAgainAfterTheRidersStop() throws {
        let a = route("A", ["a1", "USER", "P1", "P2", "A-END"])
        let b = route("B", ["b1", "USER", "P1", "P2", "B-END"])
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: [a, b], axis: .vertical, viewport: tall))
        #expect(Set(scene.stop("P2")?.lineIDs ?? []) == ["A", "B"])
        #expect(scene.stop("P2")?.isPastUserStop == true)
        #expect(scene.stop("A-END")?.lineIDs == ["A"])
        let lineA = try #require(scene.line("A")), lineB = try #require(scene.line("B"))
        // The last stops sit in their own lanes, apart.
        #expect(abs(lineA.stopCenters[4].x - lineB.stopCenters[4].x) > FullRouteLayout.bundleSpacing * 2)
        #expect(lineB.segments[3].bends)
        #expect(lineB.segments[3].faded)
    }

    @Test func linesThatShareSitInNeighbouringLanes() throws {
        // A and C share a corridor; B, picked in between, has nothing to do with them. B gives up
        // the middle lane so that C does not have to cross it to reach A.
        let a = route("A", ["a1", "a2", "M1", "M2", "M3", "USER"])
        let b = route("B", ["b1", "b2", "b3", "b4", "b5", "USER"])
        let c = route("C", ["c1", "c2", "M1", "M2", "M3", "USER"])
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: [a, b, c], axis: .vertical, viewport: tall))
        let homes = ["A", "B", "C"].map { scene.line($0)!.stopCenters[0].x }
        #expect(!(homes[1] > min(homes[0], homes[2]) && homes[1] < max(homes[0], homes[2])))
    }

    /// One line in landscape sits in the middle of the view with its names, not along its foot:
    /// the band from the top of the climbing names to the buses under the rail is centred.
    @Test func aLandscapeLineAndItsNamesSitInTheMiddle() throws {
        for viewport in [wide, CGSize(width: 1180, height: 700)] {
            let scene = FullRouteLayout.layout(FullRouteRequest(lines: [line("41", stops: 12, userAt: 8)],
                                                                axis: .horizontal, viewport: viewport))
            let rail = try #require(scene.line("41")).stopCenters[0].y
            let middle = ((rail - FullRouteLayout.horizontalNameRise) + (rail + FullRouteLayout.horizontalBelowRail)) / 2
            #expect(close(middle, viewport.height / 2), "\(viewport): drawing centred at \(middle)")
            #expect(rail - FullRouteLayout.horizontalNameRise >= -0.5, "\(viewport): names cut off")
            #expect(scene.contentSize.height <= viewport.height + 0.5)
        }
    }

    /// Lanes that do not fit are not raised past the room the top lane's names need.
    @Test func crowdedLandscapeLanesKeepTheirNamesRoom() throws {
        let lines = (0..<3).map { line("L\($0)", stops: 8, userAt: 5, colorIndex: $0) }
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: lines, axis: .horizontal, viewport: wide))
        let top = scene.lines.flatMap(\.stopCenters).map(\.y).min() ?? 0
        #expect(top - FullRouteLayout.horizontalNameRise >= -0.5)
    }

    @Test func landscapeGathersABundleOnItsLowestLaneSoNamesRiseIntoTheEmptiedOnes() throws {
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: fixture(MapFixtures.mergeB), axis: .horizontal,
                                                            viewport: wide))
        let bell = try #require(scene.stop("BELL-TOWER"))
        let ys = bell.memberCenters.map(\.y)
        #expect(close(ys.max()! - ys.min()!, FullRouteLayout.bundleSpacing))
        #expect(bell.labelAnchor.y < ys.min()!)
        #expect(scene.labelRotation == -35)
    }

    @Test func aNameStopsShortOfALineBendingAcrossIt() throws {
        // Corridor, landscape: 41 bends down into 18's lane just after CIVIC CTR, through the
        // space CIVIC CTR's name climbs into.
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: fixture(MapFixtures.corridorPair), axis: .horizontal,
                                                            viewport: CGSize(width: 844, height: 300)))
        let civic = try #require(scene.stop("CIVIC-CTR"))
        let fortyOne = try #require(scene.line("41"))
        let angle = 35 * CGFloat.pi / 180
        let thickness = 2 * scene.labelFontSize * 1.25 / cos(angle)
        for segment in fortyOne.segments where segment.bends {
            for step in 0...40 {
                let p = segment.point(at: CGFloat(step) / 40)
                let dx = p.x - civic.labelAnchor.x
                guard dx >= 0, dx <= civic.labelMaxWidth * cos(angle) else { continue }
                let baseline = civic.labelAnchor.y - dx * tan(angle)
                #expect(!(p.y > baseline - thickness && p.y < civic.labelAnchor.y), "41 crosses the name at \(p)")
            }
        }
    }

    // MARK: Lanes and names

    @Test func portraitNamesStopShortOfTheNextRail() throws {
        let lines = [line("41", stops: 20, userAt: 10), line("18", stops: 20, userAt: 10), line("7", stops: 20, userAt: 10)]
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: lines, axis: .vertical, viewport: tall))
        #expect(close(scene.contentSize.width, 600))
        #expect(scene.labelRotation == 0)
        let rails = scene.lines.map { $0.stopCenters[0].x }.sorted()
        for stop in scene.stops where !stop.isShared && !stop.isPastUserStop {
            let next = rails.first { $0 > stop.center.x + 1 } ?? scene.contentSize.width
            #expect(stop.labelAnchor.x + stop.labelMaxWidth <= next)
        }
    }

    @Test func aNarrowScreenScrollsAcrossRatherThanSqueezeTheLanes() {
        let lines = [line("41", stops: 20, userAt: 10), line("18", stops: 20, userAt: 10), line("7", stops: 20, userAt: 10)]
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: lines, axis: .vertical,
                                                            viewport: CGSize(width: 320, height: 700)))
        #expect(close(scene.contentSize.width, 3 * FullRouteLayout.minimumVerticalLane))
    }

    /// A −35° name runs on past its stop and climbs above its rail: the content has to hold both,
    /// or the last stop's name and the top lane's names are cut off at the edge of the scroller.
    @Test func landscapeLeavesRoomForTheNamesAtTheEdges() throws {
        let lines = [line("41", stops: 12, userAt: 8), line("18", stops: 12, userAt: 8)]
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: lines, axis: .horizontal,
                                                            viewport: CGSize(width: 844, height: 270)))
        let angle = 35 * CGFloat.pi / 180
        let last = try #require(scene.stops.max { $0.center.x < $1.center.x })
        #expect(last.labelAnchor.x + last.labelMaxWidth * cos(angle) <= scene.contentSize.width)
        for stop in scene.stops {
            let textLines: CGFloat = stop.role == .userStop ? 3 : 2
            let rise = stop.labelMaxWidth * sin(angle) + textLines * scene.labelFontSize * 1.25 * cos(angle)
            #expect(stop.labelAnchor.y - rise >= -0.5)
        }
    }

    // MARK: Buses

    @Test func aBusSitsBetweenItsStops() throws {
        let vehicle = MapVehicleInput(id: "bus", lineID: "41", lastStopIndex: 3, progressToNext: 0.5)
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: [line("41", stops: 10, userAt: 6)], vehicles: [vehicle],
                                                            axis: .horizontal, viewport: wide))
        let puck = try #require(scene.pucks.first)
        let route = try #require(scene.line("41"))
        #expect(close(puck.center.x, (route.stopCenters[3].x + route.stopCenters[4].x) / 2))
        #expect(close(puck.center.y, route.stopCenters[3].y))
    }

    @Test func aBusOnABendRidesTheCurve() throws {
        let seven = MapFixtures.line7B
        let joinIndex = try #require(seven.stops.firstIndex { $0.code == "PIER-FOUR" })
        let vehicle = MapVehicleInput(id: "bus", lineID: "7", lastStopIndex: joinIndex - 1, progressToNext: 0.5)
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: fixture(MapFixtures.mergeB), vehicles: [vehicle],
                                                            axis: .vertical, viewport: tall))
        let puck = try #require(scene.pucks.first)
        let segment = try #require(scene.line("7")?.segments[joinIndex - 1])
        #expect(segment.bends)
        #expect(close(puck.center.x, segment.point(at: 0.5).x))
        #expect(close(puck.center.y, segment.point(at: 0.5).y))
    }

    @Test func aBusOfAnUnwatchedLineIsLeftOff() {
        let vehicle = MapVehicleInput(id: "bus", lineID: "99", lastStopIndex: 3, progressToNext: 0.5)
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: [line("41", stops: 10, userAt: 6)], vehicles: [vehicle],
                                                            axis: .horizontal, viewport: wide))
        #expect(scene.pucks.isEmpty)
    }

    @Test func nothingToDrawIsEmpty() {
        #expect(FullRouteLayout.layout(FullRouteRequest(lines: [], axis: .horizontal, viewport: .zero)).isEmpty)
        #expect(FullRouteLayout.layout(FullRouteRequest(lines: [line("41", stops: 1, userAt: 0)], axis: .horizontal,
                                                        viewport: .zero)).isEmpty)
    }

    // MARK: Alignment

    @Test func sharedStopsLineUpAndOwnStopsSitSideBySide() {
        let columns = RouteAlignment.columns(lines: [["a1", "a2", "S", "U"], ["b1", "S", "U"]], userIndices: [3, 2])
        #expect(columns.count == 4)
        // The shared stop and the rider's are one column each, for both lines.
        #expect(columns[2] == [0: 2, 1: 1])
        #expect(columns[3] == [0: 3, 1: 2])
        // b1 sits beside a2, not in a column of its own.
        #expect(columns[1] == [0: 1, 1: 0])
        #expect(columns[0] == [0: 0])
    }

    @Test func afterTheRidersStopTheRoutesStartTogether() {
        let columns = RouteAlignment.columns(lines: [["U", "p", "q", "r"], ["U", "x"]], userIndices: [0, 0])
        #expect(columns[0] == [0: 0, 1: 0])
        #expect(columns[1] == [0: 1, 1: 1])
        #expect(columns[3] == [0: 3])
    }

    // MARK: Prev, my stop and next

    /// Line 41, 30 stops, the rider at 20: buses at stops 5, 12 and 20 (at the stop), and 25 past it.
    private func busyScene(axis: MapAxis = .horizontal) -> FullRouteScene {
        let vehicles = [(5, "far"), (12, "near"), (20, "here"), (25, "gone")].map {
            MapVehicleInput(id: $0.1, lineID: "41", lastStopIndex: $0.0, progressToNext: 0)
        }
        return FullRouteLayout.layout(FullRouteRequest(lines: [line("41", stops: 30, userAt: 20)], vehicles: vehicles,
                                                       axis: axis, viewport: wide))
    }

    @Test func fromMyStopPrevIsTheBusAtOrBeforeIt() {
        let scene = busyScene()
        #expect(FullRouteNavigation.step(-1, from: .userStop, in: scene, visibleCenterAlong: 0)?.vehicleID == "here")
        #expect(FullRouteNavigation.step(1, from: .userStop, in: scene, visibleCenterAlong: 0)?.vehicleID == "gone")
    }

    @Test func prevAndNextWalkTheBusesInOrderAndStopAtTheEnds() {
        let scene = busyScene(axis: .vertical)
        var focus = FullRouteNavigation.Focus.bus("here")
        var seen: [String] = []
        while let bus = FullRouteNavigation.step(-1, from: focus, in: scene, visibleCenterAlong: 0) {
            seen.append(bus.vehicleID)
            focus = .bus(bus.vehicleID)
        }
        #expect(seen == ["near", "far"])
        #expect(FullRouteNavigation.step(1, from: .bus("gone"), in: scene, visibleCenterAlong: 0) == nil)
        #expect(FullRouteNavigation.step(1, from: .bus("far"), in: scene, visibleCenterAlong: 0)?.vehicleID == "near")
    }

    @Test func afterTheRiderScrollsTheStepsGoFromTheMiddleOfTheView() throws {
        let scene = busyScene()
        let route = try #require(scene.line("41"))
        // The view is centred between stops 12 and 20.
        let middle = (route.stopCenters[12].x + route.stopCenters[20].x) / 2
        #expect(FullRouteNavigation.step(-1, from: .free, in: scene, visibleCenterAlong: middle)?.vehicleID == "near")
        #expect(FullRouteNavigation.step(1, from: .free, in: scene, visibleCenterAlong: middle)?.vehicleID == "here")
        // A focused bus that has since finished its run steps from the view too.
        #expect(FullRouteNavigation.step(1, from: .bus("retired"), in: scene, visibleCenterAlong: middle)?.vehicleID == "here")
    }

    @Test func busesLevelWithEachOtherGoInLaneOrder() {
        let vehicles = [MapVehicleInput(id: "b", lineID: "18", lastStopIndex: 3, progressToNext: 0),
                        MapVehicleInput(id: "a", lineID: "41", lastStopIndex: 3, progressToNext: 0)]
        let lines = [line("41", stops: 10, userAt: 8), line("18", stops: 10, userAt: 8)]
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: lines, vehicles: vehicles, axis: .vertical,
                                                            viewport: tall))
        #expect(FullRouteNavigation.ordered(scene.pucks, axis: .vertical).map(\.vehicleID) == ["a", "b"])
    }

    // MARK: Scrolling and the strip

    @Test func opensCentredOnTheRidersStop() {
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: [line("41", stops: 60, userAt: 40)], axis: .horizontal,
                                                            viewport: CGSize(width: 800, height: 300)))
        let offset = scene.offset(centeringUserStopIn: CGSize(width: 800, height: 300))
        #expect(close(offset.x + 400, scene.userStopAlong))
        #expect(offset.y == 0)
    }

    @Test func lanesThatFitNeverScrollAcross() {
        let lines = [line("41", stops: 12, userAt: 8), line("18", stops: 12, userAt: 8)]
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: lines, axis: .horizontal,
                                                            viewport: CGSize(width: 844, height: 320)))
        #expect(close(scene.contentSize.height, 320))
    }

    @Test func opensOnTheRidersStopAcrossTooWhenTheLanesOverflow() throws {
        // Three lanes at their minimum on a short screen: the node gathers on the lowest lane.
        let lines = [line("41", stops: 12, userAt: 8), line("18", stops: 12, userAt: 8), line("7", stops: 12, userAt: 8)]
        let viewport = CGSize(width: 820, height: 260)
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: lines, axis: .horizontal, viewport: viewport))
        #expect(scene.contentSize.height > viewport.height)
        let node = try #require(scene.stop("USER"))
        let offset = scene.offset(centeringUserStopIn: viewport)
        #expect(node.center.y > offset.y && node.center.y < offset.y + viewport.height)
    }

    @Test func centringNeverScrollsPastTheEnds() {
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: [line("41", stops: 60, userAt: 0)], axis: .horizontal,
                                                            viewport: CGSize(width: 800, height: 300)))
        #expect(scene.offset(centeringUserStopIn: CGSize(width: 800, height: 300)).x == 0)
        let end = FullRouteLayout.layout(FullRouteRequest(lines: [line("41", stops: 60, userAt: 59)], axis: .horizontal,
                                                          viewport: CGSize(width: 800, height: 300)))
        #expect(close(end.offset(centeringUserStopIn: CGSize(width: 800, height: 300)).x, end.contentSize.width - 800))
    }

    @Test func theWindowIsWhatTheViewShows() {
        let minimap = FullRouteMinimap(axis: .horizontal, content: CGSize(width: 4000, height: 300),
                                       strip: CGSize(width: 400, height: 48))
        let window = minimap.window(visible: CGRect(x: 1000, y: 0, width: 800, height: 300))
        #expect(close(window.minX, 100))
        #expect(close(window.width, 80))
        // The whole height, less the inset that keeps its outline whole.
        #expect(close(window.height, 48 - 2 * FullRouteMinimap.windowInset))
    }

    @Test func portraitTurnsOnItsSideInTheStrip() {
        // The view scrolls down; the strip still runs left to right.
        let minimap = FullRouteMinimap(axis: .vertical, content: CGSize(width: 390, height: 3000),
                                       strip: CGSize(width: 300, height: 48))
        let window = minimap.window(visible: CGRect(x: 0, y: 1500, width: 390, height: 600))
        #expect(close(window.minX, 150))
        #expect(close(window.width, 60))
        #expect(close(window.height, 48 - 2 * FullRouteMinimap.windowInset))
    }

    @Test func touchingTheStripCentresTheViewThereAndRoundTrips() {
        let minimap = FullRouteMinimap(axis: .horizontal, content: CGSize(width: 4000, height: 300),
                                       strip: CGSize(width: 400, height: 48))
        let offset = minimap.offset(centeredOn: CGPoint(x: 200, y: 24), visible: CGSize(width: 800, height: 300))
        #expect(close(offset.x, 1600))
        #expect(offset.y == 0)
        let window = minimap.window(visible: CGRect(origin: offset, size: CGSize(width: 800, height: 300)))
        #expect(close(window.midX, 200))
        // Past either end the view stops at the end.
        #expect(minimap.offset(centeredOn: CGPoint(x: -50, y: 24), visible: CGSize(width: 800, height: 300)).x == 0)
        #expect(close(minimap.offset(centeredOn: CGPoint(x: 500, y: 24), visible: CGSize(width: 800, height: 300)).x, 3200))
    }

    @Test func oneLineRunsThroughTheMiddleOfTheStrip() throws {
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: [line("112", stops: 40, userAt: 10)],
                                                            axis: .horizontal, viewport: wide))
        let minimap = FullRouteMinimap(axis: scene.axis, content: scene.contentSize,
                                       strip: CGSize(width: 300, height: 52), railsAcross: scene.railsAcross)
        let route = try #require(scene.line("112"))
        for center in route.stopCenters { #expect(close(minimap.point(center).y, 26)) }
    }

    @Test func severalLanesFillTheStripBetweenItsPadding() throws {
        let scene = FullRouteLayout.layout(FullRouteRequest(lines: fixture(MapFixtures.main), axis: .vertical,
                                                            viewport: tall))
        let strip = CGSize(width: 300, height: 52)
        let minimap = FullRouteMinimap(axis: scene.axis, content: scene.contentSize, strip: strip,
                                       railsAcross: scene.railsAcross)
        let ys = scene.lines.flatMap(\.stopCenters).map { minimap.point($0).y }
        #expect(close(ys.min()!, FullRouteMinimap.padding))
        #expect(close(ys.max()!, strip.height - FullRouteMinimap.padding))
    }

    @Test func theWindowNeverLeavesTheStrip() {
        let minimap = FullRouteMinimap(axis: .horizontal, content: CGSize(width: 4000, height: 300),
                                       strip: CGSize(width: 400, height: 48), railsAcross: 150...270)
        let inset = FullRouteMinimap.windowInset
        for visible in [CGRect(x: 3200, y: 0, width: 800, height: 300), CGRect(x: 0, y: 0, width: 800, height: 300),
                        CGRect(x: 1000, y: 200, width: 800, height: 100)] {
            let window = minimap.window(visible: visible)
            #expect(window.minX >= inset - 0.01 && window.maxX <= 400 - inset + 0.01)
            #expect(window.minY >= inset - 0.01 && window.maxY <= 48 - inset + 0.01)
            #expect(window.width > 0 && window.height > 0)
        }
    }

    @Test func touchingTheStripsMiddleCentresTheRails() {
        let minimap = FullRouteMinimap(axis: .horizontal, content: CGSize(width: 4000, height: 600),
                                       strip: CGSize(width: 400, height: 48), railsAcross: 150...450)
        let offset = minimap.offset(centeredOn: CGPoint(x: 200, y: 24), visible: CGSize(width: 800, height: 300))
        #expect(close(offset.y + 150, 300))
    }
}
