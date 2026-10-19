import Testing
import Foundation
@testable import BusBus

@MainActor
struct OnboardingProgressTests {

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "onboarding-\(UUID().uuidString)")!
    }

    private func stop() -> TransitStop {
        TransitStop(code: "41122", name: "ALLENBY", city: "Harbor City", location: GeoPoint(lat: 32.9, lon: 34.95))
    }

    private func line() -> TransitLine {
        TransitLine(id: "18", shortName: "18", headsign: nil, agency: nil, origin: nil, destination: nil,
                    isAccessible: nil, brandColorIndex: nil)
    }

    @Test func aFreshInstallStartsWithTheStory() {
        #expect(SettingsStore(defaults: suite()).onboarding == .welcome)
    }

    /// Someone upgrading with a board already set up never sees the story or the tip.
    @Test func anUpgradeWithAStopIsDone() throws {
        let defaults = suite()
        let configuration = BoardConfiguration(providerID: "mock", stop: stop(), lines: [line()])
        defaults.set(try JSONEncoder().encode(configuration), forKey: "board.configuration")
        let store = SettingsStore(defaults: defaults)
        #expect(store.configuration != nil)
        #expect(store.onboarding == .done)
        // Resolved, not written: the rule answers the same way on the next launch.
        #expect(defaults.string(forKey: "onboarding.progress") == nil)
    }

    @Test func anUpgradeWithOnlyHistoryIsDone() {
        let defaults = suite()
        let first = SettingsStore(defaults: defaults)
        first.apply(stop: stop(), lines: [line()], providerID: "mock")
        first.configuration = nil
        defaults.removeObject(forKey: "onboarding.progress")

        let store = SettingsStore(defaults: defaults)
        #expect(store.configuration == nil)
        #expect(!store.savedSetups.isEmpty)
        #expect(store.onboarding == .done)
    }

    @Test func aPendingTipSurvivesARelaunch() {
        let defaults = suite()
        SettingsStore(defaults: defaults).onboarding = .tipPending
        #expect(SettingsStore(defaults: defaults).onboarding == .tipPending)
    }

    /// A rider still in the story keeps it, whatever else is stored.
    @Test func aStoredValueWinsOverHistory() {
        #expect(OnboardingProgress.initial(stored: "welcome", hasConfiguration: false, hasHistory: true) == .welcome)
        #expect(OnboardingProgress.initial(stored: "tipPending", hasConfiguration: true, hasHistory: true) == .tipPending)
    }

    @Test func anUnknownStoredValueIsIgnored() {
        #expect(OnboardingProgress.initial(stored: "sideways", hasConfiguration: false, hasHistory: false) == .welcome)
        #expect(OnboardingProgress.initial(stored: "sideways", hasConfiguration: true, hasHistory: false) == .done)
    }
}
