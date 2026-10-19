import SwiftUI

/// Stages one screen of the app on the mock provider, for App Store screenshots. Off unless the
/// app is launched with `-screenshot <screen>`, which `scripts/screenshots.sh` does:
///
///     -screenshot stops|search|lines|board|tapped|settings
///     -screenshotAppearance light|dark
///     -screenshotLines 1|2|3                  (default 3)
///     -screenshotOrientation portrait|landscape (iPhone and iPad; default portrait)
///     -screenshotWall YES                     (the board as a wall display)
///     -screenshotOnward 0|1|2…                (stops the routes run on past the rider's; default 0)
///     -screenshotClockRate 40 -screenshotClockOffset -140  (App Store previews: see AppClock)
///
/// Everything it touches is kept apart from a rider's own: its settings live in a volatile store,
/// telemetry stays off, and the clock is frozen so every run draws the same buses in the same places.
nonisolated struct ScreenshotMode: Sendable {
    enum Screen: String, Sendable {
        /// The home: the rider's saved stops.
        case stops
        /// The search screen on the mock's nearby stops.
        case search
        /// Step 2, with two lines already picked.
        case lines
        case board
        /// The board with a bus tapped.
        case tapped
        /// The Settings sheet over the board.
        case settings
    }

    enum Orientation: String, Sendable {
        case portrait, landscape
    }

    var screen: Screen
    var appearance: Appearance
    /// How many lines the board watches, 1 to 3.
    var lineCount: Int
    var orientation: Orientation
    /// The board in wall mode, as a display hung on a wall shows it.
    var wall = false
    /// How many stops the mock's routes run on past HARBOR GATE (`MockTransitProvider.onwardCount`).
    var onward = 0

    /// Nil for every ordinary launch.
    static let current: ScreenshotMode? = {
        let arguments = UserDefaults.standard
        guard let screen = arguments.string(forKey: "screenshot").flatMap(Screen.init) else { return nil }
        let appearance = arguments.string(forKey: "screenshotAppearance").flatMap(Appearance.init) ?? .dark
        let lines = arguments.integer(forKey: "screenshotLines")
        let orientation = arguments.string(forKey: "screenshotOrientation").flatMap(Orientation.init) ?? .portrait
        return ScreenshotMode(screen: screen, appearance: appearance,
                              lineCount: (1...3).contains(lines) ? lines : 3, orientation: orientation,
                              wall: arguments.bool(forKey: "screenshotWall"),
                              onward: max(0, arguments.integer(forKey: "screenshotOnward")))
    }()

    /// Three lines are the artboards' main composition. Two share a long corridor into the stop, the
    /// shape a real board most often has; one is drawn on its own, larger.
    var scenario: MockScenario { lineCount == 2 ? .corridor : .main }

    /// The lines watched, in the order they were picked.
    var lineIDs: [String] {
        switch lineCount {
        case 1: ["41"]
        case 2: ["41", "18"]
        default: ["18", "41", "7"]
        }
    }

    /// Apple's 9:41 (`AppClock.frozenNow`).
    static var frozenNow: Date { AppClock.frozenNow }

    /// The Mac App Store's 2560 × 1600 at 2×. Its 2880 × 1800 would need a window taller than a
    /// laptop's screen leaves room for, and macOS shrinks one that does not fit.
    static let macWindowSize = CGSize(width: 1280, height: 800)

    /// The Darwin notification that sets a preview's clock running, posted by the recording script
    /// (`notifyutil -p` in the simulator, `notify_post` from the Mac's UI test) as filming starts.
    static let clockStartNotification = "com.hayek.BusBus.screenshotClock"

    static func listenForClockStart() {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            AppClock.startRunning()
        }, clockStartNotification as CFString, nil, .deliverImmediately)
    }

    /// Where the rider stands: a short walk from the mock's HARBOR GATE.
    static let location = GeoPoint(lat: MockTransitProvider.anchor.lat - 0.0015,
                                   lon: MockTransitProvider.anchor.lon + 0.0015)
}

extension TimelineViewDefaultContext {
    /// The tick's date, unless screenshots have frozen the clock (or run it on from 9:41).
    nonisolated var now: Date { ScreenshotMode.current == nil ? date : AppClock.now }
}
