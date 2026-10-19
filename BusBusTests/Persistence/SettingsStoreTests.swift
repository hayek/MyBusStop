import Testing
import Foundation
import SwiftUI
@testable import BusBus

@MainActor
struct SettingsStoreTests {

    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "settings-\(UUID().uuidString)")!)
    }

    private func stop(_ code: String, _ name: String) -> TransitStop {
        TransitStop(code: code, name: name, city: "Harbor City", location: GeoPoint(lat: 32.9, lon: 34.95))
    }

    private func line(_ id: String) -> TransitLine {
        TransitLine(id: id, shortName: id, headsign: nil, agency: nil, origin: nil, destination: nil,
                    isAccessible: nil, brandColorIndex: nil)
    }

    @Test func roundTripsConfiguration() {
        let defaults = UserDefaults(suiteName: "settings-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        store.apply(stop: stop("41122", "ALLENBY"), lines: [line("18"), line("41")], providerID: "mock")

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.configuration?.stop.code == "41122")
        #expect(reloaded.configuration?.lines.map(\.id) == ["18", "41"])
        #expect(reloaded.configuration?.providerID == "mock")
    }

    @Test func choosingAStopIsRecordedInHistory() {
        let store = makeStore()
        store.apply(stop: stop("41122", "ALLENBY"), lines: [line("18"), line("41")], providerID: "mock")
        #expect(store.savedSetups.count == 1)
        #expect(store.savedSetups.first?.stop.code == "41122")
        #expect(store.savedSetups.first?.lineIDs == ["18", "41"])
    }

    @Test func theSameStopWithDifferentLinesIsASeparateEntry() {
        let store = makeStore()
        store.apply(stop: stop("41122", "ALLENBY"), lines: [line("18")], providerID: "mock")
        store.apply(stop: stop("41122", "ALLENBY"), lines: [line("18"), line("41")], providerID: "mock")
        #expect(store.savedSetups.count == 2)
    }

    @Test func searchTermsAreCappedAndDeduplicated() {
        let store = makeStore()
        for index in 0..<8 { store.rememberSearch("term \(index)") }
        #expect(store.recentSearches.count == 6)
        #expect(store.recentSearches.first == "term 7")

        store.rememberSearch("term 3")
        #expect(store.recentSearches.first == "term 3")
        #expect(store.recentSearches.filter { $0 == "term 3" }.count == 1)
    }

    @Test func tapBehaviourFollowsWallModeUntilOverridden() {
        let store = makeStore()
        #expect(store.tapBehaviour == .swap)
        store.wallMode = true
        #expect(store.tapBehaviour == .beside)
        store.tapBehaviourOverride = .swap
        #expect(store.tapBehaviour == .swap)
        store.tapBehaviourOverride = nil
        #expect(store.tapBehaviour == .beside)
    }

    @Test func historyAndSearchesSurviveARelaunch() {
        let defaults = UserDefaults(suiteName: "settings-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        store.apply(stop: stop("41122", "ALLENBY"), lines: [line("18")], providerID: "mock")
        store.rememberSearch("allenby")
        store.togglePin(try! #require(store.savedSetups.first).id)

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.savedSetups.count == 1)
        #expect(reloaded.savedSetups.first?.pinned == true)
        #expect(reloaded.recentSearches == ["allenby"])
    }

    @Test func paletteAssignmentsPersistAndStayDistinct() {
        let defaults = UserDefaults(suiteName: "settings-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        store.apply(stop: stop("1", "A"), lines: [line("18"), line("41"), line("7")], providerID: "mock")
        let assigned = ["18", "41", "7"].map { store.colorIndex(for: $0) }
        #expect(Set(assigned).count == 3)

        let reloaded = SettingsStore(defaults: defaults)
        #expect(["18", "41", "7"].map { reloaded.colorIndex(for: $0) } == assigned)
    }

    @Test func anOperatorsOwnColourIsHonoured() {
        let store = makeStore()
        var branded = line("41")
        branded.brandColorIndex = 5
        store.apply(stop: stop("1", "A"), lines: [branded], providerID: "mock")
        #expect(store.colorIndex(for: "41") == 5)
    }

    /// A wall display is a lit panel in a room. The rule for a dark room is to dim it, never to
    /// turn it cream.
    @Test func wallModeStaysDarkWhateverTheDeviceSays() {
        let store = makeStore()
        store.appearance = .light
        #expect(store.boardColorScheme == .light)

        store.wallMode = true
        #expect(store.boardColorScheme == .dark)

        store.appearance = .system
        #expect(store.boardColorScheme == .dark)

        store.wallMode = false
        #expect(store.boardColorScheme == nil)
    }

    @Test func inTheHandTheDeviceDecides() {
        let store = makeStore()
        #expect(store.appearance == .system)
        #expect(store.boardColorScheme == nil)
        store.appearance = .dark
        #expect(store.boardColorScheme == .dark)
    }

    @Test func defaultsAreTheOnesTheBriefAsksFor() {
        let store = makeStore()
        #expect(store.appearance == .system)
        #expect(store.wallMode == false)
        #expect(store.providerID == "bus.gov.il")
    }
}
