import XCTest

/// The way to a stop, end to end on the staged app: a saved stop opens its board in one tap, and a
/// new one is found in search, asked about, and chosen. Runs on the Mac and on the iPhone simulator,
/// in every run of this target.
final class SearchFlowTests: XCTestCase {
    private var app: XCUIApplication!

    /// A search result's row reads "<name>, 120 meters, lines …"; a saved stop's never has a distance.
    /// English is forced below, but the spelling follows the region, so either one counts.
    private static let nearbyRow = NSPredicate(format: "label CONTAINS 'meters' OR label CONTAINS 'metres'")

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-screenshot", "stops", "-screenshotAppearance", "dark",
                               "-ApplePersistenceIgnoreState", "YES",
                               // The labels the predicates read, whatever the machine speaks.
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-settings.language", "en"]
        // The frozen 9:41 is read in this zone, which fixes where the mock's buses are.
        app.launchEnvironment["TZ"] = "Asia/Jerusalem"
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func openSearch() {
        let bar = element("home.search")
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "no search bar on the home")
        press(bar)
        XCTAssertTrue(element("search.field").waitForExistence(timeout: 5), "search did not open")
    }

    /// A saved stop was confirmed once already: it goes straight to its board, with no question.
    func testSavedStopOpensWithoutConfirm() {
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'CANAL ST,'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "the staged history has no CANAL ST")
        press(saved)
        let header = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'CANAL ST. Change stop and lines'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "the board did not open")
        XCTAssertFalse(element("confirm.select").exists)
        XCTAssertFalse(element("search.field").exists)
    }

    /// A row is asked about before it is chosen; BACK puts the list back as it was. SELECT STOP
    /// pushes the stop's lines inside search, whose way back is to the same confirm step, and
    /// choosing lines there closes search on the board.
    func testSearchConfirmBackThenSelect() {
        openSearch()
        let firstRow = app.buttons.matching(Self.nearbyRow).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "no stops near the rider")
        let label = firstRow.label
        let row = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(waitUntilHittable(row, timeout: 10), "the row cannot be tapped")
        press(row)

        let select = element("confirm.select"), back = element("confirm.back")
        XCTAssertTrue(select.waitForExistence(timeout: 5), "no confirm step")
        XCTAssertTrue(back.exists)
        attachScreenshot("confirm-lines")
        press(back)
        XCTAssertTrue(select.waitForNonExistence(timeout: 5), "BACK left the confirm step up")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "BACK did not bring the row back")
        XCTAssertTrue(waitUntilHittable(row), "the row is not where the rider left it")

        press(row)
        XCTAssertTrue(select.waitForExistence(timeout: 5), "no confirm step the second time")
        press(select)
        let showMap = app.buttons["SHOW THE MAP"]
        XCTAssertTrue(showMap.waitForExistence(timeout: 10), "no line picker")
        attachScreenshot("line-picker")

        // Back from the lines: the confirm step again, about the same stop.
        goBackFromLinePicker()
        XCTAssertTrue(showMap.waitForNonExistence(timeout: 5), "the line picker stayed up")
        XCTAssertTrue(select.waitForExistence(timeout: 5), "back from the lines did not return to the confirm step")
        XCTAssertTrue(waitUntilHittable(select), "the confirm step is not in front")
        attachScreenshot("back-from-lines")
        let name = String(label.prefix { $0 != "," })
        XCTAssertTrue(app.staticTexts[name].exists, "the confirm step is not about \(name) any more")

        // On again, a line chosen, and the board in place of search.
        press(select)
        XCTAssertTrue(showMap.waitForExistence(timeout: 10), "no line picker the second time")
        let line = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Line '")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10), "the line picker lists no lines")
        press(line)
        press(showMap)
        let header = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ENDSWITH '. Change stop and lines'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "the board did not open")
        XCTAssertTrue(element("search.field").waitForNonExistence(timeout: 5), "search stayed up over the board")
    }

    /// A stop no line calls at says so in place of its lines, and cannot be chosen.
    func testStopWithNoLinesCannotBeSelected() {
        openSearch()
        let field = element("search.field")
        press(field)
        field.typeText("salt")
        // Its row in the list or its pin on the map, the same tap either way. On a Mac a result's row
        // (unlike a nearby one) never reports itself hittable, so the pin is taken there.
        let matches = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'SALT MARSH'"))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10), "the mock's lineless stop was not found")
        let result = matches.allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(result, "neither the row nor the pin of the lineless stop can be tapped")
        guard let result else { return }
        press(result)
        let select = element("confirm.select")
        XCTAssertTrue(select.waitForExistence(timeout: 5), "no confirm step")
        let caption = app.staticTexts["NO LINES STOP HERE"]
        XCTAssertTrue(caption.waitForExistence(timeout: 10), "the panel does not say no lines stop here")
        XCTAssertFalse(select.isEnabled, "SELECT STOP can be pressed at a stop with no lines")
        attachScreenshot("no-lines")
        press(select)
        XCTAssertFalse(app.buttons["SHOW THE MAP"].waitForExistence(timeout: 2), "a stop with no lines opened the line picker")
    }

    /// The ⓘ beside a line in the confirm step opens the line's card over search, with its stops;
    /// closing it leaves the confirm step as it was.
    func testLineCardOpensFromConfirmStep() {
        openSearch()
        let firstRow = app.buttons.matching(Self.nearbyRow).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "no stops near the rider")
        XCTAssertTrue(waitUntilHittable(firstRow, timeout: 10), "the row cannot be tapped")
        press(firstRow)
        let about = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'About line '")).firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 10), "the confirm step's lines have no ⓘ")
        press(about)
        XCTAssertTrue(app.staticTexts["STOPS ON THIS LINE"].waitForExistence(timeout: 10), "no line card")
        // The mock's shape is drawn without a note that the route is missing.
        XCTAssertFalse(app.staticTexts["Route not available for this line"].waitForExistence(timeout: 2))
        attachScreenshot("line-card")
        press(app.buttons["Close"].firstMatch)
        XCTAssertTrue(app.staticTexts["STOPS ON THIS LINE"].waitForNonExistence(timeout: 5), "the card stayed up")
        XCTAssertTrue(element("confirm.select").exists, "closing the card left the confirm step")
    }

    /// On the board the stop's name changes its lines, the gear opens settings, and the back
    /// chevron before the name goes back to the stops.
    func testHeaderNameOpensLinesAndChevronGoesBack() {
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'CANAL ST,'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "the staged history has no CANAL ST")
        press(saved)
        let name = app.buttons.matching(NSPredicate(format: "label == 'Change lines' AND value == 'CANAL ST'")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10), "the stop's name is not the way to its lines")
        XCTAssertTrue(waitUntilHittable(name, timeout: 10), "the stop's name cannot be tapped")
        attachScreenshot("board-header")
        press(name)
        let linesDone = app.buttons["DONE"].firstMatch
        XCTAssertTrue(linesDone.waitForExistence(timeout: 5), "the line picker did not open")
        attachScreenshot("board-lines")
        press(linesDone)
        XCTAssertTrue(linesDone.waitForNonExistence(timeout: 5), "the line picker did not close")
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(waitUntilHittable(gear, timeout: 5), "the board has no settings gear")
        press(gear)
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "settings did not open")
        press(done)
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "settings did not close")
        let back = app.buttons.matching(NSPredicate(format: "label == 'CANAL ST. Change stop and lines'")).firstMatch
        XCTAssertTrue(waitUntilHittable(back, timeout: 5), "the back chevron cannot be tapped")
        press(back)
        XCTAssertTrue(element("home.search").waitForExistence(timeout: 10), "the chevron did not go back")
    }

    /// A stop tapped on the line card's map is scrolled to in the stop list under it.
    func testLineCardMapStopFindsItsRow() {
        openSearch()
        let firstRow = app.buttons.matching(Self.nearbyRow).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "no stops near the rider")
        XCTAssertTrue(waitUntilHittable(firstRow, timeout: 10), "the row cannot be tapped")
        press(firstRow)
        let about = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'About line '")).firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 10), "the confirm step's lines have no ⓘ")
        press(about)
        let mapStops = element("Route map").buttons
        XCTAssertTrue(mapStops.firstMatch.waitForExistence(timeout: 10), "the map's stops cannot be tapped")
        // The far end of the line, below the fold of the half-height card.
        let last = mapStops.element(boundBy: mapStops.count - 1)
        let name = last.label
        press(last)
        // Its row: a button named for the stop that is not on the map, and on screen. The map is
        // read again each time, since the scroll may carry it off the screen.
        let screen = app.windows.firstMatch.frame
        let rowShown = NSPredicate { _, _ in
            let map = self.element("Route map")
            let mapFrame = map.exists ? map.frame : .null
            return self.app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).allElementsBoundByIndex
                .contains { row in
                    let middle = CGPoint(x: row.frame.midX, y: row.frame.midY)
                    return !row.frame.isEmpty && screen.contains(middle) && !mapFrame.contains(middle)
                }
        }
        let found = XCTWaiter.wait(for: [expectation(for: rowShown, evaluatedWith: nil)], timeout: 5)
        XCTAssertEqual(found, .completed, "\(name) was not scrolled to in the list")
        attachScreenshot("line-card-map-stop")
    }

    /// The full route's strip turns into the map with the lines on their roads, and back.
    func testFullRouteTogglesToTheMap() {
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'CANAL ST,'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "the staged history has no CANAL ST")
        press(saved)
        let full = app.buttons["Full lines view"].firstMatch
        XCTAssertTrue(full.waitForExistence(timeout: 10), "the board has no full lines button")
        XCTAssertTrue(waitUntilHittable(full, timeout: 10), "the full lines button cannot be tapped")
        press(full)
        let toMap = element("fullRoute.map")
        XCTAssertTrue(toMap.waitForExistence(timeout: 10), "the full route has no map toggle")
        attachScreenshot("full-route-strip")
        press(toMap)
        XCTAssertTrue(element("Route map").waitForExistence(timeout: 10), "the map did not open")
        attachScreenshot("full-route-map")
        press(element("fullRoute.strip"))
        XCTAssertTrue(element("Route overview").waitForExistence(timeout: 5), "the strip did not come back")
    }

    /// CANCEL leaves search, and the next opening forgets what was typed.
    func testCancelClosesAndReopensFresh() {
        openSearch()
        let field = element("search.field")
        press(field)
        field.typeText("har")
        XCTAssertEqual(field.value as? String, "har")
        press(element("search.cancel"))
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "CANCEL left search up")

        openSearch()
        let reopened = element("search.field")
        let value = reopened.value as? String ?? ""
        XCTAssertTrue(value.isEmpty || value == reopened.placeholderValue,
                      "search reopened with \"\(value)\" in the field")
    }

    /// Kept with the run's results, for the panel to be looked at as well as asserted on.
    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The way back from the line picker: the navigation bar's back button on a phone; Escape on a
    /// Mac, where the picker's own BACK answers to it.
    private func goBackFromLinePicker() {
        #if os(macOS)
        app.typeKey(.escape, modifierFlags: [])
        #else
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "the line picker has no back button")
        back.tap()
        #endif
    }

    /// The list settles after the drawer's spring, so a row can exist a moment before it takes taps.
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let hittable = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: element)
        return XCTWaiter.wait(for: [hittable], timeout: timeout) == .completed
    }
}
