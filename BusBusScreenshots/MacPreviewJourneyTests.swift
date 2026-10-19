#if os(macOS)
import AppKit
import XCTest

/// The Mac App Store preview's journey: the nearest stop found in search and confirmed, its lines
/// chosen in the same sheet, the live map, a bus clicked, and wall mode turned on. XCTest cannot
/// record video, so the window is filmed as a run of shots between clicks, each written to the
/// runner's temporary folder as <ms>.jpg, the milliseconds since filming began; every click is
/// printed as "TAP <name> <x> <y> <ms>" in the window's points. scripts/preview-video.sh runs it;
/// skipped in any other run.
final class MacPreviewJourneyTests: XCTestCase {
    private var out: URL!
    private var start = Date()
    private var window: XCUIElement!

    private var elapsed: Int { Int(Date().timeIntervalSince(start) * 1000) }

    /// Films the window for `seconds`.
    private func film(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            let ms = elapsed
            let image = window.screenshot().image
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else { continue }
            try? jpeg.write(to: out.appendingPathComponent(String(format: "%06d.jpg", ms)))
        }
    }

    private func click(_ element: XCUIElement, _ name: String) {
        note(element, name)
        element.click()
    }

    /// The search list's stop row, clicked where it is drawn. With the NYC staging the row reports
    /// isHittable false, and element.click() fails with "Unable to find hit point for ScrollView",
    /// while a click at its centre opens the confirm step as it should. Why is not yet known: no
    /// other element covers that point, even with the map dragged away. Only this row gets the
    /// workaround, so anything else that is really covered still fails the run.
    private func clickStopRow(_ row: XCUIElement) {
        note(row, "stop")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    private func note(_ element: XCUIElement, _ name: String) {
        let frame = element.frame, origin = window.frame.origin
        print(String(format: "TAP %@ %.1f %.1f %d", name, frame.midX - origin.x, frame.midY - origin.y, elapsed))
    }

    func testJourney() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PREVIEW_JOURNEY"] != nil else {
            throw XCTSkip("The preview's journey runs only through scripts/preview-video.sh")
        }
        // The runner is sandboxed: the shots go to its own temporary folder, printed for the script.
        out = FileManager.default.temporaryDirectory.appendingPathComponent("preview-journey")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        print("FRAMES \(out.path)")
        let language = environment["PREVIEW_LANGUAGE"] ?? "en"
        let app = XCUIApplication()
        app.launchArguments = ["-screenshot", "stops", "-screenshotLines", "2", "-screenshotAppearance", "dark",
                               "-ApplePersistenceIgnoreState", "YES",
                               "-AppleLanguages", "(\(language))", "-AppleLocale", language, "-settings.language", language,
                               "-screenshotPlace", environment["PREVIEW_PLACE"] ?? "nyc",
                               "-screenshotClockRate", environment["PREVIEW_CLOCK_RATE"] ?? "20",
                               "-screenshotClockOffset", "-140"]
        // The frozen 9:41 is read in this zone, which fixes where the mock's buses are.
        app.launchEnvironment["TZ"] = "Asia/Jerusalem"
        app.launch()
        window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let search = app.buttons["home.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        start = Date()

        film(1.6)
        click(search, "search")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS 'meters'",
                                                    environment["PREVIEW_STOP"] ?? "5 AV/W 42 ST")).element(boundBy: 0)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        film(2.0)
        clickStopRow(row)
        // Asked about on the map before it is chosen.
        let select = app.buttons["confirm.select"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        film(1.4)
        click(select, "select")
        // The lines slide over the search sheet, which stays up until they are chosen.
        XCTAssertTrue(app.buttons["SHOW THE MAP"].waitForExistence(timeout: 5))
        film(1.6)
        click(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Line 41'")).element(boundBy: 0), "line41")
        film(0.7)
        click(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Line 18'")).element(boundBy: 0), "line18")
        film(0.9)
        // The sheet goes, and the board is behind it.
        click(app.buttons["SHOW THE MAP"], "confirm")
        // ScreenshotMode.clockStartNotification: the buses move from here.
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.hayek.BusBus.screenshotClock" as CFString), nil, nil, true)
        film(9.0)

        let buses = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Bus 41'"))
        if let nearest = buses.allElementsBoundByIndex.min(by: { minutes($0.label) < minutes($1.label) }) {
            click(nearest, "bus")
        }
        film(4.5)

        click(app.buttons["Settings"].firstMatch, "gear")
        film(1.2)
        click(app.sheets.firstMatch.switches.firstMatch, "wall")
        film(1.2)
        click(app.sheets.firstMatch.buttons["Done"], "done")
        film(8.0)
    }

    /// "BUS 41, 9 MINUTES AWAY, 5 STOPS" → 9.
    private func minutes(_ label: String) -> Int {
        let parts = label.split(separator: ",")
        guard parts.count > 1 else { return .max }
        return Int(parts[1].split(separator: " ").first ?? "") ?? .max
    }
}
#endif
