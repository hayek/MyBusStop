import Testing
import Foundation
@testable import BusBus

private let start = Date(timeIntervalSince1970: 1_800_000_000)

struct TrunkSelectorTests {

    @Test func firstCandidateAdoptedImmediately() {
        var selector = TrunkSelector()
        #expect(selector.select(candidateID: "41", now: start) == "41")
    }

    @Test func changeWithin30sIsIgnored() {
        var selector = TrunkSelector()
        _ = selector.select(candidateID: "41", now: start)
        #expect(selector.select(candidateID: "18", now: start.addingTimeInterval(29)) == "41")
    }

    @Test func changeAfter30sApplied() {
        var selector = TrunkSelector()
        _ = selector.select(candidateID: "41", now: start)
        #expect(selector.select(candidateID: "18", now: start.addingTimeInterval(30)) == "18")
    }

    @Test func nilCandidateKeepsCurrent() {
        var selector = TrunkSelector()
        _ = selector.select(candidateID: "41", now: start)
        #expect(selector.select(candidateID: nil, now: start.addingTimeInterval(120)) == "41")
    }

    @Test func manualPromotionWinsOverCandidate() {
        var selector = TrunkSelector()
        _ = selector.select(candidateID: "41", now: start)
        selector.manualTrunkID = "7"
        #expect(selector.select(candidateID: "18", now: start.addingTimeInterval(31)) == "7")
    }

    @Test func manualPromotionRespectsInterval() {
        var selector = TrunkSelector()
        _ = selector.select(candidateID: "41", now: start)
        selector.manualTrunkID = "7"
        #expect(selector.select(candidateID: "41", now: start.addingTimeInterval(5)) == "41")
        #expect(selector.select(candidateID: "41", now: start.addingTimeInterval(31)) == "7")
    }
}
