import Testing
import CoreGraphics
@testable import BusBus

private func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.5) -> Bool { abs(a - b) <= tolerance }
private func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.5) -> Bool {
    close(a.x, b.x, tolerance) && close(a.y, b.y, tolerance)
}

private extension MapScene {
    func stops(ofLine id: String) -> [StopMark] { stops.filter { $0.lineIDs == [id] } }
    func capsule(_ code: String) -> StopMark? { stops.first { $0.stopCode == code && $0.kind == .capsule } }
    func label(_ lineID: String, _ code: String) -> StopLabel? {
        labels.first { $0.lineID == lineID && $0.stopCode == code }
    }
    var cubics: [RailSegment] { rails.flatMap(\.segments).filter { if case .cubic = $0 { true } else { false } } }
}

struct MapLayoutEngineTests {

    // MARK: Landscape shell

    @Test func trunkIsStraightAtCentre() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main))
        let trunk = try #require(scene.rail("41"))
        for segment in trunk.segments {
            #expect(close(segment.start.y, 190))
            #expect(close(segment.end.y, 190))
            if case .cubic = segment { Issue.record("the trunk must never bend") }
        }
    }

    @Test func terminiAlignAtLeft() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main))
        #expect(scene.termini.count == 3)
        for terminus in scene.termini { #expect(close(terminus.rect.midX, 45)) }
        #expect(close(scene.termini[0].rect.width, 10))
        #expect(close(scene.termini[0].rect.height, 40))
    }

    @Test func rowsAt70_190_310() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main))
        #expect(close(try #require(scene.rail("18")).segments[0].start.y, 70))
        #expect(close(try #require(scene.rail("7")).segments[0].start.y, 310))
    }

    @Test func twoLines_otherRowFollowsSelectionOrder() throws {
        let below = MapLayoutEngine.layout(MapFixtures.request([MapFixtures.line41Main, MapFixtures.line7Main]))
        #expect(close(try #require(below.rail("7")).segments[0].start.y, 310))
        let above = MapLayoutEngine.layout(MapFixtures.request([MapFixtures.line7Main, MapFixtures.line41Main]))
        #expect(close(try #require(above.rail("7")).segments[0].start.y, 70))
    }

    // MARK: Compression and placement

    @Test func noMerge_lastTailStopAt910_pitch100() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main))
        let along = try #require(scene.stopAlong["41"])
        #expect(along[11] == 1190)
        let drawn = scene.stops(ofLine: "41").map { $0.center.x }.sorted()
        #expect(drawn.count == 6)
        for (actual, expected) in zip(drawn, [110.0, 510, 610, 710, 810, 910] as [CGFloat]) {
            #expect(close(actual, expected))
        }
    }

    @Test func noMerge_dashSpansBetweenHeadAndTail() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main))
        let dash = try #require(scene.dashes.first { $0.lineID == "41" })
        #expect(close(dash.from.x, 130))      // 110 + ring outer 16 + 4 clearance
        #expect(close(dash.to.x, 490))        // 510 − 16 − 4
        #expect(dash.swallowedCount == 4)
        // 26 below the rail rather than the artboard's 16: a puck is 36 tall and centred on the
        // rail, so a caption at 16 sits underneath any bus standing at that point. The artboards
        // never draw a bus there; live data does.
        #expect(close(dash.labelCenter, CGPoint(x: 310, y: 216)))
    }

    @Test func noMerge_swallowedStopsGetVirtualAlong() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main))
        let along = try #require(scene.stopAlong["41"])
        let swallowed = Array(along[2..<6])
        #expect(zip(swallowed, swallowed.dropFirst()).allSatisfy { $0 < $1 })
        #expect(swallowed.allSatisfy { $0 > 130 && $0 < 490 })
    }

    @Test func noMerge_noCapsules() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main))
        #expect(scene.stops.allSatisfy { if case .ring = $0.kind { true } else { false } })
        #expect(close(scene.stops[0].ringRadius, 13))
        #expect(close(scene.stops[0].strokeWidth, 6))
    }

    @Test func convergence_unjoinedCurvesMatchMain() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main))
        let rail18 = try #require(scene.rail("18"))
        guard case .cubic(let from, let c1, let c2, let to) = try #require(rail18.segments.last) else {
            Issue.record("an unjoined rail must end in one curve into the stub"); return
        }
        #expect(close(from, CGPoint(x: 1020, y: 70)))
        #expect(close(c1, CGPoint(x: 1066, y: 70)))
        #expect(close(c2, CGPoint(x: 1074, y: 190)))
        #expect(close(to, CGPoint(x: 1120, y: 190)))
        #expect(close(try #require(rail18.segments.dropLast().last).end, CGPoint(x: 1020, y: 70)))

        let convergence = scene.convergence
        #expect(close(convergence.stubFrom, CGPoint(x: 1118, y: 190)))
        #expect(close(convergence.stubTo, CGPoint(x: 1162, y: 190)))
        #expect(close(convergence.stubWidth, 16))
        #expect(close(convergence.nodeCenter, CGPoint(x: 1190, y: 190)))
        #expect(close(convergence.nodeRadius, 26))
        #expect(close(convergence.nodeStrokeWidth, 12))
        #expect(close(convergence.captionAnchor, CGPoint(x: 1190, y: 236)))
        #expect(convergence.captionIsBelow)
    }

    // MARK: Merge A — one shared corridor

    @Test func mergeA_capsulesSpanTrunkAndUpperRail() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.mergeA))
        for code in ["MILL-JUNCTION", "CANAL-ST", "FISH-MARKET", "DOCK-GATE"] {
            let capsule = try #require(scene.capsule(code), "expected a capsule at \(code)")
            #expect(close(capsule.capsuleRect.minY, 154))
            #expect(close(capsule.capsuleRect.height, 54))
            #expect(close(capsule.capsuleRect.width, 20))
            #expect(close(capsule.capsuleCornerRadius, 10))
            #expect(close(capsule.strokeWidth, 4))
            #expect(capsule.lineIDs == ["41", "18"])
        }
    }

    @Test func mergeA_18RunsParallelAbove() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.mergeA))
        let junctionAlong = try #require(scene.stopAlong["41"])[9]
        let rail = try #require(scene.rail("18"))
        guard case .cubic(let from, _, _, let to) = try #require(rail.segments.first { if case .cubic = $0 { true } else { false } }) else {
            Issue.record("expected a junction curve"); return
        }
        #expect(close(to, CGPoint(x: junctionAlong, y: 172)))
        #expect(close(from.x, junctionAlong - 80))
        #expect(close(from.y, 70))
        #expect(rail.segments.contains { if case .line(let f, let t) = $0 { close(f.y, 172) && close(t.y, 172) } else { false } })
    }

    @Test func mergeA_18OwnSegmentEndsOnePitchBeforeJunction() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.mergeA))
        let junctionAlong = try #require(scene.stopAlong["41"])[9]
        #expect(close(try #require(scene.stopAlong["18"])[10], junctionAlong - 100))
        #expect(MapFixtures.line18A.stops[10].name == "WEST MARKET")
    }

    @Test func mergeA_7IsIndependent() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.mergeA))
        let rail = try #require(scene.rail("7"))
        #expect(rail.segments.filter { if case .cubic = $0 { true } else { false } }.count == 1)
        #expect(scene.stops.filter { $0.lineIDs == ["7"] }.allSatisfy { if case .ring = $0.kind { true } else { false } })
    }

    @Test func mergeA_junctionLabelIsPrimary() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.mergeA))
        #expect(try #require(scene.label("41", "MILL-JUNCTION")).role == .junction)
        #expect(try #require(scene.label("41", "CANAL-ST")).role == .stop)
        #expect(scene.labels.filter { $0.stopCode == "CANAL-ST" }.count == 1)
        #expect(scene.labels.filter { $0.stopCode == "MILL-JUNCTION" }.count == 1)
    }

    @Test func mergeA_joinedRailConvergesFromParallel() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.mergeA))
        let rail = try #require(scene.rail("18"))
        guard case .cubic(let from, let c1, let c2, let to) = try #require(rail.segments.last) else {
            Issue.record("expected a convergence curve"); return
        }
        #expect(close(from, CGPoint(x: 1056, y: 172)))
        #expect(close(c1, CGPoint(x: 1090, y: 172)))
        #expect(close(c2, CGPoint(x: 1096, y: 190)))
        #expect(close(to, CGPoint(x: 1120, y: 190)))
    }

    // MARK: Merge B — two junctions

    @Test func mergeB_threeRailBundleAfterPierFour() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.mergeB))
        for code in ["BELL-TOWER", "CANAL-ST", "FISH-MARKET"] {
            let capsule = try #require(scene.capsule(code), "expected a two-rail capsule at \(code)")
            #expect(close(capsule.capsuleRect.minY, 154))
            #expect(close(capsule.capsuleRect.height, 54))
        }
        for code in ["PIER-FOUR", "GRANITE-ROW", "DOCK-GATE"] {
            let capsule = try #require(scene.capsule(code), "expected a three-rail capsule at \(code)")
            #expect(close(capsule.capsuleRect.minY, 154))
            #expect(close(capsule.capsuleRect.maxY, 226))
            #expect(close(capsule.capsuleRect.height, 72))
        }
        let rail7 = try #require(scene.rail("7"))
        #expect(rail7.segments.contains { if case .line(let f, let t) = $0 { close(f.y, 208) && close(t.y, 208) } else { false } })
    }

    @Test func mergeB_junctionsAtDifferentAlong() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.mergeB))
        let along = try #require(scene.stopAlong["41"])
        #expect(along[7] < along[10])
        func junctionEnd(_ lineID: String) -> CGPoint? {
            guard case .cubic(_, _, _, let to)? = scene.rail(lineID)?.segments.first(where: { if case .cubic = $0 { true } else { false } }) else { return nil }
            return to
        }
        #expect(close(try #require(junctionEnd("18")).x, along[7]))
        #expect(close(try #require(junctionEnd("7")).x, along[10]))
    }

    // MARK: Merge C — one common trunk

    @Test func mergeC_allThreeMeetAtWestMarket() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.mergeC))
        let junctionAlong = try #require(scene.stopAlong["41"])[9]
        for code in ["WEST-MARKET", "CANAL-ST", "PIER-FOUR", "DOCK-GATE"] {
            #expect(close(try #require(scene.capsule(code), "expected a capsule at \(code)").capsuleRect.height, 72))
        }
        #expect(scene.stops.filter { $0.kind == .capsule }.count == 4)
        func junctionEnd(_ lineID: String) -> CGPoint? {
            guard case .cubic(_, _, _, let to)? = scene.rail(lineID)?.segments.first(where: { if case .cubic = $0 { true } else { false } }) else { return nil }
            return to
        }
        #expect(close(try #require(junctionEnd("18")), CGPoint(x: junctionAlong, y: 172)))
        #expect(close(try #require(junctionEnd("7")), CGPoint(x: junctionAlong, y: 208)))
    }

    @Test func mergeC_ownTailsAreOne() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.mergeC))
        // One own stop drawn between each line's dash and the junction.
        #expect(scene.stops(ofLine: "41").count == 2)   // head + own tail; shared stops are capsules
        #expect(scene.stops(ofLine: "18").count == 2)
        #expect(scene.stops(ofLine: "7").count == 2)
    }

    // MARK: Portrait

    @Test func phone3Lines_columnsAt59_127_195_trunkRight() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(
            MapFixtures.main, axis: .vertical, preset: .phone, canvas: CGSize(width: 390, height: 470)))
        #expect(close(try #require(scene.rail("7")).segments[0].start.x, 59))
        #expect(close(try #require(scene.rail("18")).segments[0].start.x, 127))
        for segment in try #require(scene.rail("41")).segments { #expect(close(segment.start.x, 195)) }
    }

    @Test func phone2Lines_otherColumnAt110() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(
            [MapFixtures.line18Main, MapFixtures.line41Main], axis: .vertical, preset: .phone,
            canvas: CGSize(width: 390, height: 470)))
        #expect(close(try #require(scene.rail("18")).segments[0].start.x, 110))
    }

    @Test func phone_distanceSpines_haveNoLabels() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(
            MapFixtures.main, axis: .vertical, preset: .phone,
            canvas: CGSize(width: 390, height: 470), named: ["41"]))
        #expect(scene.labels.allSatisfy { $0.lineID == "41" })
        // No "+N STOPS" on a spine either: it reports position, not the route.
        #expect(scene.dashes.filter(\.showLabel).allSatisfy { $0.lineID == "41" })
        #expect(scene.termini.allSatisfy { if case .badge = $0.style { true } else { false } })
    }

    @Test func phone_convergenceMatchesArtboard() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(
            [MapFixtures.line18Main, MapFixtures.line41Main], axis: .vertical, preset: .phone,
            canvas: CGSize(width: 390, height: 470)))
        let rail = try #require(scene.rail("18"))
        guard case .cubic(let from, let c1, let c2, let to) = try #require(rail.segments.last) else {
            Issue.record("expected a convergence curve"); return
        }
        #expect(close(from, CGPoint(x: 110, y: 388)))
        #expect(close(c1, CGPoint(x: 110, y: 404)))
        #expect(close(c2, CGPoint(x: 195, y: 392)))
        #expect(close(to, CGPoint(x: 195, y: 410)))
        #expect(close(scene.convergence.stubFrom, CGPoint(x: 195, y: 408)))
        #expect(close(scene.convergence.stubTo, CGPoint(x: 195, y: 428)))
        #expect(close(scene.convergence.nodeCenter, CGPoint(x: 195, y: 448)))
        #expect(close(scene.convergence.nodeRadius, 17))
        #expect(close(scene.convergence.nodeStrokeWidth, 9))
        #expect(close(scene.convergence.captionAnchor, CGPoint(x: 228, y: 448)))
        #expect(scene.convergence.captionIsBelow == false)
    }

    @Test func phone_labelsHorizontalOutside() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(
            [MapFixtures.line18Main, MapFixtures.line41Main], axis: .vertical, preset: .phone,
            canvas: CGSize(width: 390, height: 470)))
        let trunkLabels = scene.labels.filter { $0.lineID == "41" }
        #expect(!trunkLabels.isEmpty)
        #expect(trunkLabels.allSatisfy { $0.rotationDegrees == 0 && $0.alignment == .leading && close($0.anchor.x, 227) })
        // 110 − 22: a name left of the second column has only the screen edge to run into, so it
        // sits closer to its rail than the trunk's names do (which have the whole right side).
        let otherLabels = scene.labels.filter { $0.lineID == "18" }
        #expect(otherLabels.allSatisfy { $0.alignment == .trailing && close($0.anchor.x, 88) })
    }

    @Test func pad_columnsAt167_417_667() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(
            MapFixtures.main, axis: .vertical, preset: .pad, canvas: CGSize(width: 834, height: 720)))
        #expect(close(try #require(scene.rail("18")).segments[0].start.x, 167))
        #expect(close(try #require(scene.rail("41")).segments[0].start.x, 417))
        #expect(close(try #require(scene.rail("7")).segments[0].start.x, 667))
        #expect(close(scene.convergence.nodeCenter, CGPoint(x: 417, y: 676)))
        #expect(close(scene.convergence.nodeRadius, 28))
        let drawn = scene.stops(ofLine: "41").map { $0.center.y }.sorted()
        let lastStop = try #require(drawn.last)
        let previousStop = try #require(drawn.dropLast().last)
        #expect(close(lastStop, 529))
        #expect(close(lastStop - previousStop, 86))
    }

    @Test func pad_namesSitBesideTheirOwnRail() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(
            MapFixtures.main, axis: .vertical, preset: .pad, canvas: CGSize(width: 834, height: 720)))
        for (lineID, column) in [("18", 199.0), ("41", 449.0), ("7", 699.0)] {
            let labels = scene.labels.filter { $0.lineID == lineID }
            #expect(!labels.isEmpty)
            #expect(labels.allSatisfy { $0.alignment == .leading && close($0.anchor.x, column) })
        }
        for lineID in ["18", "41", "7"] {
            let caption = try #require(scene.dashes.first { $0.lineID == lineID && $0.showLabel })
            #expect(caption.labelAlignment == .leading)
        }
        #expect(close(try #require(scene.dashes.first { $0.lineID == "7" && $0.showLabel }).labelCenter.x, 699))
    }

    @Test func portraitPucksKeepTheirLandscapeShape() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(
            MapFixtures.main, axis: .vertical, preset: .pad, canvas: CGSize(width: 834, height: 720),
            vehicles: [MapVehicleInput(id: "a", lineID: "41", lastStopIndex: 8, progressToNext: 0.5)]))
        let puck = try #require(scene.pucks.first)
        #expect(close(puck.size.width, 52))
        #expect(close(puck.size.height, 40))
    }

    @Test func portraitRingsMatchTheArtboardOuterDiameter() throws {
        let pad = MapLayoutEngine.layout(MapFixtures.request(
            MapFixtures.main, axis: .vertical, preset: .pad, canvas: CGSize(width: 834, height: 720)))
        #expect(close(pad.stops[0].ringRadius * 2 + pad.stops[0].strokeWidth, 30))
        let phone = MapLayoutEngine.layout(MapFixtures.request(
            MapFixtures.main, axis: .vertical, preset: .phone, canvas: CGSize(width: 390, height: 470)))
        #expect(close(phone.stops[0].ringRadius * 2 + phone.stops[0].strokeWidth, 22))
    }

    @Test func puckStopsShortOfTheConvergenceStub() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main, vehicles: [
            MapVehicleInput(id: "a", lineID: "41", lastStopIndex: 10, progressToNext: 1),
        ]))
        let puck = try #require(scene.pucks.first)
        #expect(puck.center.x + puck.size.width / 2 <= scene.convergence.stubFrom.x + 0.5)
    }

    // MARK: Scaling and fit

    @Test func scale_appliesUniformly() throws {
        let full = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main))
        let half = MapLayoutEngine.layout(MapFixtures.request(
            MapFixtures.main, canvas: CGSize(width: 640, height: 190), scale: 0.5))
        #expect(close(half.convergence.nodeCenter.x, full.convergence.nodeCenter.x / 2))
        #expect(close(half.convergence.nodeRadius, full.convergence.nodeRadius / 2))
        #expect(close(try #require(half.stopAlong["41"])[10], try #require(full.stopAlong["41"])[10] / 2))
        #expect(close(try #require(half.rail("18")).width, try #require(full.rail("18")).width / 2))
        #expect(close(half.stops[0].ringRadius, full.stops[0].ringRadius / 2))
    }

    @Test func wideCanvas_extraWidthGoesToDash() throws {
        let wide = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main, canvas: CGSize(width: 1600, height: 380)))
        let base = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main))
        #expect(close(wide.convergence.nodeCenter.x, 1510))
        #expect(close(try #require(wide.stopAlong["41"])[10], try #require(base.stopAlong["41"])[10] + 320))
        #expect(close(try #require(wide.stopAlong["41"])[1], 110))
        let wideDash = try #require(wide.dashes.first { $0.lineID == "41" })
        let baseDash = try #require(base.dashes.first { $0.lineID == "41" })
        #expect(close((wideDash.to.x - wideDash.from.x) - (baseDash.to.x - baseDash.from.x), 320))
    }

    @Test func tooManyTailStops_shrinkPitchNotBelowMinDash() throws {
        let narrow = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.mergeB, canvas: CGSize(width: 900, height: 380)))
        let dash = try #require(narrow.dashes.first { $0.lineID == "41" })
        #expect(dash.to.x - dash.from.x >= 60 - 0.5)
        let drawn = narrow.stops.filter { $0.lineIDs.first == "41" || $0.kind == .capsule }.map { $0.center.x }.sorted()
        let gaps = zip(drawn, drawn.dropFirst()).map { $1 - $0 }
        #expect(try #require(gaps.last) < 100)
    }

    // MARK: Pucks

    @Test func pucks_sitOnRailBetweenStops() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main, vehicles: [
            MapVehicleInput(id: "a", lineID: "41", lastStopIndex: 9, progressToNext: 0.5),
            MapVehicleInput(id: "b", lineID: "18", lastStopIndex: 2, progressToNext: 0),
        ]))
        let a = try #require(scene.pucks.first { $0.id == "a" })
        #expect(close(a.center, CGPoint(x: 860, y: 190)))
        #expect(close(a.size.width, 44))
        #expect(close(a.size.height, 36))
        let b = try #require(scene.pucks.first { $0.id == "b" })
        #expect(close(b.center.x, try #require(scene.stopAlong["18"])[2]))
        #expect(close(b.center.y, 70))
    }

    @Test func puck_onJunctionCurveFollowsCubic() throws {
        let along = try #require(MapLayoutEngine.layout(MapFixtures.request(MapFixtures.mergeA)).stopAlong["18"])
        // Halfway from the last own stop to the junction puts the bus inside the curve.
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.mergeA, vehicles: [
            MapVehicleInput(id: "c", lineID: "18", lastStopIndex: 10, progressToNext: 0.5)
        ]))
        let puck = try #require(scene.pucks.first)
        #expect(close(puck.center.x, (along[10] + along[11]) / 2))
        #expect(puck.center.y > 70 && puck.center.y < 172)
    }

    @Test func selectedPuck_isDrawnLast() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main, vehicles: [
            MapVehicleInput(id: "a", lineID: "41", lastStopIndex: 9, progressToNext: 0.5, isSelected: true),
            MapVehicleInput(id: "b", lineID: "18", lastStopIndex: 9, progressToNext: 0.2),
        ]))
        #expect(scene.pucks.last?.isSelected == true)
    }

    // MARK: Modes and validation

    @Test func highlightedLine_dimsTheOthers() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main, highlighted: "7"))
        #expect(try #require(scene.rail("7")).dimmed == false)
        #expect(try #require(scene.rail("41")).dimmed)
        #expect(try #require(scene.rail("18")).dimmed)
        let dimmedLabels = scene.labels.filter { $0.lineID == "41" }
        #expect(dimmedLabels.allSatisfy { $0.dimmed })
        #expect(scene.stops(ofLine: "7").allSatisfy { $0.dimmed == false })
    }

    @Test func singleLine_usesLargeMetrics() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request([MapFixtures.line41Main], preset: .landscapeSingle))
        #expect(close(try #require(scene.rail("41")).width, 14))
        #expect(close(scene.stops[0].ringRadius, 17))
        #expect(close(scene.stops[0].strokeWidth, 8))
        #expect(close(scene.termini[0].rect.width, 10))
        #expect(close(scene.termini[0].rect.height, 60))
        // Head of two: two stops are drawn before the dash.
        let dash = try #require(scene.dashes.first)
        #expect(scene.stops.filter { $0.center.x < dash.from.x }.count == 2)
    }

    @Test func dropsLineWithoutUserStop() throws {
        let stray = MapLineInput(id: "99", number: "99", colorIndex: 5, stops: MapFixtures.filler("X", 6))
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main + [stray]))
        #expect(scene.rail("99") == nil)
        #expect(scene.rails.count == 3)
    }

    // MARK: Two dashed runs on one line

    /// A trunk long enough to be compressed twice: once for its own segment before the junction,
    /// once for the corridor it then shares. Every Israeli urban route of any length looks like this.
    private static let twiceDashedTrunk = MapLineInput(id: "41", number: "41", colorIndex: 1, stops:
        [MapFixtures.stop("VISTA PARK")] + MapFixtures.filler("V", 5) + [MapFixtures.stop("BELL TOWER")]
        + MapFixtures.filler("C", 32) + [MapFixtures.stop(MapFixtures.user)])

    private static let twiceDashedBranch = MapLineInput(id: "18", number: "18", colorIndex: 0, stops:
        [MapFixtures.stop("NORTHGATE")] + MapFixtures.filler("N", 3) + [MapFixtures.stop("BELL TOWER")]
        + MapFixtures.filler("C", 32) + [MapFixtures.stop(MapFixtures.user)])

    @Test func ownDashAndBundleDash_bothDrawn() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request([Self.twiceDashedTrunk, Self.twiceDashedBranch]))
        let dashes = scene.dashes.filter { $0.lineID == "41" }.sorted { $0.from.x < $1.from.x }
        #expect(dashes.count == 2)
        #expect(dashes.map(\.swallowedCount) == [3, 28])
        #expect(close(dashes[0].from.x, 130))
        #expect(close(dashes[0].to.x, 290))
        #expect(close(dashes[1].from.x, 430))
        #expect(close(dashes[1].to.x, 590))
    }

    @Test func ownDashAndBundleDash_everyStopKeepsAPosition() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request([Self.twiceDashedTrunk, Self.twiceDashedBranch]))
        let along = try #require(scene.stopAlong["41"])
        #expect(along.count == Self.twiceDashedTrunk.stops.count)
        #expect(along.dropFirst().allSatisfy { $0 > 0 })
        #expect(zip(along, along.dropFirst()).allSatisfy { $0 < $1 })
        #expect(close(along[38], 910))
        #expect(along[20] > 430 && along[20] < 590)
    }

    @Test func ownDashAndBundleDash_pucksInsideTheSecondDash() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(
            [Self.twiceDashedTrunk, Self.twiceDashedBranch],
            vehicles: [MapVehicleInput(id: "a", lineID: "41", lastStopIndex: 20, progressToNext: 0.5)]))
        let puck = try #require(scene.pucks.first)
        #expect(puck.center.x > 430 && puck.center.x < 590)
        #expect(close(puck.center.y, 190))
    }

    @Test func stopMarkIDsAreUnique() throws {
        let repeated = MapLineInput(id: "41", number: "41", colorIndex: 1, stops: [
            MapFixtures.stop("VISTA PARK"), MapFixtures.stop("CANAL ST"), MapFixtures.stop("BELL TOWER"),
            MapFixtures.stop("CANAL ST"), MapFixtures.stop("DOCK GATE"), MapFixtures.stop(MapFixtures.user),
        ])
        let branch = MapLineInput(id: "18", number: "18", colorIndex: 0, stops: [
            MapFixtures.stop("NORTHGATE"), MapFixtures.stop("CANAL ST"), MapFixtures.stop("BELL TOWER"),
            MapFixtures.stop("CANAL ST"), MapFixtures.stop("DOCK GATE"), MapFixtures.stop(MapFixtures.user),
        ])
        let scene = MapLayoutEngine.layout(MapFixtures.request([repeated, branch]))
        #expect(Set(scene.stops.map(\.id)).count == scene.stops.count)
    }

    @Test func unknownTrunkFallsBackToTheFirstDrawableLine() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main, trunk: "nope"))
        #expect(scene.trunkLineID == "18")
        #expect(close(try #require(scene.rail("18")).segments[0].start.y, 190))
    }

    @Test func aStaleVehicleIndexIsClampedToTheRoute() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main, vehicles: [
            MapVehicleInput(id: "far", lineID: "41", lastStopIndex: 999, progressToNext: 1),
            MapVehicleInput(id: "back", lineID: "41", lastStopIndex: -4, progressToNext: -1),
        ]))
        #expect(scene.pucks.count == 2)
        for puck in scene.pucks {
            #expect(puck.center.x >= 0 && puck.center.x <= 1280)
            #expect(close(puck.center.y, 190))
        }
    }

    @Test func aLineEntirelyOnTheTrunkStartsAtItsJunction() throws {
        // 18 runs only the last stretch of 41's route, so it has no segment of its own to draw.
        let subset = MapLineInput(id: "18", number: "18", colorIndex: 0,
                                  stops: Array(MapFixtures.line41Main.stops.suffix(4)))
        let scene = MapLayoutEngine.layout(MapFixtures.request([MapFixtures.line41Main, subset]))
        let terminus = try #require(scene.termini.first { $0.lineID == "18" })
        let junctionAlong = try #require(scene.stopAlong["41"])[8]
        #expect(close(terminus.rect.midX, junctionAlong))
        #expect(close(terminus.rect.midY, 208))
        #expect(scene.stops(ofLine: "18").isEmpty)
    }

    /// An angled name costs vertical rise, so a long one is allowed a second line rather than
    /// climbing out of the top of the map.
    @Test func angledNames_wrapToTwoLines() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main))
        #expect(scene.labels.allSatisfy { $0.lineLimit == 2 })
        #expect(scene.labels.allSatisfy { $0.maxWidth > 0 })
        #expect(scene.labels.allSatisfy { $0.rotationDegrees == -35 })
    }

    @Test func angledNames_wrapWiderOnTheSingleLineBoard() throws {
        let single = MapLayoutEngine.layout(MapFixtures.request([MapFixtures.line41Main], preset: .landscapeSingle))
        let three = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main))
        #expect(try #require(single.labels.first).maxWidth > #require(three.labels.first).maxWidth)
    }

    /// Portrait names are horizontal and have a column to run along, so they stay on one line.
    @Test func horizontalNames_doNotWrap() throws {
        let scene = MapLayoutEngine.layout(MapFixtures.request(
            MapFixtures.main, axis: .vertical, preset: .phone, canvas: CGSize(width: 390, height: 470)))
        #expect(scene.labels.allSatisfy { $0.lineLimit == 1 })
        #expect(scene.labels.allSatisfy { $0.maxWidth == 0 })
    }

    @Test func wrapWidthScalesWithEverythingElse() throws {
        let full = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main))
        let half = MapLayoutEngine.layout(MapFixtures.request(
            MapFixtures.main, canvas: CGSize(width: 640, height: 190), scale: 0.5))
        #expect(close(try #require(half.labels.first).maxWidth,
                      try #require(full.labels.first).maxWidth / 2))
    }

    @Test func hintAnchor_onlyInLandscape() throws {
        #expect(close(try #require(MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main)).hintAnchor),
                      CGPoint(x: 40, y: 348)))
        #expect(MapLayoutEngine.layout(MapFixtures.request(
            MapFixtures.main, axis: .vertical, preset: .phone,
            canvas: CGSize(width: 390, height: 470))).hintAnchor == nil)
    }

    // MARK: Past the user's stop

    private static func onward(_ names: String...) -> [MapStopInput] { names.map(MapFixtures.stop) }

    private func withOnward(_ lines: [MapLineInput], _ onward: [MapStopInput]) -> [MapLineInput] {
        lines.map { var line = $0; line.onward = onward; return line }
    }

    @Test func nothingIsDrawnPastTheLastStop() {
        let scene = MapLayoutEngine.layout(MapFixtures.request(MapFixtures.main))
        #expect(scene.onward == nil)
        #expect(close(scene.convergence.nodeCenter.x, 1280 - 90))
    }

    @Test func aRouteThatGoesOnShowsItsNextStopAndADash() throws {
        let lines = withOnward(MapFixtures.main, Self.onward("LIGHTHOUSE", "SEA WALL"))
        let scene = MapLayoutEngine.layout(MapFixtures.request(lines))
        let onward = try #require(scene.onward)
        let node = scene.convergence.nodeCenter
        #expect(onward.lineID == "41")
        #expect(onward.label.text == "LIGHTHOUSE")
        #expect(onward.label.role == .stop)
        #expect(onward.terminus == nil)
        let ring = try #require(onward.stop)
        #expect(close(ring.center, CGPoint(x: node.x + 100, y: node.y)))
        #expect(onward.segments.contains { if case .dashed = $0 { true } else { false } })
        // The node made room: everything stays inside the canvas.
        #expect(onward.segments.allSatisfy { $0.end.x <= 1280 })
        #expect(node.x < 1280 - 90)
    }

    @Test func aNextStopThatEndsTheLineIsATerminusWithNoDash() throws {
        let lines = withOnward(MapFixtures.main, Self.onward("LIGHTHOUSE"))
        let scene = MapLayoutEngine.layout(MapFixtures.request(lines))
        let onward = try #require(scene.onward)
        #expect(onward.stop == nil)
        let terminus = try #require(onward.terminus)
        #expect(close(terminus.rect.midX, scene.convergence.nodeCenter.x + 100))
        #expect(onward.label.role == .terminus(colorIndex: 1))
        #expect(!onward.segments.contains { if case .dashed = $0 { true } else { false } })
    }

    @Test func theNodeSitsInOnePlaceWhicheverTheNextStopIs() {
        let continuing = MapLayoutEngine.layout(MapFixtures.request(
            withOnward(MapFixtures.main, Self.onward("LIGHTHOUSE", "SEA WALL"))))
        let ending = MapLayoutEngine.layout(MapFixtures.request(withOnward(MapFixtures.main, Self.onward("LIGHTHOUSE"))))
        #expect(close(continuing.convergence.nodeCenter, ending.convergence.nodeCenter))
    }

    @Test func portraitRunsTheNextStopDownwardsWithItsNameInTheColumn() throws {
        let lines = withOnward([MapFixtures.line41Main], Self.onward("LIGHTHOUSE", "SEA WALL"))
        let scene = MapLayoutEngine.layout(MapFixtures.request(
            lines, axis: .vertical, preset: .phone, canvas: CGSize(width: 390, height: 600)))
        let onward = try #require(scene.onward)
        let ring = try #require(onward.stop)
        #expect(close(ring.center.x, scene.convergence.nodeCenter.x))
        #expect(ring.center.y > scene.convergence.nodeCenter.y)
        #expect(onward.label.anchor.x > ring.center.x)
        #expect(onward.segments.allSatisfy { $0.end.y <= 600 })
    }

    @Test func onlyTheTrunkGoesOn() throws {
        var lines = MapFixtures.main
        lines[0].onward = Self.onward("NORTH POINT", "CAPE ROAD")   // 18, not the trunk
        #expect(MapLayoutEngine.layout(MapFixtures.request(lines)).onward == nil)
        #expect(MapLayoutEngine.layout(MapFixtures.request(lines, trunk: "18")).onward?.label.text == "NORTH POINT")
    }
}
