import SwiftUI

/// The three pages of the first-install welcome story, in order.
nonisolated enum WelcomePage: Int, CaseIterable, Sendable {
    /// The live map: two buses running down to your stop while the countdown reaches NOW.
    case map
    /// The old phone hung by the door.
    case wall
    /// Stops near you, and the one request for location.
    case nearby

    /// How long a page stays before the story turns it by itself, in seconds, its build in and
    /// build out included. Well past the artboard's 5 and 4.5, so there is time to read the words
    /// as well as watch. The last page asks something, but a rider who answers nothing is not kept
    /// on it: when its time is up the story closes onto the stop list, where NEARBY asks again.
    var seconds: Double {
        switch self {
        case .map: 9
        case .wall: 8.5
        case .nearby: 9
        }
    }

    /// When the story starts building the page out by itself: early enough that the page turns, or
    /// on the last page the story closes, just as its time is up.
    var buildOutAfter: Duration {
        .milliseconds(Int((seconds - WelcomeTimeline.buildOutSeconds) * 1000))
    }

    /// How long the page's progress bar takes to fill: the page's own time.
    var barFillSeconds: Double { seconds }

    var previous: WelcomePage? { WelcomePage(rawValue: rawValue - 1) }

    var next: WelcomePage? { WelcomePage(rawValue: rawValue + 1) }
}

/// Where everything in the story's pictures is, `t` seconds into a page. Pure, so the frames can
/// be tested and a still frame drawn for Reduce Motion or a screenshot.
///
/// Every keyframe is the artboard's CSS (`OnbAW3`). A keyframe's timing function runs between it
/// and the next one, so a move with a stop in the middle is eased in two pieces, as CSS does.
/// `still` is the artboard with its animations off: the state each element is drawn in before any
/// keyframe touches it.
///
/// Each page also builds in and out, the way a Keynote slide does, around the artboard's run. The
/// build in plays from the page's first frame; the build out from `leaving`, the seconds since the
/// rider (or the page's own timer) started leaving. A build out takes each element from wherever the
/// build in and the run had got it to, so a page left early folds away from where it stands: once a
/// page is leaving, only what loops (page 1's pulse, page 3's pings) keeps its own time.
nonisolated enum WelcomeTimeline {
    /// How long a page takes to build out before the next one comes in.
    static let buildOutSeconds: Double = 0.5
    /// How long the words take to rise in.
    static let wordsBuildInSeconds: Double = 0.5

    /// The page's time held at the moment it began leaving: what everything but a loop is drawn at
    /// while the page builds out.
    private static func held(_ seconds: Double, leaving: Double?) -> Double {
        leaving.map { max(0, seconds - $0) } ?? seconds
    }

    // MARK: Words

    struct WordsFrame: Hashable, Sendable {
        var opacity: Double
        /// Down from where the words rest, in design points; negative is up.
        var offsetY: Double
    }

    /// The title and message rise in with the art, as the artboard's `aw3Text` does, and rise on out
    /// of sight as it builds out.
    static func words(at t: Double, leaving: Double? = nil, still: Bool) -> WordsFrame {
        if still { return WordsFrame(opacity: 1, offsetY: 0) }
        let rise = eased(.easeOut, held(t, leaving: leaving) / wordsBuildInSeconds)
        let out = eased(.easeIn, (leaving ?? 0) / (buildOutSeconds * 0.8))
        return WordsFrame(opacity: rise * (1 - out), offsetY: 10 * (1 - rise) - 10 * out)
    }

    // MARK: Page 1, the live map

    enum Readout: Hashable, Sendable {
        case minutes(Int)
        case now
    }

    struct MapFrame: Hashable, Sendable {
        /// Distance down the rail, in design points.
        var puck41Y: Double
        var puck41Opacity: Double
        var puck18Y: Double
        var readout: Readout
        /// The ring round your stop, breathing.
        var pulseOpacity: Double
        var puck18Opacity: Double = 1
        /// The coloured blocks at the top of the rails, with their numbers.
        var termini: Double = 1
        /// How far each rail is drawn down from its terminus, 0…1.
        var rail41: Double = 1
        var rail18: Double = 1
        /// The stop rings, their names, your stop and YOUR STOP.
        var marks: Double = 1
        var readoutOpacity: Double = 1
        /// Down from where the readout rests, in design points.
        var readoutOffsetY: Double = 0
    }

    /// Line 41 travels its rail to your stop; line 18 drifts partway down its own.
    static let puck41Travel: Double = 214
    static let puck18Travel: Double = 150
    /// Line 18's puck on the still frame: centred at 90 on its rail, midway between the labels at
    /// baselines 60 and 129, so neither its body nor its halo touches one.
    static let stillPuck18Y: Double = 54
    /// The artboard's page 1 runs 5 s.
    static let mapDesignSeconds: Double = 5
    /// The map builds in for this long before the buses set off: termini, then the rails drawn down
    /// from them, 41 a beat ahead of 18, then the stops and their names, then the readout.
    static let mapBuildInSeconds: Double = 1.35
    /// The artboard's run is stretched over the page between the build in and the build out, so bus
    /// 41 reaches your stop and NOW holds a beat before the map folds away.
    static var mapRunSeconds: Double {
        WelcomePage.map.seconds - buildOutSeconds - mapBuildInSeconds
    }

    static func map(at seconds: Double, leaving: Double? = nil, still: Bool) -> MapFrame {
        if still {
            // Not the artboard's first frame: there both pucks sit on their termini, over the numbers
            // and names. Bus 41 is in at your stop, NOW; 18 waits between FOUNDRY RD and the folded
            // stops, clear of every label (at the end of its run its halo would bite PIER FOUR).
            return MapFrame(puck41Y: puck41Travel, puck41Opacity: 1, puck18Y: stillPuck18Y, readout: .now,
                            pulseOpacity: 1)
        }
        // Artboard time, from the end of the build in, held once the map is leaving. The pulse keeps
        // its own beat, in real seconds.
        let built = held(seconds, leaving: leaving)
        let t = max(0, built - mapBuildInSeconds) * mapDesignSeconds / mapRunSeconds
        let readout: Readout = switch t {
        case ..<1.25: .minutes(3)
        case ..<2.5: .minutes(2)
        case ..<3.75: .minutes(1)
        default: .now
        }
        // Build in.
        let marksIn = eased(.easeOut, (built - 0.7) / 0.45)
        let readoutIn = eased(.easeOut, (built - 0.8) / 0.5)
        // Build out: the pucks, names and readout go first, then the rails pull back up into their
        // termini, 41 leading as it did coming in, and the termini go last.
        let out = leaving.map { $0 / buildOutSeconds } ?? 0
        let marksOut = 1 - eased(.easeIn, out / 0.5)
        let readoutOut = eased(.easeIn, out / 0.6)
        let rail41Out = 1 - eased(.easeInOut, (out - 0.2) / 0.6)
        let rail18Out = 1 - eased(.easeInOut, (out - 0.3) / 0.6)
        let terminiOut = 1 - eased(.easeIn, (out - 0.75) / 0.25)
        return MapFrame(puck41Y: puck41Travel * eased(.easeInOut, t / 3.9),
                        puck41Opacity: eased(.easeInOut, t / 0.4) * marksOut,
                        puck18Y: puck18Travel * clamp(t / 5),
                        readout: readout,
                        pulseOpacity: pulse(at: seconds) * marksIn * marksOut,
                        // 18 comes in as it sets off, as 41 does, rather than over its terminus
                        // while the names build.
                        puck18Opacity: eased(.easeInOut, t / 0.4) * marksOut,
                        termini: eased(.easeOut, built / 0.25) * terminiOut,
                        rail41: min(eased(.easeInOut, (built - 0.1) / 0.8), rail41Out),
                        rail18: min(eased(.easeInOut, (built - 0.25) / 0.8), rail18Out),
                        marks: marksIn * marksOut,
                        readoutOpacity: readoutIn * (1 - readoutOut),
                        readoutOffsetY: 14 * (1 - readoutIn) + 14 * readoutOut)
    }

    /// 0.2 to 0.8 and back every 2.4 s, eased at both ends.
    private static func pulse(at t: Double) -> Double {
        let phase = cycle(t, period: 2.4)
        return phase < 0.5 ? 0.2 + 0.6 * eased(.easeInOut, phase * 2)
                           : 0.8 - 0.6 * eased(.easeInOut, (phase - 0.5) * 2)
    }

    // MARK: Page 2, the wall

    struct WallFrame: Hashable, Sendable {
        /// The phone dropping onto its hook, in scene points; 0 is hung.
        var phoneY: Double
        var phoneOpacity: Double
        /// How much of the charging cable is drawn, 0…1.
        var cable: Double
        var glow: Double
        /// The board on the phone's screen.
        var screen: Double
        /// The bus on the phone's map, in scene points along its rail.
        var puckX: Double
        var puckOpacity: Double
        /// The hallway's wall and floor.
        var room: Double = 1
        /// The door, its frame, the switch and the socket, settling onto the wall from above.
        var fixtures: Double = 1
        var fixturesY: Double = 0
        /// The whole picture, lifting away as it builds out.
        var sceneOpacity: Double = 1
        var sceneY: Double = 0
    }

    static let wallPuckTravel: Double = 64
    /// The room builds in for this long before the phone drops onto its hook.
    static let wallBuildInSeconds: Double = 0.7
    /// Page 2 is still from here until it builds out: the bus on the phone has reached its end.
    static let wallSettledSeconds: Double = wallBuildInSeconds + 1.8 + 2.4

    static func wall(at seconds: Double, leaving: Double? = nil, still: Bool) -> WallFrame {
        if still {
            return WallFrame(phoneY: 0, phoneOpacity: 1, cable: 1, glow: 1, screen: 1, puckX: 0, puckOpacity: 1)
        }
        // Build in: the room comes up out of the dark, its fixtures settling a moment behind. Nothing
        // on this page loops, so all of it is held once the page is leaving.
        let built = held(seconds, leaving: leaving)
        let room = eased(.easeOut, built / 0.5)
        let fixtures = eased(.easeOut, (built - 0.15) / 0.5)
        // Build out: the phone's screen goes dark, then the room lifts away.
        let out = leaving.map { $0 / buildOutSeconds } ?? 0
        let dim = 1 - eased(.easeIn, out / 0.45)
        let lift = eased(.easeIn, (out - 0.3) / 0.65)
        // The artboard's run, from the end of the build in.
        let t = built - wallBuildInSeconds
        // Drops past the hook and settles back: −28 → +4 at 70%, then 0.
        let hang = clamp(t / 1.1)
        let phoneY: Double, phoneOpacity: Double
        if hang < 0.7 {
            let k = eased(dropCurve, hang / 0.7)
            phoneY = -28 + 32 * k
            phoneOpacity = k
        } else {
            phoneY = 4 - 4 * eased(dropCurve, (hang - 0.7) / 0.3)
            phoneOpacity = 1
        }
        let puck = (t - 1.8) / 2.4
        return WallFrame(phoneY: phoneY, phoneOpacity: phoneOpacity,
                         cable: eased(.easeOut, (t - 0.6) / 0.9),
                         glow: eased(.easeOut, (t - 1.2) / 0.8) * dim,
                         screen: eased(.easeOut, (t - 1.3) / 0.5) * dim,
                         puckX: wallPuckTravel * clamp(puck),
                         puckOpacity: clamp(puck / 0.1) * dim,
                         room: room,
                         fixtures: fixtures,
                         fixturesY: -10 * (1 - fixtures),
                         sceneOpacity: 1 - lift,
                         sceneY: -12 * lift)
    }

    // MARK: Page 3, nearby

    struct Ping: Hashable, Sendable {
        var radius: Double
        var opacity: Double
    }

    struct Pop: Hashable, Sendable {
        var scale: Double
        var opacity: Double
    }

    struct NearbyFrame: Hashable, Sendable {
        var pings: [Ping]
        /// One per stop, closest first.
        var pops: [Pop]
        var roads: Double = 1
        /// How much of the 500 m circle is drawn, clockwise from the top, 0…1.
        var ring: Double = 1
        /// The circle and its 500 m chip, fading as the page builds out.
        var ringOpacity: Double = 1
        var ringLabel: Double = 1
        var rider = Pop(scale: 1, opacity: 1)
    }

    /// The ring's own radius; the ping scales it from 0.4× to 7.5×.
    static let pingBaseRadius: Double = 20
    /// When each stop appears after the build in, closest first.
    static let popStarts: [Double] = [0.5, 0.8, 1.1, 1.4]
    static let popDuration: Double = 0.45
    /// The plan builds in for this long before the rider starts pinging: the streets, then the 500 m
    /// circle drawn round from its chip, then the rider.
    static let nearbyBuildInSeconds: Double = 1
    /// How long each stop takes to shrink away as the page builds out, and the gap between them.
    static let stopOutSeconds: Double = 0.22
    static let stopOutStagger: Double = 0.08

    static func nearby(at seconds: Double, leaving: Double? = nil, still: Bool) -> NearbyFrame {
        if still {
            return NearbyFrame(pings: Array(repeating: Ping(radius: pingBaseRadius, opacity: 1), count: 2),
                               pops: Array(repeating: Pop(scale: 1, opacity: 1), count: popStarts.count))
        }
        // Everything but the pings is held once the plan is leaving.
        let built = held(seconds, leaving: leaving)
        let rider = pop(at: (built - 0.6) / 0.35)
        // Build out: the stops shrink away farthest first, then the rider, the circle and the streets.
        let out = leaving ?? 0
        let riderOut = 1 - eased(.easeIn, (out - 0.2) / 0.28)
        let ringOut = 1 - eased(.easeIn, (out - 0.15) / 0.33)
        let roadsOut = 1 - eased(.easeIn, (out - 0.25) / 0.23)
        let t = built - nearbyBuildInSeconds
        let last = popStarts.count - 1
        let pops = popStarts.indices.map { index in
            let shown = pop(at: (t - popStarts[index]) / popDuration)
            let kept = 1 - eased(.easeIn, (out - Double(last - index) * stopOutStagger) / stopOutSeconds)
            return Pop(scale: shown.scale * kept, opacity: shown.opacity * kept)
        }
        let ringing = seconds - nearbyBuildInSeconds
        let pings = [ping(at: ringing), ping(at: ringing - 1.2)].map {
            Ping(radius: $0.radius, opacity: $0.opacity * rider.opacity * riderOut)
        }
        return NearbyFrame(pings: pings,
                           pops: pops,
                           roads: eased(.easeOut, built / 0.4) * roadsOut,
                           ring: eased(.easeInOut, (built - 0.15) / 0.7),
                           ringOpacity: ringOut,
                           ringLabel: eased(.easeOut, (built - 0.1) / 0.25) * ringOut,
                           rider: Pop(scale: rider.scale * riderOut, opacity: rider.opacity * riderOut))
    }

    /// A ring spreading from the rider every 2.4 s. The second is held at its first frame until its
    /// delay is up, as CSS's `both` does.
    private static func ping(at t: Double) -> Ping {
        let k = eased(.easeOut, cycle(max(0, t), period: 2.4))
        return Ping(radius: pingBaseRadius * (0.4 + 7.1 * k), opacity: 0.8 * (1 - k))
    }

    /// Grows past full size and settles back: 0 → 1.12 at 70%, then 1.
    private static func pop(at progress: Double) -> Pop {
        let p = clamp(progress)
        if p < 0.7 {
            let k = eased(dropCurve, p / 0.7)
            return Pop(scale: 1.12 * k, opacity: k)
        }
        return Pop(scale: 1.12 - 0.12 * eased(dropCurve, (p - 0.7) / 0.3), opacity: 1)
    }

    // MARK: Chrome

    /// Whether the story turns its own pages. Not under Reduce Motion, where the bars stand still and
    /// a page would change with no warning, and not under VoiceOver, where it would pull the focus
    /// away from what is being read.
    static func autoAdvances(reduceMotion: Bool, voiceOver: Bool) -> Bool { !reduceMotion && !voiceOver }

    /// Each progress bar's fill, 0…1: pages already seen are full, later ones empty. With the story
    /// held still, the current bar is simply full.
    static func barFill(page: WelcomePage, elapsed: Double, still: Bool) -> [Double] {
        WelcomePage.allCases.map { bar in
            if bar.rawValue < page.rawValue { return 1 }
            if bar != page { return 0 }
            return still ? 1 : clamp(elapsed / page.barFillSeconds)
        }
    }

    // MARK: Curves

    /// The artboard's cubic-bezier(0.2, 0.9, 0.3, 1): quick out of the blocks, overshooting the
    /// keyframe it is heading for.
    static let dropCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.2, y: 0.9),
                                            endControlPoint: UnitPoint(x: 0.3, y: 1))

    private static func eased(_ curve: UnitCurve, _ progress: Double) -> Double {
        curve.value(at: clamp(progress))
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    /// Where `t` is within a repeating period, 0…1.
    private static func cycle(_ t: Double, period: Double) -> Double {
        let phase = t.truncatingRemainder(dividingBy: period) / period
        return phase < 0 ? phase + 1 : phase
    }
}
