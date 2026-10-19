import Testing
import Foundation
@testable import BusBus

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func stop(_ code: String) -> TransitStop {
    TransitStop(code: code, name: "STOP \(code)", city: nil, location: GeoPoint(lat: 0, lon: 0))
}

private func line(_ id: String) -> TransitLine {
    TransitLine(id: id, shortName: id, headsign: nil, agency: nil, origin: nil, destination: nil,
                isAccessible: nil, brandColorIndex: nil)
}

private func setup(_ code: String, lines ids: [String] = ["1"],
                   minutes: Double = 0, pinned: Bool = false) -> SavedSetup {
    SavedSetup(stop: stop(code), lines: ids.map(line),
               lastUsedAt: start.addingTimeInterval(minutes * 60), pinned: pinned)
}

struct SavedSetupTests {

    @Test func identityIsTheStopAndItsLines() {
        #expect(setup("1", lines: ["a", "b"]).id == setup("1", lines: ["a", "b"], minutes: 99).id)
        #expect(setup("1", lines: ["a", "b"]).id == setup("1", lines: ["b", "a"]).id)
        #expect(setup("1", lines: ["a"]).id != setup("1", lines: ["a", "b"]).id)
        #expect(setup("1", lines: ["a"]).id != setup("2", lines: ["a"]).id)
    }

    @Test func pinnedComeFirstThenMostRecentlyUsed() {
        let ordered = SavedSetups.sorted([
            setup("old", minutes: 1),
            setup("new", minutes: 9),
            setup("pinned-old", minutes: 2, pinned: true),
        ])
        #expect(ordered.map(\.stop.code) == ["pinned-old", "new", "old"])
    }

    @Test func theUnpinnedTailAgesOut() {
        let many = (0..<12).map { setup("s\($0)", minutes: Double($0)) }
        let kept = SavedSetups.capped(many)
        #expect(kept.count == SavedSetups.limit)
        // The newest survive; the oldest are the ones dropped.
        #expect(kept.first?.stop.code == "s11")
        #expect(kept.contains { $0.stop.code == "s0" } == false)
    }

    /// A pin is a promise that the entry stays, so it outranks the cap.
    @Test func pinsAreNeverAgedOut() {
        var many = (0..<12).map { setup("s\($0)", minutes: Double($0)) }
        many[0].pinned = true
        let kept = SavedSetups.capped(many)
        #expect(kept.contains { $0.stop.code == "s0" })
        #expect(kept.count == SavedSetups.limit)
    }

    @Test func morePinsThanTheCapAreAllKept() {
        let pinned = (0..<10).map { setup("p\($0)", minutes: Double($0), pinned: true) }
        #expect(SavedSetups.capped(pinned).count == 10)
    }

    @Test func recordingAnExistingSetupMovesItUpWithoutDuplicating() {
        let existing = [setup("a", minutes: 1), setup("b", minutes: 2)]
        let updated = SavedSetups.recording(setup("a", minutes: 9), in: existing)
        #expect(updated.count == 2)
        #expect(updated.first?.stop.code == "a")
    }

    /// Reusing an entry must not quietly unpin it.
    @Test func recordingKeepsAnExistingPin() {
        let existing = [setup("a", minutes: 1, pinned: true)]
        let updated = SavedSetups.recording(setup("a", minutes: 9), in: existing)
        #expect(updated.first?.pinned == true)
    }

    @Test func pinningAndRemoving() {
        let existing = [setup("a"), setup("b")]
        let pinned = SavedSetups.togglingPin(id: setup("a").id, in: existing)
        #expect(pinned.first?.stop.code == "a")
        #expect(pinned.first?.pinned == true)

        let unpinned = SavedSetups.togglingPin(id: setup("a").id, in: pinned)
        #expect(unpinned.first { $0.stop.code == "a" }?.pinned == false)

        #expect(SavedSetups.removing(id: setup("a").id, from: existing).map(\.stop.code) == ["b"])
    }
}

struct RecentSearchTests {

    @Test func mostRecentFirstWithoutDuplicates() {
        var terms = RecentSearches.recording("allenby", in: [])
        terms = RecentSearches.recording("herzl", in: terms)
        terms = RecentSearches.recording("ALLENBY", in: terms)
        #expect(terms == ["ALLENBY", "herzl"])
    }

    @Test func cappedAtSix() {
        var terms: [String] = []
        for index in 0..<10 { terms = RecentSearches.recording("term \(index)", in: terms) }
        #expect(terms.count == 6)
        #expect(terms.first == "term 9")
    }

    /// A single character matches almost everything; it is not a search worth keeping.
    @Test func tooShortToKeep() {
        #expect(RecentSearches.recording("a", in: []) == [])
        #expect(RecentSearches.recording("   ", in: []) == [])
        #expect(RecentSearches.recording("  ab  ", in: []) == ["ab"])
    }
}
