import Testing
@testable import BusBus

private let userCode = MapFixtures.userCode
private func junction(_ line: MapLineInput, _ trunk: MapLineInput) -> JunctionResult {
    JunctionDetector.junction(of: line, onto: trunk, userStopCode: userCode)
}

struct JunctionDetectorTests {

    @Test func mergeA_18JoinsAtMillJunction() {
        let result = junction(MapFixtures.line18A, MapFixtures.line41A)
        #expect(result.lineJunctionIndex == 11)
        #expect(result.trunkJunctionIndex == 9)
        #expect(result.lineIsSubsetOfTrunk == false)
        #expect(MapFixtures.line41A.stops[9].name == "MILL JUNCTION")
    }

    @Test func mergeA_7HasNoJunction() {
        #expect(junction(MapFixtures.line7A, MapFixtures.line41A).lineJunctionIndex == nil)
    }

    @Test func mergeB_twoDifferentJunctions() {
        let j18 = junction(MapFixtures.line18B, MapFixtures.line41B)
        let j7 = junction(MapFixtures.line7B, MapFixtures.line41B)
        #expect(j18.trunkJunctionIndex == 7)
        #expect(MapFixtures.line41B.stops[7].code == "BELL-TOWER")
        #expect(j7.trunkJunctionIndex == 10)
        #expect(MapFixtures.line41B.stops[10].code == "PIER-FOUR")
    }

    @Test func mergeC_allJoinAtWestMarket() {
        #expect(junction(MapFixtures.line18C, MapFixtures.line41C).trunkJunctionIndex == 9)
        #expect(junction(MapFixtures.line7C, MapFixtures.line41C).trunkJunctionIndex == 9)
        #expect(MapFixtures.line41C.stops[9].code == "WEST-MARKET")
    }

    @Test func noMerge_mainLinesShareOnlyTheUserStop() {
        #expect(junction(MapFixtures.line18Main, MapFixtures.line41Main).hasJunction == false)
        #expect(junction(MapFixtures.line7Main, MapFixtures.line41Main).hasJunction == false)
    }

    @Test func mergeAtUserStopOnly_isNoJunction() {
        let line = MapLineInput(id: "99", number: "99", colorIndex: 4,
                                stops: [MapFixtures.stop("ELSEWHERE"), MapFixtures.stop("SOMEWHERE"), MapFixtures.stop(MapFixtures.user)])
        #expect(junction(line, MapFixtures.line41Main).hasJunction == false)
    }

    @Test func lineEntirelyOnTrunk_isSubset() {
        let line = MapLineInput(id: "99", number: "99", colorIndex: 4, stops: Array(MapFixtures.line41A.stops.suffix(5)))
        let result = junction(line, MapFixtures.line41A)
        #expect(result.lineIsSubsetOfTrunk)
        #expect(result.lineJunctionIndex == 0)
        #expect(result.trunkJunctionIndex == 9)
    }

    @Test func trunkTerminusInsideLine_isTreatedAsIndependent() {
        let line = MapLineInput(id: "99", number: "99", colorIndex: 4,
                                stops: [MapFixtures.stop("FAR"), MapFixtures.stop("FARTHER")] + MapFixtures.line41A.stops)
        #expect(junction(line, MapFixtures.line41A).hasJunction == false)
    }

    @Test func duplicateCodesOnLine_walkIsIndexBased() {
        var stops = MapFixtures.line18A.stops
        stops.insert(MapFixtures.stop("CANAL ST"), at: 3)
        let line = MapLineInput(id: "18", number: "18", colorIndex: 0, stops: stops)
        let result = junction(line, MapFixtures.line41A)
        #expect(result.lineJunctionIndex == 12)
        #expect(result.trunkJunctionIndex == 9)
        #expect(stops[12].code == "MILL-JUNCTION")
    }

    @Test func missingUserStop_returnsNoJunction() {
        let line = MapLineInput(id: "99", number: "99", colorIndex: 4, stops: MapFixtures.filler("X", 5))
        let result = junction(line, MapFixtures.line41Main)
        #expect(result.lineJunctionIndex == nil)
        #expect(result.trunkJunctionIndex == nil)
    }
}
