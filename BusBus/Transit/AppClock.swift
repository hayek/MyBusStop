import Foundation

/// The time as the app sees it: the real one, or the frozen one while staging screenshots.
///
/// Kept in the Transit layer, which stamps its fetches with it, so that layer builds without the app
/// around it (scripts/live-probe.sh).
nonisolated enum AppClock {
    /// Whether this run stages App Store screenshots: `ScreenshotMode`'s `-screenshot` launch argument.
    static let isStaging = UserDefaults.standard.string(forKey: "screenshot") != nil

    /// Apple's 9:41 on a weekday morning, in whatever time zone the app is running in. The script
    /// pins that zone too, so the moment — and so the mock's buses — are the same on every run.
    static let frozenNow: Date = {
        let components = DateComponents(year: 2026, month: 9, day: 15, hour: 9, minute: 41)
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }()

    /// How fast the staged clock runs on from 9:41: 0, the default, holds it still for screenshots;
    /// the App Store previews play it at `-screenshotClockRate` times real time, so buses move and
    /// the countdown runs down while they are recorded. It holds at `-screenshotClockOffset` seconds
    /// until `startRunning()`, which the recording script sets off the moment it starts filming,
    /// however long the launch took (`ScreenshotMode.listenForClockStart`).
    static let rate = UserDefaults.standard.double(forKey: "screenshotClockRate")
    private static let offset = UserDefaults.standard.double(forKey: "screenshotClockOffset")
    nonisolated(unsafe) private static var startedAt: Date?

    static func startRunning() { startedAt = Date() }

    static var now: Date {
        guard isStaging else { return Date() }
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        return frozenNow.addingTimeInterval(offset + elapsed * rate)
    }
}
