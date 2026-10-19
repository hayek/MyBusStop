import Testing
import Foundation
@testable import BusBus

struct HistoryLookupTests {

    private func setup(_ code: String, lines: [String], minutesAgo: Double, pinned: Bool = false) -> SavedSetup {
        SavedSetup(stop: TransitStop(code: code, name: "Stop \(code)", location: GeoPoint(lat: 0, lon: 0)),
                   lines: lines.map {
                       TransitLine(id: $0, shortName: $0, headsign: nil, agency: nil, origin: nil, destination: nil,
                                   isAccessible: nil, brandColorIndex: nil)
                   },
                   lastUsedAt: Date(timeIntervalSince1970: 10_000 - minutesAgo * 60), pinned: pinned)
    }

    private var history: [SavedSetup] {
        [setup("1", lines: ["18"], minutesAgo: 30),
         setup("2", lines: ["41", "7"], minutesAgo: 5),
         setup("3", lines: ["5"], minutesAgo: 90, pinned: true)]
    }

    @Test func sortsLikeThePicker() {
        #expect(HistoryLookup.sorted(history).map(\.stop.code) == ["3", "2", "1"])
    }

    @Test func theDefaultIsThePinnedEntry() {
        #expect(HistoryLookup.defaultEntry(in: history)?.stop.code == "3")
        #expect(HistoryLookup.defaultEntry(in: []) == nil)
    }

    @Test func entriesKeepTheOrderAskedForAndDropUnknownIDs() {
        let ids = [history[0].id, "gone", history[2].id]
        #expect(HistoryLookup.entries(ids: ids, in: history).map(\.stop.code) == ["1", "3"])
    }

    @Test func resolvesAChoiceTheDefaultOrWhatIsMissing() {
        #expect(HistoryLookup.resolve(id: history[1].id, in: history) == .setup(history[1]))
        #expect(HistoryLookup.resolve(id: nil, in: history) == .setup(history[2]))
        #expect(HistoryLookup.resolve(id: "gone", in: history) == .missing)
        #expect(HistoryLookup.resolve(id: nil, in: []) == .noHistory)
        #expect(HistoryLookup.resolve(id: "gone", in: []) == .noHistory)
    }

    @Test func theSubtitleListsTheLines() {
        #expect(HistoryLookup.subtitle(for: history[1]) == "41 · 7")
    }
}
