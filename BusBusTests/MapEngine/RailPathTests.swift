import Testing
import CoreGraphics
@testable import BusBus

struct RailPathTests {

    @Test func straightRail_acrossConstant() {
        let path = RailPath(segments: [.line(from: CGPoint(x: 0, y: 190), to: CGPoint(x: 500, y: 190))])
        #expect(path.across(atAlong: 0) == 190)
        #expect(path.across(atAlong: 250) == 190)
        #expect(path.across(atAlong: 500) == 190)
    }

    @Test func beforeAndAfterTheRail_clampsToTheEnds() {
        let path = RailPath(segments: [.line(from: CGPoint(x: 100, y: 70), to: CGPoint(x: 200, y: 70))])
        #expect(path.across(atAlong: -50) == 70)
        #expect(path.across(atAlong: 9999) == 70)
    }

    @Test func dashedSegment_isLinear() {
        let path = RailPath(segments: [.dashed(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 50), on: 20, off: 18)])
        #expect(abs(path.across(atAlong: 50) - 25) < 0.001)
    }

    @Test func cubic_endpointsExact() {
        let cubic = RailSegment.cubic(from: CGPoint(x: 1020, y: 70), c1: CGPoint(x: 1066, y: 70),
                                      c2: CGPoint(x: 1074, y: 190), to: CGPoint(x: 1120, y: 190))
        let path = RailPath(segments: [cubic])
        #expect(abs(path.across(atAlong: 1020) - 70) < 0.001)
        #expect(abs(path.across(atAlong: 1120) - 190) < 0.001)
    }

    @Test func cubic_midpointWithinTolerance() {
        // Main's convergence curve. Compare the along-parameterised approximation against the true
        // bezier, found by bisecting on x.
        let from = CGPoint(x: 1020, y: 70), c1 = CGPoint(x: 1066, y: 70)
        let c2 = CGPoint(x: 1074, y: 190), to = CGPoint(x: 1120, y: 190)
        func bezier(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            let v = 1 - t
            return v * v * v * a + 3 * v * v * t * b + 3 * v * t * t * c + t * t * t * d
        }
        let target: CGFloat = 1070
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if bezier(mid, from.x, c1.x, c2.x, to.x) < target { low = mid } else { high = mid }
        }
        let trueAcross = bezier((low + high) / 2, from.y, c1.y, c2.y, to.y)
        let approximated = RailPath(segments: [.cubic(from: from, c1: c1, c2: c2, to: to)]).across(atAlong: target)
        #expect(abs(approximated - trueAcross) <= 2)
    }

    @Test func multipleSegments_pickTheRightOne() {
        let path = RailPath(segments: [
            .line(from: CGPoint(x: 0, y: 70), to: CGPoint(x: 100, y: 70)),
            .cubic(from: CGPoint(x: 100, y: 70), c1: CGPoint(x: 150, y: 70), c2: CGPoint(x: 150, y: 190), to: CGPoint(x: 200, y: 190)),
            .line(from: CGPoint(x: 200, y: 190), to: CGPoint(x: 300, y: 190)),
        ])
        #expect(path.across(atAlong: 50) == 70)
        #expect(path.across(atAlong: 150) > 70 && path.across(atAlong: 150) < 190)
        #expect(path.across(atAlong: 250) == 190)
    }
}
