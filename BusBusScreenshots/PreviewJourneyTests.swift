#if os(iOS)
import XCTest

/// Drives the App Store preview's journey through the staged app while scripts/preview-video.sh
/// films the simulator: the nearest stop found in search and confirmed, its lines chosen there as
/// search's last step, the live map, a bus tapped, and wall mode turned on and the device turned
/// (PREVIEW_ORIENTATION, PREVIEW_WALL_ORIENTATION). Each step prints "MARK <name> <epoch>" and each
/// tap "TAP <name> <x> <y> <epoch>", for the cut to find them in the recording. Skipped in any
/// other run.
final class PreviewJourneyTests: XCTestCase {
    private func mark(_ name: String) {
        print(String(format: "MARK %@ %.3f", name, Date().timeIntervalSince1970))
    }

    /// "TAP <name> <x> <y> <epoch>": where a tap lands, in the window's points, for the touch the
    /// preview draws there.
    private func note(_ name: String, _ x: CGFloat, _ y: CGFloat) {
        print(String(format: "TAP %@ %.1f %.1f %.3f", name, x, y, Date().timeIntervalSince1970))
    }

    private func tap(_ element: XCUIElement, _ name: String) {
        let frame = element.frame
        note(name, frame.midX, frame.midY)
        element.tap()
    }

    private func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    func testJourney() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PREVIEW_JOURNEY"] != nil else {
            throw XCTSkip("The preview's journey runs only through scripts/preview-video.sh")
        }
        let language = environment["PREVIEW_LANGUAGE"] ?? "en"
        let app = XCUIApplication()
        app.launchArguments = ["-screenshot", "stops", "-screenshotLines", "2", "-screenshotAppearance", "dark",
                               "-AppleLanguages", "(\(language))", "-AppleLocale", language,
                               "-settings.language", language,
                               "-screenshotPlace", environment["PREVIEW_PLACE"] ?? "nyc",
                               "-screenshotClockRate", environment["PREVIEW_CLOCK_RATE"] ?? "20",
                               "-screenshotClockOffset", "-140"]
        app.launchEnvironment["TZ"] = "Asia/Jerusalem"
        XCUIDevice.shared.orientation = environment["PREVIEW_ORIENTATION"] == "landscape" ? .landscapeLeft : .portrait
        app.launch()
        let search = app.buttons["home.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        pause(2.5)

        mark("nearby")
        // Into search, which opens on the stops around the rider, then the closest one.
        tap(search, "search")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS 'meters'",
                                                    environment["PREVIEW_STOP"] ?? "5 AV/W 42 ST")).element(boundBy: 0)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        if !row.isHittable || row.frame.maxY > app.windows.firstMatch.frame.maxY - 40 {
            // The drawer raised, for a stop below its fold.
            let window = app.windows.firstMatch
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            note("drag", window.frame.width * 0.5, window.frame.height * 0.6)
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        pause(1.4)
        tap(row, "stop")
        // Asked about on the map before it is chosen.
        let select = app.buttons["confirm.select"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        pause(1.4)
        tap(select, "select")
        // The lines, pushed inside search over the confirm step.
        XCTAssertTrue(app.buttons["SHOW THE MAP"].waitForExistence(timeout: 5))
        pause(1.0)

        mark("lines")
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Line 41'")).element(boundBy: 0), "line41")
        pause(0.8)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Line 18'")).element(boundBy: 0), "line18")
        pause(1.0)
        // Search closes on the board.
        tap(app.buttons["SHOW THE MAP"], "confirm")
        // ScreenshotMode.clockStartNotification: the buses move from here.
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.hayek.BusBus.screenshotClock" as CFString), nil, nil, true)
        mark("board")
        pause(9.0)

        mark("tap")
        let buses = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bus 41'"))
        let nearest = buses.allElementsBoundByIndex.min { minutes($0.label) < minutes($1.label) }
        if let nearest { tap(nearest, "bus") }
        pause(4.5)

        mark("settings")
        tap(app.buttons["Settings"], "gear")
        pause(1.4)
        tap(app.switches.matching(NSPredicate(format: "label == 'Wall mode'")).element(boundBy: 0).switches.firstMatch, "wall")
        pause(1.2)
        tap(app.buttons["Done"], "done")
        pause(1.0)

        mark("rotate")
        XCUIDevice.shared.orientation = environment["PREVIEW_WALL_ORIENTATION"] == "portrait" ? .portrait : .landscapeLeft
        pause(1.5)
        mark("wall")
        pause(9.0)
        mark("end")
        XCUIDevice.shared.orientation = .portrait
    }

    /// "Bus 41, 9 minutes away, 5 stops" → 9.
    private func minutes(_ label: String) -> Int {
        let parts = label.split(separator: ",")
        guard parts.count > 1 else { return .max }
        return Int(parts[1].split(separator: " ").first ?? "") ?? .max
    }
}
#endif
