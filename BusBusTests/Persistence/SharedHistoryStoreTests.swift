import Testing
import Foundation
@testable import BusBus

/// The history lives in the App Group suite, where the widget reads it.
@MainActor
struct SharedHistoryStoreTests {

    private func suite(_ name: String) -> UserDefaults {
        UserDefaults(suiteName: "\(name)-\(UUID().uuidString)")!
    }

    private func stop(_ code: String, _ name: String) -> TransitStop {
        TransitStop(code: code, name: name, city: "Harbor City", location: GeoPoint(lat: 32.9, lon: 34.95))
    }

    private func line(_ id: String) -> TransitLine {
        TransitLine(id: id, shortName: id, headsign: nil, agency: nil, origin: nil, destination: nil,
                    isAccessible: nil, brandColorIndex: nil)
    }

    @Test func roundTripsHistory() {
        let store = SharedHistoryStore(defaults: suite("shared"))
        #expect(store.stored() == nil)
        let setup = SavedSetup(stop: stop("41122", "ALLENBY"), lines: [line("18")],
                               lastUsedAt: Date(timeIntervalSince1970: 1_000), pinned: true, providerID: "mbta")
        store.save([setup])
        #expect(store.load() == [setup])
    }

    /// Removing every entry leaves an empty list behind, not an absent one — or the old copy
    /// would be migrated back in on the next launch.
    @Test func anEmptiedHistoryIsStillStored() {
        let store = SharedHistoryStore(defaults: suite("shared"))
        store.save([])
        #expect(store.stored() == [])
    }

    @Test func theStoreWritesHistoryAndColoursToTheSharedSuite() {
        let defaults = suite("own"), shared = suite("shared")
        let store = SettingsStore(defaults: defaults, shared: shared)
        store.apply(stop: stop("41122", "ALLENBY"), lines: [line("18"), line("41")], providerID: "mock")

        let history = SharedHistoryStore(defaults: shared)
        #expect(history.load().map(\.id) == [store.savedSetups[0].id])
        #expect(history.paletteAssignments() == store.paletteAssignments)
        #expect(!store.paletteAssignments.isEmpty)
        // A copy stays in the app's own suite, for a launch that finds the shared one gone.
        #expect(defaults.data(forKey: "board.savedSetups") != nil)
        #expect(SettingsStore(defaults: defaults, shared: shared).savedSetups.map(\.id) == store.savedSetups.map(\.id))
    }

    @Test func appearanceAndLanguageAreMirrored() {
        let defaults = suite("own"), shared = suite("shared")
        let store = SettingsStore(defaults: defaults, shared: shared)
        store.appearance = .light
        store.language = "he"
        #expect(SharedHistoryStore(defaults: shared).appearance() == .light)
        #expect(shared.string(forKey: SharedKeys.language) == "he")
        store.language = nil
        #expect(shared.string(forKey: SharedKeys.language) == nil)
    }

    /// History saved by an earlier version, in the app's own suite, moves to the shared one on the
    /// first launch after the update. The old copy is left alone.
    @Test func legacyHistoryIsMigratedOnce() throws {
        let defaults = suite("own"), shared = suite("shared")
        let legacy = [SavedSetup(stop: stop("41122", "ALLENBY"), lines: [line("18")],
                                 lastUsedAt: Date(timeIntervalSince1970: 1_000))]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "board.savedSetups")

        let store = SettingsStore(defaults: defaults, shared: shared)
        #expect(store.savedSetups == legacy)
        #expect(SharedHistoryStore(defaults: shared).stored() == legacy)
        #expect(defaults.data(forKey: "board.savedSetups") != nil)

        // Emptied afterwards, it stays empty: the legacy copy is not read a second time.
        store.removeSetup(legacy[0].id)
        #expect(SettingsStore(defaults: defaults, shared: shared).savedSetups.isEmpty)
    }

    /// Emptied, it stays empty however often the app launches: the empty list is stored, not
    /// taken for a missing one, and the app's own copy is emptied too.
    @Test func anEmptiedHistoryIsNotMigratedAgain() throws {
        let defaults = suite("own"), shared = suite("shared")
        let legacy = [SavedSetup(stop: stop("41122", "ALLENBY"), lines: [line("18")],
                                 lastUsedAt: Date(timeIntervalSince1970: 1_000))]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "board.savedSetups")
        SettingsStore(defaults: defaults, shared: shared).removeSetup(legacy[0].id)
        for _ in 0..<2 {
            #expect(SettingsStore(defaults: defaults, shared: shared).savedSetups.isEmpty)
        }
        // Even with the shared copy lost, the app's own is empty as well.
        #expect(SettingsStore(defaults: defaults, shared: suite("fresh")).savedSetups.isEmpty)
    }

    /// The shared suite in use can change between launches — a build signed without the group,
    /// then one with it. Neither launch loses what the other saved, and neither brings back what
    /// it removed.
    @Test func switchingSharedSuitesKeepsTheLatestHistory() throws {
        let defaults = suite("own"), first = suite("group"), second = suite("fallback")
        let allenby = stop("41122", "ALLENBY"), dizengoff = stop("25314", "DIZENGOFF")

        let before = SettingsStore(defaults: defaults, shared: first)
        before.apply(stop: allenby, lines: [line("18")], providerID: "mock")

        // Launched against a suite that has never seen the history: the app's own copy carries it.
        let during = SettingsStore(defaults: defaults, shared: second)
        #expect(during.savedSetups.map(\.stop.code) == ["41122"])
        during.apply(stop: dizengoff, lines: [line("5")], providerID: "mock")
        during.removeSetup(during.savedSetups.first { $0.stop.code == "41122" }!.id)

        // Back on the first suite, whose copy is now behind: the later one wins.
        let after = SettingsStore(defaults: defaults, shared: first)
        #expect(after.savedSetups.map(\.stop.code) == ["25314"])
        #expect(SharedHistoryStore(defaults: first).load().map(\.stop.code) == ["25314"])
    }

    /// A shared copy this build cannot read is not overwritten at launch: the app runs on its own
    /// copy and leaves the blob for whichever build wrote it.
    @Test func anUnreadableSharedCopyIsLeftAlone() throws {
        let defaults = suite("own"), shared = suite("shared")
        let legacy = [SavedSetup(stop: stop("41122", "ALLENBY"), lines: [line("18")],
                                 lastUsedAt: Date(timeIntervalSince1970: 1_000))]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "board.savedSetups")
        let blob = Data("{\"not\": \"a history\"}".utf8)
        shared.set(blob, forKey: SharedKeys.history)

        #expect(SharedHistoryStore(defaults: shared).contents() == .unreadable)
        #expect(SharedHistoryStore(defaults: shared).stored() == nil)
        let store = SettingsStore(defaults: defaults, shared: shared)
        #expect(store.savedSetups == legacy)
        #expect(shared.data(forKey: SharedKeys.history) == blob)
    }

    /// The remote switches reach the widget: what the app would not use, it will not call.
    @Test func providerSwitchesAreMirrored() {
        let defaults = suite("own"), shared = suite("shared")
        let store = SettingsStore(defaults: defaults, shared: shared)
        store.regionIsAvailable = { $0.providerID != "mbta" }
        store.transitousIsEnabled = { false }
        store.providerHasKey = { _ in true }
        #expect(SharedHistoryStore(defaults: shared).disabledProviders() == nil)
        store.mirrorProviderSwitches()
        let disabled = SharedHistoryStore(defaults: shared).disabledProviders()
        #expect(disabled?.contains("mbta") == true)
        #expect(disabled?.contains(TransitousProvider.providerID) == true)
        #expect(disabled?.contains("bus.gov.il") == false)

        store.transitousIsEnabled = { true }
        store.mirrorProviderSwitches()
        #expect(SharedHistoryStore(defaults: shared).disabledProviders()?.contains(TransitousProvider.providerID) == false)
    }

    /// Any store other than the app's own keeps its history to itself, so a test or a staged
    /// screenshot never reaches the rider's widget.
    @Test func aNonStandardStoreSharesWithItself() {
        let defaults = suite("own")
        let store = SettingsStore(defaults: defaults)
        store.apply(stop: stop("41122", "ALLENBY"), lines: [line("18")], providerID: "mock")
        #expect(SharedHistoryStore(defaults: defaults).load().count == 1)
    }

    /// Every change is also offered to the watch (`WatchSync`). Under test the bridge is inactive,
    /// so nothing is sent and nothing crashes, with or without a paired watch.
    @Test func settingsChangesDoNotCrashWithoutAWatch() {
        #expect(!WidgetBridge.isActive)
        let store = SettingsStore(defaults: suite("own"), shared: suite("shared"))
        store.appearance = .dark
        store.language = "he"
        store.apply(stop: stop("41122", "ALLENBY"), lines: [line("18")], providerID: "mock")
        store.mirrorProviderSwitches()
        #expect(store.savedSetups.count == 1)
    }
}
