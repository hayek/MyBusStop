import Testing
import Foundation
@testable import BusBus

/// The story's frames against the artboard's CSS keyframes.
struct WelcomeTimelineTests {
    /// Page 1 plays the artboard's 5 s run between its build in and its build out: artboard second
    /// `t` lands at `runStart + t * stretch`.
    let runStart = WelcomeTimeline.mapBuildInSeconds
    let stretch = (9.0 - 0.5 - 1.35) / 5
    func run(_ t: Double) -> Double { runStart + t * stretch }
    /// Page 2's and page 3's artboard runs start once their build in has played.
    let wallStart = WelcomeTimeline.wallBuildInSeconds
    let nearbyStart = WelcomeTimeline.nearbyBuildInSeconds

    @Test func theCountdownReachesNowAsTheBusArrives() {
        #expect(WelcomeTimeline.map(at: 0, still: false).readout == .minutes(3))
        #expect(WelcomeTimeline.map(at: run(0.1), still: false).readout == .minutes(3))
        #expect(WelcomeTimeline.map(at: run(1.3), still: false).readout == .minutes(2))
        #expect(WelcomeTimeline.map(at: run(2.6), still: false).readout == .minutes(1))
        #expect(WelcomeTimeline.map(at: run(3.8), still: false).readout == .now)
    }

    /// The run fits between the build in and the build out: the buses wait for the map to be drawn,
    /// and bus 41 is in, on NOW, a beat before the map folds away.
    @Test func thePage1RunFitsBetweenItsBuilds() {
        #expect(abs(WelcomeTimeline.mapRunSeconds - 7.15) < 1e-9)
        let buildOutStarts = 9 - WelcomeTimeline.buildOutSeconds
        let built = WelcomeTimeline.map(at: runStart, still: false)
        #expect(built.puck41Y == 0 && built.puck18Y == 0 && built.readout == .minutes(3))
        #expect(built.rail41 == 1 && built.rail18 == 1 && built.marks == 1 && built.readoutOpacity == 1)
        // NOW and bus 41's arrival come more than a second before the build out starts.
        #expect(WelcomeTimeline.map(at: buildOutStarts - 1.5, still: false).readout == .now)
        #expect(abs(WelcomeTimeline.map(at: buildOutStarts - 1.5, still: false).puck41Y - 214) < 0.001)
        // Bus 18 finishes its drift just as the build out starts.
        #expect(abs(WelcomeTimeline.map(at: buildOutStarts, still: false).puck18Y - 150) < 0.001)
    }

    @Test func bus41RidesItsRailIntoYourStopAndStays() {
        #expect(WelcomeTimeline.map(at: 0, still: false).puck41Y == 0)
        #expect(WelcomeTimeline.map(at: runStart, still: false).puck41Y == 0)
        #expect(abs(WelcomeTimeline.map(at: run(3.9), still: false).puck41Y - 214) < 0.001)
        #expect(abs(WelcomeTimeline.map(at: 9.0, still: false).puck41Y - 214) < 0.001)
        for t in stride(from: 0.0, through: 10, by: 0.1) {
            let y = WelcomeTimeline.map(at: t, still: false).puck41Y
            #expect((0...214.0001).contains(y), "t=\(t)")
        }
        #expect(WelcomeTimeline.map(at: runStart, still: false).puck41Opacity == 0)
        #expect(WelcomeTimeline.map(at: run(0.4), still: false).puck41Opacity == 1)
    }

    @Test func bus18DriftsAtAnEvenPace() {
        #expect(abs(WelcomeTimeline.map(at: run(2.5), still: false).puck18Y - 75) < 0.001)
        #expect(abs(WelcomeTimeline.map(at: run(5), still: false).puck18Y - 150) < 0.001)
    }

    @Test func theCableIsDrawnBetweenItsKeyframes() {
        #expect(WelcomeTimeline.wall(at: wallStart + 0.5, still: false).cable == 0)
        #expect(WelcomeTimeline.wall(at: wallStart + 0.6, still: false).cable == 0)
        let midway = WelcomeTimeline.wall(at: wallStart + 1.0, still: false).cable
        #expect(midway > 0 && midway < 1)
        #expect(WelcomeTimeline.wall(at: wallStart + 1.5, still: false).cable == 1)
        #expect(WelcomeTimeline.wall(at: wallStart + 3, still: false).cable == 1)
    }

    @Test func thePhoneDropsPastItsHookAndSettles() {
        let start = WelcomeTimeline.wall(at: wallStart, still: false)
        #expect(start.phoneY == -28)
        #expect(start.phoneOpacity == 0)
        #expect(WelcomeTimeline.wall(at: 0, still: false).phoneOpacity == 0)
        #expect(abs(WelcomeTimeline.wall(at: wallStart + 0.77, still: false).phoneY - 4) < 0.001)
        #expect(WelcomeTimeline.wall(at: wallStart + 1.1, still: false).phoneY == 0)
        #expect(WelcomeTimeline.wall(at: wallStart + 1.8, still: false).puckOpacity == 0)
        #expect(abs(WelcomeTimeline.wall(at: wallStart + 4.2, still: false).puckX - 64) < 0.001)
    }

    @Test func stopsPopInClosestFirst() {
        #expect(WelcomeTimeline.nearby(at: nearbyStart + 0.49, still: false).pops[0].scale == 0)
        #expect(abs(WelcomeTimeline.nearby(at: nearbyStart + 0.5 + 0.315, still: false).pops[0].scale - 1.12) < 0.01)
        #expect(WelcomeTimeline.nearby(at: nearbyStart + 0.95, still: false).pops[0].scale == 1)
        // Each later stop is still smaller than the one before it at any moment of the pop.
        for t in stride(from: nearbyStart + 0.5, through: nearbyStart + 1.6, by: 0.05) {
            let pops = WelcomeTimeline.nearby(at: t, still: false).pops
            for index in 1..<pops.count {
                #expect(pops[index].opacity <= pops[index - 1].opacity, "t=\(t)")
            }
        }
    }

    @Test func thePingRepeatsEveryTwoPointFourSeconds() {
        for t in [0.3, 1.0, 1.9].map({ $0 + nearbyStart }) {
            let now = WelcomeTimeline.nearby(at: t + 2.4, still: false).pings
            let later = WelcomeTimeline.nearby(at: t + 4.8, still: false).pings
            #expect(abs(now[0].radius - later[0].radius) < 0.0001)
            #expect(abs(now[1].opacity - later[1].opacity) < 0.0001)
        }
        let start = WelcomeTimeline.nearby(at: nearbyStart, still: false).pings[0]
        #expect(abs(start.radius - 8) < 0.0001)
        #expect(abs(start.opacity - 0.8) < 0.0001)
        // The second ring waits on its first frame.
        #expect(abs(WelcomeTimeline.nearby(at: nearbyStart + 0.6, still: false).pings[1].radius - 8) < 0.0001)
        // Nothing pings before the rider is there to ping from.
        #expect(WelcomeTimeline.nearby(at: 0, still: false).pings.allSatisfy { $0.opacity == 0 })
    }

    /// Reduce Motion draws the artboard with its animations off.
    @Test func stillFramesAreTheArtboardsRestingState() {
        // Page 1 rests with bus 41 in at your stop, NOW, and 18 between labels: its first frame
        // would put both pucks over the termini.
        #expect(WelcomeTimeline.map(at: 3, still: true)
                == .init(puck41Y: 214, puck41Opacity: 1, puck18Y: 54, readout: .now, pulseOpacity: 1))
        let ending = WelcomeTimeline.map(at: 9, still: false)
        #expect(abs(ending.puck41Y - 214) < 0.001 && ending.readout == .now)
        #expect(WelcomeTimeline.wall(at: 0, still: true)
                == .init(phoneY: 0, phoneOpacity: 1, cable: 1, glow: 1, screen: 1, puckX: 0, puckOpacity: 1))
        let nearby = WelcomeTimeline.nearby(at: 0, still: true)
        #expect(nearby.pops.allSatisfy { $0.scale == 1 && $0.opacity == 1 })
        #expect(nearby.pings.allSatisfy { $0.radius == 20 })
    }

    @Test func pagesTurnThemselvesOnlyWithoutReduceMotionOrVoiceOver() {
        #expect(WelcomeTimeline.autoAdvances(reduceMotion: false, voiceOver: false))
        #expect(!WelcomeTimeline.autoAdvances(reduceMotion: true, voiceOver: false))
        #expect(!WelcomeTimeline.autoAdvances(reduceMotion: false, voiceOver: true))
    }

    @Test func pageTimingsAndBars() {
        // Longer than the artboard's 5 and 4.5 s, to leave time for the words.
        #expect(WelcomePage.allCases.map(\.seconds) == [9, 8.5, 9])
        // The build out starts early enough for the page to turn on time.
        #expect(WelcomePage.allCases.map(\.buildOutAfter) == [.milliseconds(8500), .seconds(8), .milliseconds(8500)])
        #expect(WelcomePage.allCases.map(\.barFillSeconds) == [9, 8.5, 9])
        #expect(WelcomeTimeline.barFill(page: .map, elapsed: 2, still: true) == [1, 0, 0])
        #expect(WelcomeTimeline.barFill(page: .map, elapsed: 4.5, still: false) == [0.5, 0, 0])
        #expect(WelcomeTimeline.barFill(page: .wall, elapsed: 4.25, still: false) == [1, 0.5, 0])
        #expect(WelcomeTimeline.barFill(page: .nearby, elapsed: 4.5, still: false) == [1, 1, 0.5])
    }

    // MARK: Builds

    @Test func theMapBuildsInFromItsTermini() {
        let first = WelcomeTimeline.map(at: 0, still: false)
        #expect(first.rail41 == 0 && first.rail18 == 0 && first.termini == 0)
        #expect(first.marks == 0 && first.readoutOpacity == 0 && first.readoutOffsetY == 14)
        #expect(first.puck18Opacity == 0 && first.puck41Opacity == 0 && first.pulseOpacity == 0)
        // 41 is drawn a beat ahead of 18, and both are down before the stops appear.
        let drawing = WelcomeTimeline.map(at: 0.5, still: false)
        #expect(drawing.rail41 > drawing.rail18 && drawing.rail18 > 0 && drawing.rail41 < 1)
        #expect(drawing.termini == 1 && drawing.marks == 0)
        let rising = WelcomeTimeline.map(at: 1.1, still: false)
        #expect(rising.rail41 == 1 && rising.rail18 == 1)
        #expect(rising.readoutOpacity > 0 && rising.readoutOpacity < 1 && rising.readoutOffsetY > 0)
        let built = WelcomeTimeline.map(at: WelcomeTimeline.mapBuildInSeconds, still: false)
        #expect(built.termini == 1 && built.marks == 1 && built.readoutOpacity == 1 && built.readoutOffsetY == 0)
    }

    @Test func theMapBuildsOutBackIntoItsTermini() {
        let t = 8.5
        let resting = WelcomeTimeline.map(at: t, leaving: 0, still: false)
        #expect(resting == WelcomeTimeline.map(at: t, still: false))
        #expect(resting.rail41 == 1 && resting.marks == 1 && resting.readoutOpacity == 1)
        // The names and the readout go first, while the rails are still there…
        let early = WelcomeTimeline.map(at: t + 0.15, leaving: 0.15, still: false)
        #expect(early.marks < 1 && early.readoutOpacity < 1 && early.readoutOffsetY > 0)
        #expect(early.rail41 > 0.9 && early.termini == 1)
        // …then the rails pull back up, 41 ahead of 18.
        let pulling = WelcomeTimeline.map(at: t + 0.3, leaving: 0.3, still: false)
        #expect(pulling.marks == 0 && pulling.rail41 < pulling.rail18 && pulling.rail18 < 1)
        let gone = WelcomeTimeline.map(at: t + 0.5, leaving: 0.5, still: false)
        #expect(gone.rail41 == 0 && gone.rail18 == 0 && gone.termini == 0 && gone.marks == 0)
        #expect(gone.readoutOpacity == 0 && gone.puck41Opacity == 0 && gone.puck18Opacity == 0 && gone.pulseOpacity == 0)
    }

    /// Left at any moment, early in its build in or late in its run, a page folds away from where it
    /// stands: nothing that was still coming in goes on coming in while it builds out.
    @Test(arguments: [0.05, 0.3, 0.6, 0.9, 1.2, 1.6, 2.5, 4, 8.5])
    func aPageLeftEarlyFoldsAwayFromWhereItStands(_ left: Double) {
        let outs = stride(from: 0.0, through: WelcomeTimeline.buildOutSeconds, by: 0.02).map { $0 }
        func expectFolding(_ name: String, _ values: [Double]) {
            for index in values.indices.dropFirst() {
                #expect(values[index] <= values[index - 1] + 1e-9,
                        "\(name) grows while leaving at \(left) s, \(outs[index]) s in")
            }
        }
        let maps = outs.map { WelcomeTimeline.map(at: left + $0, leaving: $0, still: false) }
        #expect(maps[0] == WelcomeTimeline.map(at: left, still: false))
        expectFolding("termini", maps.map(\.termini))
        expectFolding("rail 41", maps.map(\.rail41))
        expectFolding("rail 18", maps.map(\.rail18))
        expectFolding("marks", maps.map(\.marks))
        expectFolding("readout", maps.map(\.readoutOpacity))
        expectFolding("bus 41", maps.map(\.puck41Opacity))
        expectFolding("bus 18", maps.map(\.puck18Opacity))
        // The readout only sinks.
        expectFolding("readout rise", maps.map { -$0.readoutOffsetY })

        let walls = outs.map { WelcomeTimeline.wall(at: left + $0, leaving: $0, still: false) }
        #expect(walls[0] == WelcomeTimeline.wall(at: left, still: false))
        expectFolding("room", walls.map(\.room))
        expectFolding("fixtures", walls.map(\.fixtures))
        expectFolding("fixtures settling", walls.map(\.fixturesY))
        expectFolding("phone", walls.map(\.phoneOpacity))
        expectFolding("cable", walls.map(\.cable))
        expectFolding("glow", walls.map(\.glow))
        expectFolding("screen", walls.map(\.screen))
        expectFolding("wall bus", walls.map(\.puckOpacity))
        expectFolding("scene", walls.map(\.sceneOpacity))

        let plans = outs.map { WelcomeTimeline.nearby(at: left + $0, leaving: $0, still: false) }
        #expect(plans[0] == WelcomeTimeline.nearby(at: left, still: false))
        expectFolding("roads", plans.map(\.roads))
        expectFolding("ring", plans.map(\.ring))
        expectFolding("ring fade", plans.map(\.ringOpacity))
        expectFolding("ring label", plans.map(\.ringLabel))
        expectFolding("rider", plans.map(\.rider.opacity))
        for index in WelcomeTimeline.popStarts.indices {
            expectFolding("stop \(index)", plans.map { $0.pops[index].opacity })
        }

        let words = outs.map { WelcomeTimeline.words(at: left + $0, leaving: $0, still: false) }
        #expect(words[0] == WelcomeTimeline.words(at: left, still: false))
        expectFolding("words", words.map(\.opacity))
        expectFolding("words rising", words.map(\.offsetY))
    }

    @Test func theWallBuildsInWithTheRoomFirst() {
        let first = WelcomeTimeline.wall(at: 0, still: false)
        #expect(first.room == 0 && first.fixtures == 0 && first.fixturesY == -10 && first.phoneOpacity == 0)
        let settling = WelcomeTimeline.wall(at: 0.4, still: false)
        #expect(settling.room > settling.fixtures && settling.fixtures > 0 && settling.fixturesY < 0)
        #expect(settling.phoneOpacity == 0)
        let built = WelcomeTimeline.wall(at: wallStart, still: false)
        #expect(built.room == 1 && built.fixtures == 1 && built.fixturesY == 0 && built.phoneOpacity == 0)
        let mid = WelcomeTimeline.wall(at: 5, still: false)
        #expect(mid.room == 1 && mid.screen == 1 && mid.glow == 1 && mid.sceneOpacity == 1 && mid.sceneY == 0)
    }

    @Test func theWallBuildsOutWithTheScreenGoingDark() {
        let t = 8.0
        let dimming = WelcomeTimeline.wall(at: t + 0.1, leaving: 0.1, still: false)
        #expect(dimming.screen < 1 && dimming.glow < 1 && dimming.sceneOpacity == 1)
        let dark = WelcomeTimeline.wall(at: t + 0.25, leaving: 0.25, still: false)
        #expect(dark.screen == 0 && dark.glow == 0 && dark.puckOpacity == 0)
        #expect(dark.sceneOpacity < 1 && dark.sceneY < 0)
        let gone = WelcomeTimeline.wall(at: t + 0.5, leaving: 0.5, still: false)
        #expect(gone.sceneOpacity == 0 && abs(gone.sceneY + 12) < 1e-9)
    }

    @Test func theNearbyPlanBuildsInStreetsRingThenRider() {
        let first = WelcomeTimeline.nearby(at: 0, still: false)
        #expect(first.roads == 0 && first.ring == 0 && first.ringLabel == 0 && first.rider.opacity == 0)
        #expect(first.pops.allSatisfy { $0.opacity == 0 })
        let drawing = WelcomeTimeline.nearby(at: 0.5, still: false)
        #expect(drawing.roads == 1 && drawing.ring > 0 && drawing.ring < 1 && drawing.ringLabel == 1)
        #expect(drawing.rider.opacity == 0)
        let built = WelcomeTimeline.nearby(at: nearbyStart, still: false)
        #expect(built.ring == 1 && built.rider.opacity == 1 && abs(built.rider.scale - 1) < 0.001)
        #expect(built.pops.allSatisfy { $0.opacity == 0 })
        let mid = WelcomeTimeline.nearby(at: 4, still: false)
        #expect(mid.pops.allSatisfy { $0 == .init(scale: 1, opacity: 1) } && mid.ringOpacity == 1)
    }

    @Test func theNearbyStopsShrinkAwayFarthestFirst() {
        let t = 4.0
        #expect(WelcomeTimeline.nearby(at: t, leaving: 0, still: false) == WelcomeTimeline.nearby(at: t, still: false))
        for out in stride(from: 0.02, through: 0.45, by: 0.02) {
            let pops = WelcomeTimeline.nearby(at: t + out, leaving: out, still: false).pops
            for index in 1..<pops.count {
                #expect(pops[index].scale <= pops[index - 1].scale, "out=\(out)")
            }
        }
        let early = WelcomeTimeline.nearby(at: t + 0.15, leaving: 0.15, still: false)
        #expect(early.pops[3].scale < 1 && early.pops[0].scale == 1 && early.rider.opacity == 1)
        let gone = WelcomeTimeline.nearby(at: t + 0.5, leaving: 0.5, still: false)
        #expect(gone.pops.allSatisfy { $0.scale == 0 && $0.opacity == 0 })
        #expect(gone.rider.opacity == 0 && gone.ringOpacity == 0 && gone.ringLabel == 0 && gone.roads == 0)
        #expect(gone.pings.allSatisfy { $0.opacity == 0 })
    }

    @Test func theWordsRiseInAndOnOut() {
        #expect(WelcomeTimeline.words(at: 0, still: false) == .init(opacity: 0, offsetY: 10))
        #expect(WelcomeTimeline.words(at: 0.5, still: false) == .init(opacity: 1, offsetY: 0))
        let leaving = WelcomeTimeline.words(at: 5.2, leaving: 0.2, still: false)
        #expect(leaving.opacity > 0 && leaving.opacity < 1 && leaving.offsetY < 0)
        #expect(WelcomeTimeline.words(at: 5.5, leaving: 0.5, still: false) == .init(opacity: 0, offsetY: -10))
    }

    /// Reduce Motion and renders never build: a still frame is the same with or without a build out.
    @Test func stillFramesIgnoreTheBuilds() {
        #expect(WelcomeTimeline.map(at: 0, leaving: 0.3, still: true) == WelcomeTimeline.map(at: 0, still: true))
        #expect(WelcomeTimeline.wall(at: 0, leaving: 0.3, still: true) == WelcomeTimeline.wall(at: 0, still: true))
        #expect(WelcomeTimeline.nearby(at: 0, leaving: 0.3, still: true) == WelcomeTimeline.nearby(at: 0, still: true))
        #expect(WelcomeTimeline.words(at: 0, leaving: 0.3, still: true) == .init(opacity: 1, offsetY: 0))
        let map = WelcomeTimeline.map(at: 0, still: true)
        #expect(map.rail41 == 1 && map.rail18 == 1 && map.termini == 1 && map.marks == 1 && map.readoutOpacity == 1)
        let nearby = WelcomeTimeline.nearby(at: 0, still: true)
        #expect(nearby.ring == 1 && nearby.roads == 1 && nearby.rider.opacity == 1)
    }
}
