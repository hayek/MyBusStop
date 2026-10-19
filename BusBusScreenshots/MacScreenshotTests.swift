import XCTest

/// Captures the Mac App Store screenshots. The app stages each screen itself (`ScreenshotMode`);
/// this only launches it and photographs the window. XCTest can read another app's window where a
/// shell's `screencapture` needs Screen Recording permission, which is why the Mac pass runs here.
///
/// Run it through `scripts/screenshots.sh mac`, which sets the appearance and pulls the attachments
/// out of the result bundle. Skipped in any other run.
final class MacScreenshotTests: XCTestCase {
    /// Every shot as (screen, lines watched, file name), the same list the script uses on iOS.
    private static let shots: [(screen: String, lines: Int, name: String)] = {
        var shots = [(screen: "stops", lines: 3, name: "stops"), (screen: "search", lines: 3, name: "search")]
        for screen in ["lines", "board", "tapped", "settings"] {
            for lines in 1...3 {
                shots.append((screen, lines, lines == 1 ? "\(screen)-1-line" : "\(screen)-\(lines)-lines"))
            }
        }
        return shots
    }()

    func testCaptureScreenshots() throws {
        guard let appearance = ProcessInfo.processInfo.environment["SCREENSHOT_APPEARANCE"] else {
            throw XCTSkip("Screenshots run only through scripts/screenshots.sh")
        }
        for shot in Self.shots {
            let app = XCUIApplication()
            app.launchArguments = ["-screenshot", shot.screen, "-screenshotLines", "\(shot.lines)",
                                   "-screenshotAppearance", appearance, "-ApplePersistenceIgnoreState", "YES"]
            // The frozen 9:41 is read in this zone, which fixes where the mock's buses are.
            app.launchEnvironment["TZ"] = "Asia/Jerusalem"
            app.launch()
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 10), "no window for \(shot.name)")

            let attachment = XCTAttachment(screenshot: settled(window))
            attachment.name = shot.name
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    /// The App Store set's raw material, in every language `STORE_LANGUAGES` names (as
    /// "<language>=<place>", the city its stops are set in: MockPlace): stills, and
    /// frame sequences taken with the staged clock running, for scripts/store-art.py to set in the
    /// designed frames and cut into the preview. XCTest cannot record video, so a clip is a run of
    /// window shots named after the millisecond each was taken at:
    ///   <language>+<name>.png, <language>+<name>-clip+<ms>.png
    func testCaptureStoreSet() throws {
        guard let languages = ProcessInfo.processInfo.environment["STORE_LANGUAGES"] else {
            throw XCTSkip("The store set runs only through scripts/screenshots.sh store")
        }
        // (kind, screen, lines watched, name), as the iOS captures in the script.
        let captures: [(clip: Bool, screen: String, lines: Int, name: String)] = [
            (false, "board", 2, "board"), (false, "tapped", 2, "tapped"), (false, "lines", 2, "lines"),
            (false, "board", 3, "routes"), (true, "board", 2, "board"), (true, "tapped", 2, "tapped"),
        ]
        for entry in languages.split(separator: " ") {
            let parts = entry.split(separator: "=").map(String.init)
            let language = parts[0]
            for capture in captures {
                let app = XCUIApplication()
                app.launchArguments = ["-screenshot", capture.screen, "-screenshotLines", "\(capture.lines)",
                                       "-screenshotAppearance", "dark", "-ApplePersistenceIgnoreState", "YES",
                                       // The app's own language setting too (SettingsStore reads launch
                                       // arguments): the Mac's AppleLanguages alone leaves strings built in
                                       // code, and the layout's direction, in the system's language.
                                       "-AppleLanguages", "(\(language))", "-AppleLocale", language,
                                       "-settings.language", language,
                                       "-screenshotPlace", parts.count > 1 ? parts[1] : ""]
                if capture.clip {
                    // The script's CLIP_RATE and CLIP_OFFSET: the next bus counts down to NOW.
                    app.launchArguments += ["-screenshotClockRate", "40", "-screenshotClockOffset", "-140"]
                }
                app.launchEnvironment["TZ"] = "Asia/Jerusalem"
                app.launch()
                let window = app.windows.firstMatch
                XCTAssertTrue(window.waitForExistence(timeout: 10), "no window for \(language) \(capture.name)")
                if capture.clip {
                    Thread.sleep(forTimeInterval: 4)
                    // ScreenshotMode.clockStartNotification: the clock runs from the first frame.
                    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                        CFNotificationName("com.hayek.BusBus.screenshotClock" as CFString), nil, nil, true)
                    let start = Date()
                    while Date().timeIntervalSince(start) < 8 {
                        let ms = Int(Date().timeIntervalSince(start) * 1000)
                        keep(window.screenshot(), as: "\(language)+\(capture.name)-clip+\(String(format: "%06d", ms))")
                    }
                } else {
                    keep(settled(window), as: "\(language)+\(capture.name)")
                }
                app.terminate()
            }
        }
    }

    private func keep(_ screenshot: XCUIScreenshot, as name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The window once two shots a second apart match, so a loading board — which shimmers — is
    /// never what gets kept. Gives up after fifteen tries and keeps the last.
    private func settled(_ window: XCUIElement) -> XCUIScreenshot {
        Thread.sleep(forTimeInterval: 2)
        var previous = window.screenshot()
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 1)
            let current = window.screenshot()
            if current.pngRepresentation == previous.pngRepresentation { return current }
            previous = current
        }
        return previous
    }
}
