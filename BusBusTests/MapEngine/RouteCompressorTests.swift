import Testing
@testable import BusBus

private func compress(_ line: MapLineInput, shared: Range<Int> = 0..<0, head: Int = 1, tail: Int = 5) -> CompressedLine {
    RouteCompressor.compress(line: line, shared: shared, headCount: head, tailBudget: tail)
}

private func line(stopCount: Int) -> MapLineInput {
    MapLineInput(id: "t", number: "t", colorIndex: 0,
                 stops: MapFixtures.filler("S", stopCount - 1) + [MapFixtures.stop(MapFixtures.user)])
}

struct RouteCompressorTests {

    @Test func main41_headOneDashFourTailFive() {
        let c = compress(MapFixtures.line41Main)
        #expect(c.runs == [.stop(index: 1), .dash(swallowed: 2..<6),
                           .stop(index: 6), .stop(index: 7), .stop(index: 8), .stop(index: 9), .stop(index: 10)])
        #expect(c.dashes.first?.count == 4)
    }

    @Test func main18_dashSix() { #expect(compress(MapFixtures.line18Main).dashes.first?.count == 6) }
    @Test func main7_dashNine() { #expect(compress(MapFixtures.line7Main).dashes.first?.count == 9) }

    @Test func pad41_tailFour_dashFive() { #expect(compress(MapFixtures.line41Main, tail: 4).dashes.first?.count == 5) }
    @Test func pad18_dashSeven() { #expect(compress(MapFixtures.line18Main, tail: 4).dashes.first?.count == 7) }
    @Test func pad7_dashTen() { #expect(compress(MapFixtures.line7Main, tail: 4).dashes.first?.count == 10) }

    @Test func nineStopLine_drawnInFull() {
        let c = compress(line(stopCount: 9))
        #expect(c.dashes.isEmpty)
        #expect(c.drawnStopIndices == Array(1..<8))
    }

    @Test func tenStopLine_getsDash() {
        let c = compress(line(stopCount: 10))
        #expect(c.dashes.first?.count == 2)
    }

    @Test func single_headTwo() {
        let c = compress(MapFixtures.line41Main, head: 2)
        #expect(c.runs.prefix(3) == [.stop(index: 1), .stop(index: 2), .dash(swallowed: 3..<6)])
        #expect(c.dashes.first?.count == 3)
    }

    @Test func mergeA_trunkOwnTailIsOne() {
        let c = compress(MapFixtures.line41A, shared: 9..<13)
        #expect(c.ownTailCount == 1)
        #expect(c.runs.suffix(6) == [.dash(swallowed: 2..<8), .stop(index: 8), .stop(index: 9),
                                     .stop(index: 10), .stop(index: 11), .stop(index: 12)])
        #expect(MapFixtures.line41A.stops[8].name == "BELL TOWER")
        #expect(c.sharedDashed == nil)
    }

    @Test func mergeB_trunkSharedSixNotBundleDashed() {
        let c = compress(MapFixtures.line41B, shared: 7..<13)
        #expect(c.sharedDashed == nil)
        #expect(c.ownTailCount == 1)
        #expect(MapFixtures.line41B.stops[6].name == "LOWER QUAY")
    }

    @Test func bundleOfNine_isCompressed() {
        // A trunk whose shared corridor is nine stops long: the bundle itself gets a dash.
        let stops = MapFixtures.filler("O", 6) + MapFixtures.filler("SH", 9) + [MapFixtures.stop(MapFixtures.user)]
        let trunk = MapLineInput(id: "t", number: "t", colorIndex: 0, stops: stops)
        let c = compress(trunk, shared: 6..<15)
        #expect(c.sharedDashed == 1..<5)
        #expect(c.ownTailCount == 1)
        #expect(c.dashes.contains(7..<11))
    }

    @Test func subsetLine_hasNoOwnRuns() {
        let stops = Array(MapFixtures.line41A.stops.suffix(5))
        let sub = MapLineInput(id: "99", number: "99", colorIndex: 4, stops: stops)
        let c = compress(sub, shared: 0..<4)
        #expect(c.dashes.isEmpty)
        #expect(c.drawnStopIndices == [0, 1, 2, 3])
    }

    @Test func twoStopLine_noRuns() {
        let two = MapLineInput(id: "99", number: "99", colorIndex: 4,
                               stops: [MapFixtures.stop("TERMINUS"), MapFixtures.stop(MapFixtures.user)])
        #expect(compress(two).runs.isEmpty)
    }
}
