import SwiftUI

extension ScreenshotMode {
    private static let suiteName = "com.hayek.BusBus.screenshots"

    /// A rider who has used the app for a while: three stops in their history, the mock's HARBOR
    /// GATE last, watching as many lines as asked. The store is wiped on every launch, so nothing a
    /// run changes carries to the next.
    @MainActor func makeSettings() -> SettingsStore {
        let defaults = UserDefaults(suiteName: Self.suiteName) ?? .standard
        defaults.removePersistentDomain(forName: Self.suiteName)
        let settings = SettingsStore(defaults: defaults)
        let mock = MockTransitProvider()
        settings.providerOverride = MockTransitProvider(scenario: scenario, onwardCount: onward)
        // The mock needs no key and no remote switch; staged, every region is open.
        settings.regionIsAvailable = { _ in true }
        settings.providerHasKey = { _ in true }
        settings.transitousIsEnabled = { false }
        settings.appearance = appearance
        settings.wallMode = wall

        let history: [(code: String, hoursAgo: Double)] = [("CANAL-ST", 50), ("PIER-FOUR", 26)]
        for entry in history {
            guard let staged = mock.staged(stopCode: entry.code) else { continue }
            settings.apply(stop: staged.stop, lines: staged.lines, providerID: settings.providerID,
                           at: Self.frozenNow.addingTimeInterval(-entry.hoursAgo * 3600))
        }
        if let staged = boardStop {
            settings.apply(stop: staged.stop, lines: staged.lines, providerID: settings.providerID,
                           at: Self.frozenNow.addingTimeInterval(-3600))
        }
        // Setup is only reached with no board yet; the board screens open on HARBOR GATE.
        if [.stops, .search, .lines].contains(screen) { settings.configuration = nil }
        return settings
    }

    /// HARBOR GATE and the lines watched there, in `lineIDs` order.
    var boardStop: (stop: TransitStop, lines: [TransitLine])? {
        guard let staged = MockTransitProvider(scenario: scenario).staged(stopCode: MapFixtures.userCode) else { return nil }
        let lines = lineIDs.compactMap { id in staged.lines.first { $0.id == id } }
        return (staged.stop, lines)
    }
}
